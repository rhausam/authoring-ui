#!/usr/bin/env bash
# Stop the processes started by start.sh. Elasticsearch and MariaDB/MySQL are left running.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

for name in gateway grunt authoring-services snowstorm; do
  if is_running "$name"; then
    echo "Stopping $name"
    # grunt is started via npx, so stop its children too
    pkill -P "$(cat "$LOGS/$name.pid")" 2>/dev/null
    kill "$(cat "$LOGS/$name.pid")"
  fi
  rm -f "$LOGS/$name.pid"
done

if port_open 61616; then
  echo 'Stopping ActiveMQ'
  "$ACTIVEMQ_HOME/bin/activemq" stop > /dev/null 2>&1
fi
