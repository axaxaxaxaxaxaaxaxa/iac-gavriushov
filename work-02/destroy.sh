#!/usr/bin/env bash
set -euo pipefail

PREFIX=gavriushov-09

# Пустой список означает, что ресурс уже удалён
delete_named() {
  local name="$1"
  shift
  local ids
  local id
  ids=$(yc "$@" list --format json \
    | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')
  for id in $ids; do
    yc "$@" delete --id "$id"
  done
}

delete_named "$PREFIX-lb" load-balancer network-load-balancer
delete_named "$PREFIX-tg" load-balancer target-group

VM_IDS=$(yc compute instance list --format json \
  | jq -r --arg prefix "$PREFIX-app-" \
    '.[] | select(.name | startswith($prefix))
     | select(.name | ltrimstr($prefix) | test("^[0-9]+$")) | .id')
for id in $VM_IDS; do
  yc compute instance delete --id "$id"
done

delete_named "$PREFIX-data" compute disk
delete_named "$PREFIX-subnet-a" vpc subnet
delete_named "$PREFIX-subnet-b" vpc subnet
delete_named "$PREFIX-net" vpc network
