#!/usr/bin/env bash
###############################################################################
#  req1: Скрипт для установки и настройки Outline (Shadowbox) + обфускации.
#  ---------------------------------------------------------------------------
#  1. Устанавливает Docker из репозитория Docker (download.docker.com).
#  2. Устанавливает необходимые пакеты: iptables, openssl, jq, net-tools и т.д.
#  3. Удаляет старые версии Outline (shadowbox, watchtower) и старые сертификаты.
#  4. Настраивает NAT (MASQUERADE), блокировку ICMP, MTU.
#  5. Генерирует самоподписанный сертификат, ключи, SHA-256 fingerprint.
#  6. Запускает контейнеры Outline (shadowbox) и Watchtower.
#  7. Выводит конечную конфигурацию (JSON) и инструкции по подключению.
#
#  Скрипт не прерывается при ошибках (не вызывает exit), а логирует их 
#  и в конце оповещает о количестве проблем, если они были.
###############################################################################

#####################
### Цветные логи  ###
#####################
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

function LOG_OK()    { echo -e "${COLOR_GREEN}[OK] ${1}${COLOR_RESET}"; }
function LOG_INFO()  { echo -e "${COLOR_CYAN}[INFO] ${1}${COLOR_RESET}"; }
function LOG_WARN()  { echo -e "${COLOR_YELLOW}[WARN] ${1}${COLOR_RESET}"; }
function LOG_ERROR() { 
  echo -e "${COLOR_RED}[ERROR] ${1}${COLOR_RESET}"
  (( SCRIPT_ERRORS++ ))
}

SCRIPT_ERRORS=0  # счётчик ошибок

###############################################################################
#                 Раздел 1. Проверка и установка необходимых пакетов          #
###############################################################################

# Проверка, запущен ли скрипт от root
function check_root() {
  LOG_INFO "Проверяем, что скрипт запущен под root (или sudo)..."
  if [[ $EUID -ne 0 ]]; then
    LOG_ERROR "Скрипт НЕ под root. Некоторые действия могут не сработать."
  else
    LOG_OK "Скрипт запущен под root."
  fi
}

# Добавляем репозиторий Docker и устанавливаем Docker CE (как в вашем примере)
function install_docker_from_official_repo() {
  LOG_INFO "Проверяем, установлен ли Docker..."
  if ! command -v docker &> /dev/null; then
    LOG_WARN "Docker не обнаружен. Устанавливаем из официального репозитория..."

    # 1) Устанавливаем зависимости
    apt-get update -y || LOG_ERROR "apt-get update не сработал (перед Docker)."
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release \
      || LOG_ERROR "Установка зависимостей для Docker не прошла."

    # 2) Получаем GPG-ключ Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor \
      | tee /usr/share/keyrings/docker-archive-keyring.gpg > /dev/null \
      || LOG_ERROR "Не смогли получить GPG-ключ Docker."

    # 3) Добавляем репозиторий
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null \
      || LOG_ERROR "Не удалось добавить репозиторий Docker."

    # 4) Устанавливаем Docker
    apt-get update -y || LOG_ERROR "apt-get update не сработал (для Docker)."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
      || LOG_ERROR "Не удалось установить Docker CE."

    systemctl enable docker && systemctl start docker \
      || LOG_ERROR "Не удалось запустить Docker через systemctl."

    if command -v docker &> /dev/null; then
      LOG_OK "Docker установлен и запущен."
    else
      LOG_ERROR "Docker не обнаружен после попытки установки."
    fi
  else
    LOG_OK "Docker уже установлен."
    systemctl start docker || LOG_WARN "Не удалось (re)start Docker.service."
  fi
}

# Устанавливаем нужные пакеты из стандартных репозиториев Ubuntu
function install_required_packages() {
  LOG_INFO "Обновляем пакеты и устанавливаем iptables, openssl, jq, net-tools, curl..."
  apt-get update -y || LOG_ERROR "apt-get update не сработал (общий)."
  apt-get install -y iptables openssl jq net-tools curl coreutils \
    || LOG_ERROR "Установка необходимых пакетов (iptables,openssl,jq и т.д.) не прошла."

  command -v iptables &>/dev/null || LOG_ERROR "iptables не установлен."
  command -v openssl  &>/dev/null || LOG_ERROR "openssl не установлен."
  command -v jq       &>/dev/null || LOG_ERROR "jq не установлен."
  command -v netstat  &>/dev/null || LOG_WARN "net-tools (netstat) может быть недоступен."
}

###############################################################################
#       Раздел 2. Очистка старых версий Outline (контейнеров, директорий)     #
###############################################################################

function remove_old_outline() {
  LOG_INFO "Проверяем и удаляем старые контейнеры shadowbox/watchtower, если есть..."
  
  local old_shadowbox
  old_shadowbox="$(docker ps -a --format '{{.Names}}' | grep '^shadowbox$' || true)"
  if [[ -n "$old_shadowbox" ]]; then
    LOG_WARN "Найден старый контейнер shadowbox. Удаляем..."
    docker rm -f shadowbox || LOG_ERROR "Не смогли удалить контейнер shadowbox."
  fi

  local old_watchtower
  old_watchtower="$(docker ps -a --format '{{.Names}}' | grep '^watchtower$' || true)"
  if [[ -n "$old_watchtower" ]]; then
    LOG_WARN "Найден старый контейнер watchtower. Удаляем..."
    docker rm -f watchtower || LOG_ERROR "Не смогли удалить контейнер watchtower."
  fi

  LOG_INFO "Удаляем старые сертификаты, если остались..."
  if [[ -d /opt/outline/persisted-state ]]; then
    rm -rf /opt/outline/persisted-state \
      && LOG_OK "Старая директория persisted-state удалена." \
      || LOG_ERROR "Не смогли удалить /opt/outline/persisted-state."
  fi
}

###############################################################################
#               Раздел 3. Настройка NAT, блокировка ICMP, MTU                #
###############################################################################

function configure_nat() {
  LOG_INFO "Включаем IPv4 forwarding и настраиваем MASQUERADE (eth0)..."

  sed -i 's/#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  sysctl -p | grep "net.ipv4.ip_forward" &>/dev/null \
    && LOG_OK "IPv4 forwarding включён (sysctl)." \
    || LOG_ERROR "Не удалось включить IPv4 forwarding (sysctl)."

  local OUT_IFACE="eth0"
  iptables -t nat -A POSTROUTING -o "$OUT_IFACE" -j MASQUERADE \
    && LOG_OK "iptables MASQUERADE добавлен для $OUT_IFACE." \
    || LOG_ERROR "Не удалось добавить MASQUERADE для $OUT_IFACE."
}

function configure_icmp() {
  LOG_INFO "Ограничиваем ICMP (ping), блокируем echo-request и echo-reply..."

  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP \
    && LOG_OK "ICMP echo-request (вход) заблокирован." \
    || LOG_ERROR "Ошибка при блокировке входящих ICMP echo-request."

  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP \
    && LOG_OK "ICMP echo-reply (выход) заблокирован." \
    || LOG_ERROR "Ошибка при блокировке исходящих ICMP echo-reply."
}

function configure_mtu() {
  LOG_INFO "Устанавливаем MTU=1400 на eth0..."
  ip link set dev eth0 mtu 1400 \
    && LOG_OK "MTU установлен на 1400." \
    || LOG_ERROR "Не удалось изменить MTU на eth0."
}

###############################################################################
#        Раздел 4. Генерация сертификатов/ключей, настройка Outline Server    #
###############################################################################

SHADOWBOX_DIR="/opt/outline"
PERSISTED_STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
ACCESS_CONFIG="${SHADOWBOX_DIR}/access.txt"
API_PORT=443  # Используем порт 443 для Outline

function generate_cert_and_keys() {
  LOG_INFO "Генерируем самоподписанный сертификат + ключ для Outline..."

  mkdir -p "$PERSISTED_STATE_DIR"
  local CERT_NAME="${PERSISTED_STATE_DIR}/shadowbox-selfsigned"
  SB_CERTIFICATE_FILE="${CERT_NAME}.crt"
  SB_PRIVATE_KEY_FILE="${CERT_NAME}.key"

  # Определяем реальный IP (или fallback=127.0.0.1)
  local SERVER_IP
  SERVER_IP=$(curl -4s https://icanhazip.com || echo "127.0.0.1")

  # Генерируем самоподписанный сертификат
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/CN=${SERVER_IP}" \
    -keyout "${SB_PRIVATE_KEY_FILE}" \
    -out "${SB_CERTIFICATE_FILE}" &>/dev/null

  if [[ -s "$SB_CERTIFICATE_FILE" && -s "$SB_PRIVATE_KEY_FILE" ]]; then
    LOG_OK "Сертификат и ключ созданы: ${SB_CERTIFICATE_FILE}, ${SB_PRIVATE_KEY_FILE}."
  else
    LOG_ERROR "Не удалось создать сертификат/ключ."
  fi

  # Генерируем секретный префикс
  LOG_INFO "Генерируем секретный ключ (API_PREFIX)..."
  local random_bytes
  random_bytes="$(head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"
  SB_API_PREFIX="$random_bytes"
  LOG_OK "Секретный ключ API_PREFIX: ${SB_API_PREFIX}"

  # Считаем SHA-256 отпечаток
  local CERT_SHA256
  CERT_SHA256=$(openssl x509 -in "$SB_CERTIFICATE_FILE" -noout -fingerprint -sha256 \
    | sed 's/://g' | sed 's/^.*=//g')

  # Записываем в access.txt
  mkdir -p "$SHADOWBOX_DIR"
  echo > "$ACCESS_CONFIG"  # очистим файл
  echo "apiUrl:https://${SERVER_IP}:${API_PORT}/${SB_API_PREFIX}" >> "$ACCESS_CONFIG"
  echo "certSha256:${CERT_SHA256}" >> "$ACCESS_CONFIG"

  LOG_OK "Записано в $ACCESS_CONFIG: apiUrl, certSha256."
}

OUTLINE_MANAGER_CONFIG=""

function build_outline_manager_config() {
  LOG_INFO "Формируем JSON-строку для Outline Manager..."
  local apiUrl
  local certSha256
  apiUrl=$(grep 'apiUrl:' "$ACCESS_CONFIG" | sed 's/apiUrl://')
  certSha256=$(grep 'certSha256:' "$ACCESS_CONFIG" | sed 's/certSha256://')

  OUTLINE_MANAGER_CONFIG="{\"apiUrl\":\"${apiUrl}\",\"certSha256\":\"${certSha256}\"}"
  LOG_OK "JSON для Outline Manager: ${OUTLINE_MANAGER_CONFIG}"
}

###############################################################################
#   Раздел 5. Запуск контейнеров (Shadowbox + Watchtower), проверка работы    #
###############################################################################

function start_outline_container() {
  LOG_INFO "Готовим скрипт для запуска Shadowbox (Outline Server)..."

  # Официальный образ
  local SB_IMAGE="quay.io/outline/shadowbox:stable"

  local START_SCRIPT="${PERSISTED_STATE_DIR}/start_container.sh"
  cat <<-EOF > "${START_SCRIPT}"
#!/usr/bin/env bash

docker stop shadowbox 2>/dev/null || true
docker rm -f shadowbox 2>/dev/null || true

docker run -d --name shadowbox --restart always --net host \\
  --label "com.centurylinklabs.watchtower.enable=true" \\
  --label "com.centurylinklabs.watchtower.scope=outline" \\
  --log-driver local \\
  -v "${PERSISTED_STATE_DIR}:${PERSISTED_STATE_DIR}" \\
  -e "SB_STATE_DIR=${PERSISTED_STATE_DIR}" \\
  -e "SB_API_PORT=${API_PORT}" \\
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \\
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}" \\
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}" \\
  "${SB_IMAGE}"
EOF

  chmod +x "${START_SCRIPT}"

  # Запуск контейнера
  LOG_INFO "Запускаем контейнер Shadowbox..."
  if bash "${START_SCRIPT}"; then
    LOG_OK "Контейнер Shadowbox запущен."
  else
    LOG_ERROR "Не удалось запустить Shadowbox."
  fi

  LOG_INFO "Запускаем Watchtower для автообновления..."
  docker run -d --name watchtower --restart always \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600 &>/dev/null \
    && LOG_OK "Watchtower успешно запущен." \
    || LOG_ERROR "Ошибка при запуске Watchtower."
}

function test_outline_installation() {
  LOG_INFO "Проверяем запущенные контейнеры и порты..."

  # Проверяем shadowbox
  local sb
  sb="$(docker ps --format '{{.Names}}' | grep '^shadowbox$' || true)"
  if [[ -n "$sb" ]]; then
    LOG_OK "Контейнер shadowbox работает."
  else
    LOG_ERROR "Контейнер shadowbox не обнаружен среди работающих."
  fi

  # Проверяем watchtower
  local wt
  wt="$(docker ps --format '{{.Names}}' | grep '^watchtower$' || true)"
  if [[ -n "$wt" ]]; then
    LOG_OK "Контейнер watchtower работает."
  else
    LOG_ERROR "Контейнер watchtower не обнаружен среди работающих."
  fi

  # Проверим, слушается ли 443 TCP
  LOG_INFO "Проверяем порт 443 (TCP) через ss..."
  if ss -tuln | grep -q ":443 "; then
    LOG_OK "Порт 443 слушается."
  else
    LOG_ERROR "Порт 443 не обнаружен в списке слушающих!"
  fi
}

###############################################################################
#               Раздел 6. Итоговый вывод (ключи, инструкции и т.д.)           #
###############################################################################

function print_instructions() {
  LOG_INFO "Инструкция по использованию Outline VPN:"
  echo "1) Скачайте Outline Manager и введите туда следующую строку (см. ниже)."
  echo "2) Проверьте, что вы не можете «пропинговать» сервер (ICMP блокирован)."
  echo "3) Если что-то не работает, посмотрите логи:"
  echo "   docker logs shadowbox"
  echo "   docker logs watchtower"
}

function print_final_data() {
  LOG_INFO "=== Итоговая конфигурация для Outline Manager ==="
  if [[ -n "${OUTLINE_MANAGER_CONFIG}" ]]; then
    echo -e "${COLOR_GREEN}${OUTLINE_MANAGER_CONFIG}${COLOR_RESET}"
  else
    LOG_ERROR "OUTLINE_MANAGER_CONFIG не сформирован."
  fi

  LOG_OK "=== Содержимое ${ACCESS_CONFIG} ==="
  cat "${ACCESS_CONFIG}"

  if (( SCRIPT_ERRORS > 0 )); then
    echo -e "${COLOR_RED}В ходе скрипта возникло ошибок: ${SCRIPT_ERRORS}. См. логи выше.${COLOR_RESET}"
  else
    echo -e "${COLOR_GREEN}Скрипт req1 выполнен без ошибок!${COLOR_RESET}"
  fi
}

###############################################################################
#                                 MAIN                                        #
###############################################################################

function main() {
  LOG_INFO "Запуск скрипта req1 (установка/настройка Outline + маскировка VPN)..."

  check_root
  install_docker_from_official_repo
  install_required_packages
  remove_old_outline

  configure_nat
  configure_icmp
  configure_mtu

  generate_cert_and_keys
  build_outline_manager_config

  start_outline_container
  test_outline_installation

  print_instructions
  print_final_data
}

main "$@"
