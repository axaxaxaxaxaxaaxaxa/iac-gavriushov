#!/usr/bin/env bash
set -euo pipefail

BASE_PREFIX=gavriushov-09

ENV_NAME="${ENV_NAME:-lab}"
WEB_COUNT="${WEB_COUNT:-2}"
APP_PORT="${APP_PORT:-8027}"
GREETING="${GREETING:-cloudlab}"

ZONE_A=ru-central1-d
ZONE_B=ru-central1-a
CIDR_A=10.19.1.0/24
CIDR_B=10.19.2.0/24

BOOT_SIZE=25
IMAGE_FAMILY=ubuntu-2404-lts

while [[ $# -gt 0 ]]; do #Парсинг параметров, передаваемых в команде запуска скрипта
  case "$1" in
    --web-count|--env-name|--app-port|--greeting)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "Не указано значение для $1" >&2
        exit 1
      fi

      case "$1" in
        --web-count) WEB_COUNT="$2" ;;
        --env-name) ENV_NAME="$2" ;;
        --app-port) APP_PORT="$2" ;;
        --greeting) GREETING="$2" ;;
      esac

      shift 2
      ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$WEB_COUNT" =~ ^[1-9][0-9]*$ ]] ||
   (( WEB_COUNT < 2 )); then
  echo "Нужно не меньше двух веб-серверов" >&2
  exit 1
fi

if ! [[ "$APP_PORT" =~ ^[1-9][0-9]*$ ]] ||
   (( APP_PORT > 65535 )); then
  echo "Порт должен быть числом от 1 до 65535" >&2
  exit 1
fi

PREFIX="$BASE_PREFIX-$ENV_NAME"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "Окружение: $ENV_NAME"
echo "Префикс: $PREFIX"
echo "Веб-серверов: $WEB_COUNT"
echo "Порт: $APP_PORT"
echo "Приветствие: $GREETING"

create_if_missing() { # Универсальная функция создания ресурса
  local service="$1"
  local resource="$2"
  local name="$3"
  shift 3

  if yc "$service" "$resource" get \
      --name "$name" >/dev/null 2>&1; then
    echo "$name уже существует, пропускаю"
  else
    yc "$service" "$resource" create --name "$name" "$@"
  fi
}

echo "==> шаблон настройки"

SSH_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
export APP_PORT GREETING SSH_KEY

envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < "$SCRIPT_DIR/cloud-init.tpl.yaml" \
  > "$SCRIPT_DIR/cloud-init.yaml"

echo "==> сеть и подсети"

create_if_missing vpc network "$PREFIX-net"

create_if_missing vpc subnet "$PREFIX-subnet-a" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE_A" \
  --range "$CIDR_A"

create_if_missing vpc subnet "$PREFIX-subnet-b" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE_B" \
  --range "$CIDR_B"

echo "==> NAT-шлюз и маршрутизация"

create_if_missing vpc gateway "$PREFIX-nat"

GW_ID=$(yc vpc gateway get \
  --name "$PREFIX-nat" --format json | jq -r '.id')

create_if_missing vpc route-table "$PREFIX-rt" \
  --network-name "$PREFIX-net" \
  --route "destination=0.0.0.0/0,gateway-id=$GW_ID"

RT_ID=$(yc vpc route-table get \
  --name "$PREFIX-rt" --format json | jq -r '.id')

CURRENT_RT_ID=$(yc vpc subnet get \
  --name "$PREFIX-subnet-a" --format json \
  | jq -r '.route_table_id // empty')

if [[ "$CURRENT_RT_ID" != "$RT_ID" ]]; then
  yc vpc subnet update \
    --name "$PREFIX-subnet-a" \
    --route-table-name "$PREFIX-rt"
fi

echo "==> веб-серверы"

ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  NAME="$PREFIX-web-$i"

  create_if_missing compute instance "$NAME" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --create-boot-disk \
      "name=$NAME-boot,image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE,auto-delete=true" \
    --network-interface \
      "subnet-name=${SUBNETS[$idx]},nat-ip-version=ipv4" \
    --hostname "$NAME" \
    --metadata-from-file "user-data=$SCRIPT_DIR/cloud-init.yaml"
done

echo "==> закрытый сервер приложения"

NAME="$PREFIX-app-1"

create_if_missing compute instance "$NAME" \
  --zone "$ZONE_A" \
  --platform standard-v3 \
  --cores=2 --core-fraction=20 --memory=2 \
  --create-boot-disk \
    "name=$NAME-boot,image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE,auto-delete=true" \
  --network-interface "subnet-name=$PREFIX-subnet-a" \
  --hostname "$NAME" \
  --metadata-from-file "user-data=$SCRIPT_DIR/cloud-init.yaml"

echo "==> целевая группа"

TARGETS=()

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))

  IP=$(yc compute instance get \
    --name "$PREFIX-web-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')

  TARGETS+=(
    --target "subnet-name=${SUBNETS[$idx]},address=$IP"
  )
done

create_if_missing load-balancer target-group "$PREFIX-tg" \
  "${TARGETS[@]}"

echo "==> балансировщик"

TG_ID=$(yc load-balancer target-group get \
  --name "$PREFIX-tg" --format json | jq -r '.id')

create_if_missing load-balancer network-load-balancer "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener \
    "name=http,port=80,target-port=$APP_PORT,external-ip-version=ipv4" \
  --target-group \
    "target-group-id=$TG_ID,healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port=$APP_PORT,healthcheck-http-path=/"

echo "==> ожидание готовности стенда"

# Проверка готовности, а не только окончания создания ВМ
DEADLINE=$((SECONDS + 900))

while (( SECONDS < DEADLINE )); do
  if ENV_NAME="$ENV_NAME" APP_PORT="$APP_PORT" GREETING="$GREETING" \
      bash "$SCRIPT_DIR/check.sh"; then
    echo "Стенд готов"
    exit 0
  fi

  sleep 10
done

echo "Стенд не прошёл проверку за отведённое время" >&2
exit 1