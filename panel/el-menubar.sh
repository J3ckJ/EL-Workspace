#!/bin/sh
# SwiftBar / xbar plugin. Refresh about once a minute.
# <xbar.title>EL Workspace</xbar.title>
# <xbar.version>1.0</xbar.version>
set -eu
BASE="${EL_HOST:-http://127.0.0.1:8080}"
if ! PAYLOAD=$(curl -fsS "$BASE/api/panel"); then
  echo "EL"
  echo "---"
  echo "Сервер не запущен | color=#8EA0C5"
  echo "Открыть справку | href=https://github.com/J3ckJ/EL-Workspace/blob/main/docs/local-git.md"
  exit 0
fi
QUEUE=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"queue":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
echo "EL${QUEUE:+:$QUEUE}"
echo "---"
echo "Открыть EL Workspace | href=$BASE/#/"
echo "Панель | href=$BASE/#/panel"
echo "Настройки зеркала | href=$BASE/#/settings/mirrors"
