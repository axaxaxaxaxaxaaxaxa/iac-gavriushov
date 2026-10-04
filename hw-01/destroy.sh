#!/usr/bin/env bash
set -euo pipefail

BASE_PREFIX=gavriushov-09
ENV_NAME="${ENV_NAME:-lab}"
PREFIX="$BASE_PREFIX-$ENV_NAME"

# Поиск ресурсов по префиксу
find_ids() {
  yc "$@" list --format json \
    | jq -r --arg prefix "$PREFIX-" \
      '.[] | select((.name // "") | startswith($prefix)) | .id'
}

delete_matching() {
  local ids
  local id

  ids=$(find_ids "$@")

  for id in $ids; do
    yc "$@" delete --id "$id"
  done
}

echo "==> балансировщики и целевые группы"

delete_matching load-balancer network-load-balancer
delete_matching load-balancer target-group

echo "==> виртуальные машины"

delete_matching compute instance

echo "==> оставшиеся диски и зарезервированные адреса"

delete_matching compute disk
delete_matching vpc address

echo "==> отвязка таблиц маршрутизации"

SUBNET_IDS=$(find_ids vpc subnet)

for id in $SUBNET_IDS; do
  RT_ID=$(yc vpc subnet get --id "$id" --format json \
    | jq -r '.route_table_id // empty')

  if [[ -n "$RT_ID" ]]; then
    yc vpc subnet update --id "$id" --disassociate-route-table #из документации клауда
  fi
done

echo "==> таблицы маршрутизации и NAT-шлюзы"

delete_matching vpc route-table
delete_matching vpc gateway

echo "==> подсети и сеть"

delete_matching vpc subnet
delete_matching vpc network

echo "Уборка завершена"