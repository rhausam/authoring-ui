#!/usr/bin/env bash
# Show which parts of the local stack are up.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

check() {
  if curl -s -o /dev/null -m 2 "$2"; then
    printf '  %-20s up    %s\n' "$1" "$2"
  else
    printf '  %-20s DOWN  %s\n' "$1" "$2"
  fi
}

check Elasticsearch http://localhost:9200
check Snowstorm "http://localhost:$SNOWSTORM_PORT/version"
check 'Authoring Services' "http://localhost:$AUTHORING_SERVICES_PORT/authoring-services/version"
check 'UI (grunt)' "http://localhost:$UI_PORT/"
check Gateway "http://localhost:$GATEWAY_PORT/local-login"
if port_open 61616; then
  printf '  %-20s up    tcp://localhost:61616\n' ActiveMQ
else
  printf '  %-20s DOWN  tcp://localhost:61616\n' ActiveMQ
fi
