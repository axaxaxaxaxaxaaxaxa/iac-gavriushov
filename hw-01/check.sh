#!/usr/bin/env bash
set -uo pipefail

BASE_PREFIX=gavriushov-09
ENV_NAME="${ENV_NAME:-lab}"
APP_PORT="${APP_PORT:-8027}"
GREETING="${GREETING:-cloudlab}"

PREFIX="$BASE_PREFIX-$ENV_NAME"
RESULT=0

if ! LB_IP=$(yc load-balancer network-load-balancer get \
    --name "$PREFIX-lb" --format json \
    | jq -er '.listeners[0].address // empty'); then
  echo "✗ балансировщик не найден или не удалось получить его адрес"
  echo "✗ распределение запросов проверить невозможно"
  echo "✗ проверка стенда не выполнена: ошибка получения балансировщика"
  exit 1
fi

if HTTP_CODE=$(curl --noproxy '*' -sS \
    --connect-timeout 3 --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://$LB_IP") &&
   [[ "$HTTP_CODE" == "200" ]]; then
  echo "✓ балансировщик отвечает: 200"
else
  echo "✗ балансировщик не вернул HTTP 200"
  RESULT=1
fi

# Проверили балансировщик, теперь проверяем статистику ответов
RESPONSES=""

for i in $(seq 1 20); do
  if BODY=$(curl --noproxy '*' -fsS \
      --connect-timeout 3 --max-time 5 "http://$LB_IP"); then

    case "$BODY" in
      "$GREETING on $PREFIX-web-"*)
        MACHINE="${BODY#"$GREETING on "}"
        NUMBER="${MACHINE#"$PREFIX-web-"}"

        if [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
          RESPONSES="${RESPONSES}${MACHINE}"$'\n'
        fi
        ;;
    esac
  fi
done

MACHINES=$(printf '%s\n' "$RESPONSES" \
  | sed '/^$/d' | sort -u)

COUNT=$(printf '%s\n' "$MACHINES" \
  | sed '/^$/d' | wc -l | tr -d ' ')

if (( COUNT > 1 )); then
  echo "✓ ответили машины: $(printf '%s\n' "$MACHINES" | tr '\n' ' ')"
else
  echo "✗ ответили меньше двух машин: ${MACHINES:-нет ответов}"
  RESULT=1
fi

# Проверка доступности закрытого сервера
if WEB_IP=$(yc compute instance get \
    --name "$PREFIX-web-1" --format json \
    | jq -er \
      '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty') &&
   APP_IP=$(yc compute instance get \
    --name "$PREFIX-app-1" --format json \
    | jq -er \
      '.network_interfaces[0].primary_v4_address.address // empty'); then

  if BODY=$(ssh -n \
      -i "$HOME/.ssh/id_ed25519" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=5 \
      "student@$WEB_IP" \
      "curl --noproxy '*' -fsS --connect-timeout 3 --max-time 5 http://$APP_IP:$APP_PORT") &&
     [[ "$BODY" == "$GREETING on $PREFIX-app-1" ]]; then
    echo "✓ сервер приложения доступен с web-1: $BODY"
  else
    echo "✗ сервер приложения недоступен с web-1 или ответ неверен"
    RESULT=1
  fi
else
  echo "✗ не удалось получить адрес web-1 или app-1"
  RESULT=1
fi

exit "$RESULT"