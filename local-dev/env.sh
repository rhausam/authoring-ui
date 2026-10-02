# Shared settings for the local-dev scripts. Override any of these in your
# environment, or in local-dev/env.local.sh (not committed).

LOCAL_DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_ROOT="$(cd "$LOCAL_DEV/.." && pwd)"
LOGS="$LOCAL_DEV/logs"

# Snowstorm 11 and Authoring Services 10 need Java 25
: "${JAVA_25:=$HOME/.asdf/installs/java/temurin-25.0.4+101.0.LTS/bin/java}"

: "${SNOWSTORM_JAR:=$HOME/git-repo/snowstorm/target/snowstorm-11.0.0.jar}"
: "${AUTHORING_SERVICES_JAR:=$HOME/git-repo/authoring-services/target/authoring-services-10.0.1.jar}"
: "${CLASSIFICATION_SERVICE_JAR:=$HOME/git-repo/classification-service/target/classification-service-10.0.1.jar}"

# Optional extra reasoner for the Classification Service (ELK is built in). If this jar
# exists, start.sh adds it to the class path and extracts its native library; see
# "Other reasoners" in local-dev/README.md. Use a release build at a stable path, not a
# development build directory that test runs overwrite with unreleased code.
: "${KONCLUDE_PLUGIN_JAR:=$HOME/build/protege-plugin-master/konclude-protege-plugin-master.jar}"
# Reasoner factory used when a classification doesn't name one (e.g. the UI's Classify
# button). Empty means Snowstorm's default, ELK. For Konclude:
#   REASONER_ID=com.konclude.owlapi.KoncludeReasonerFactory
: "${REASONER_ID:=}"
# Built checkout of https://github.com/IHTSDO/sct-browser-frontend served at /browser/ by the
# gateway (the UI's "TS Browser" link); see local-dev/README.md
: "${BROWSER_DIR:=$HOME/git-repo/sct-browser-frontend}"
# Extra JVM options for the Classification Service, e.g. -Dkonclude.taxonomyCache=false
: "${CLASSIFICATION_JAVA_OPTS:=}"
: "${ACTIVEMQ_HOME:=$(brew --prefix activemq 2>/dev/null)}"

: "${GATEWAY_PORT:=9100}"
: "${UI_PORT:=9001}"
: "${SNOWSTORM_PORT:=8090}"
: "${AUTHORING_SERVICES_PORT:=8081}"
: "${CLASSIFICATION_SERVICE_PORT:=8089}"

# The RF2 release loaded into Snowstorm. seed.sh links it into the Classification
# Service release store and sets it as MAIN's previousPackage.
: "${RF2_RELEASE_ZIP:=$HOME/Downloads/NCTS_SCT_RF2_DISTRIBUTION_32506021000036107-20260930-SNAPSHOT.zip}"

if [ -f "$LOCAL_DEV/env.local.sh" ]; then
  . "$LOCAL_DEV/env.local.sh"
fi
if [ -f "$LOCAL_DEV/.secrets.env" ]; then
  set -a
  . "$LOCAL_DEV/.secrets.env"
  set +a
fi

mkdir -p "$LOGS" "$LOCAL_DEV/data"

is_running() {
  [ -f "$LOGS/$1.pid" ] && kill -0 "$(cat "$LOGS/$1.pid")" 2>/dev/null
}

port_open() {
  nc -z localhost "$1" >/dev/null 2>&1
}

wait_for_url() {
  local url=$1 name=$2 tries=${3:-120}
  printf 'Waiting for %s ' "$name"
  for _ in $(seq "$tries"); do
    if curl -s -o /dev/null -m 2 "$url"; then
      echo ' up'
      return 0
    fi
    printf '.'
    sleep 2
  done
  echo ' timed out'
  return 1
}
