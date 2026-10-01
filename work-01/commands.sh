# Сервисный аккаунт и доступ к каталогу
yc iam service-account get --name gavriushov-09-sa >/dev/null 2>&1 || \
  yc iam service-account create --name gavriushov-09-sa

export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name gavriushov-09-sa --format json | jq -r .id)

yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

# Авторизованный ключ сохраняется вне репозитория
mkdir -p ~/.yc-keys
if [ ! -s ~/.yc-keys/gavriushov-09-key.json ]; then
  yc iam key create --service-account-name gavriushov-09-sa \
    --output ~/.yc-keys/gavriushov-09-key.json
fi

# Параметры, использованные в журнале
export PREFIX=gavriushov-09
export ZONE=ru-central1-d
export CIDR=10.19.1.0/24
export DISK_SIZE=25

# Создание сети и подсети
yc vpc network create --name "$PREFIX-net"
yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

# Создание прерываемой виртуальной машины
yc compute instance create \
  --name "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --hostname "$PREFIX-web-1" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli

# Используется, когда прерываемая машина останавливается
yc compute instance list --format json | jq -r '.[] | select(.status != "RUNNING") | .name'

# Удаление стенда после выполнения работы
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
