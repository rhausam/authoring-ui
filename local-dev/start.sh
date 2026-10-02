#!/usr/bin/env bash
# Start the local Authoring Platform stack: ActiveMQ, Snowstorm, Authoring Services,
# the Classification Service, the UI (grunt serve) and the gateway. Elasticsearch and MariaDB/MySQL must already
# be running. Then open http://localhost:9100
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$UI_ROOT"

if ! curl -s -o /dev/null -m 2 http://localhost:9200; then
  echo 'Elasticsearch is not running on localhost:9200 - start it first.' >&2
  exit 1
fi

if port_open 61616; then
  echo 'ActiveMQ already running'
else
  echo 'Starting ActiveMQ'
  "$ACTIVEMQ_HOME/bin/activemq" start > "$LOGS/activemq-start.log" 2>&1
fi

if is_running snowstorm; then
  echo 'Snowstorm already running'
else
  echo "Starting Snowstorm on $SNOWSTORM_PORT"
  # Snowstorm writes snomed-drools-rules/ and authoring-traceability.log to its working directory
  mkdir -p "$LOCAL_DEV/data/snowstorm"
  cd "$LOCAL_DEV/data/snowstorm"
  nohup "$JAVA_25" -Xms2g -Xmx6g -jar "$SNOWSTORM_JAR" \
    --spring.config.additional-location="file:$LOCAL_DEV/snowstorm.properties" \
    --server.port="$SNOWSTORM_PORT" \
    > "$LOGS/snowstorm.log" 2>&1 &
  echo $! > "$LOGS/snowstorm.pid"
fi

if is_running gateway; then
  echo 'Gateway already running'
else
  echo "Starting gateway on $GATEWAY_PORT"
  GATEWAY_PORT=$GATEWAY_PORT UI_URL="http://localhost:$UI_PORT" REASONER_ID="$REASONER_ID" \
    AS_URL="http://localhost:$AUTHORING_SERVICES_PORT" SNOWSTORM_URL="http://localhost:$SNOWSTORM_PORT" \
    nohup node "$LOCAL_DEV/gateway.js" > "$LOGS/gateway.log" 2>&1 &
  echo $! > "$LOGS/gateway.pid"
fi

wait_for_url "http://localhost:$SNOWSTORM_PORT/version" Snowstorm

if is_running authoring-services; then
  echo 'Authoring Services already running'
else
  echo "Starting Authoring Services on $AUTHORING_SERVICES_PORT"
  mkdir -p "$LOCAL_DEV/data/authoring-services"
  cd "$LOCAL_DEV/data/authoring-services"
  nohup "$JAVA_25" -Xmx2g -jar "$AUTHORING_SERVICES_JAR" \
    --spring.config.additional-location="file:$LOCAL_DEV/authoring-services.properties" \
    --server.port="$AUTHORING_SERVICES_PORT" \
    > "$LOGS/authoring-services.log" 2>&1 &
  echo $! > "$LOGS/authoring-services.pid"
fi

if is_running classification-service; then
  echo 'Classification Service already running'
else
  echo "Starting Classification Service on $CLASSIFICATION_SERVICE_PORT"
  mkdir -p "$LOCAL_DEV/data/classification-service"
  cd "$LOCAL_DEV/data/classification-service"
  # classifying a whole edition (e.g. AU with AMT) needs a large heap
  CLASSIFICATION_JAVA_ARGS=(-Xmx12g -jar "$CLASSIFICATION_SERVICE_JAR")
  if [ -f "$KONCLUDE_PLUGIN_JAR" ]; then
    # Copy the plugin on every start, so the latest build is used but a rebuild while the
    # service runs can't change the jar under it, then extract its native library and
    # start through PropertiesLauncher, which adds loader.path to the class path
    echo "  with Konclude from $KONCLUDE_PLUGIN_JAR"
    rm -rf reasoners native && mkdir -p reasoners native
    cp "$KONCLUDE_PLUGIN_JAR" reasoners/konclude.jar
    unzip -o -q -j reasoners/konclude.jar 'lib/native/macos-arm64/*' -d native
    # --add-opens repeats the jar's Add-Opens manifest entry, which only applies with -jar
    # (the OWL API's Guice needs it); JNI libraries need native access on Java 25
    CLASSIFICATION_JAVA_ARGS=(-Xmx12g --add-opens java.base/java.lang=ALL-UNNAMED --enable-native-access=ALL-UNNAMED
      -Dloader.path="$PWD/reasoners/konclude.jar" -Djava.library.path="$PWD/native"
      -cp "$CLASSIFICATION_SERVICE_JAR" org.springframework.boot.loader.launch.PropertiesLauncher)
  fi
  # shellcheck disable=SC2086 # CLASSIFICATION_JAVA_OPTS is a list of options
  nohup "$JAVA_25" $CLASSIFICATION_JAVA_OPTS "${CLASSIFICATION_JAVA_ARGS[@]}" \
    --spring.config.additional-location="file:$LOCAL_DEV/classification-service.properties" \
    --server.port="$CLASSIFICATION_SERVICE_PORT" \
    > "$LOGS/classification-service.log" 2>&1 &
  echo $! > "$LOGS/classification-service.pid"
fi

if is_running grunt; then
  echo 'UI (grunt serve) already running'
else
  cd "$UI_ROOT"
  echo "Starting UI (grunt serve) on $UI_PORT"
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh"
  nvm use >/dev/null
  UI_PORT=$UI_PORT UI_OPEN_URL=false nohup npx grunt serve > "$LOGS/grunt.log" 2>&1 &
  echo $! > "$LOGS/grunt.pid"
fi

wait_for_url "http://localhost:$AUTHORING_SERVICES_PORT/authoring-services/version" 'Authoring Services'
wait_for_url "http://localhost:$UI_PORT/" UI
wait_for_url "http://localhost:$CLASSIFICATION_SERVICE_PORT/classification-service/version" 'Classification Service'

echo
echo "Ready: http://localhost:$GATEWAY_PORT   (logs in local-dev/logs/)"
