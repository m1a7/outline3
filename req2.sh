#!/usr/bin/env bash
#
# Установочный и конфигурационный скрипт для Outline VPN (Shadowbox + Watchtower),
# включающий удаление старых версий, установку Docker, настройку iptables,
# обфускацию трафика, генерацию сертификатов, запуск контейнеров,
# вывод итоговой конфигурации (JSON) для Outline Manager.
#

###############################################################################
# Глобальные переменные и настройки
###############################################################################

SCRIPT_ERRORS=0            # Счётчик ошибок
SHADOWBOX_CONTAINER="shadowbox"
WATCHTOWER_CONTAINER="watchtower"
OUTLINE_DIR="/opt/outline"
STATE_DIR="${OUTLINE_DIR}/persisted-state"

# Можно настроить при необходимости
ETH_INTERFACE="eth0"       # Ваш основной сетевой интерфейс
MTU_VALUE="1400"

# === Изменено тут ===
#  1) Shadowsocks на 443 (основной VPN/прокси-трафик)
#  2) Management API (Outline Manager) на 8443
SHADOWBOX_API_PORT="8443"  # Порт для Management API (панель управления)
SHADOWSOCKS_PORT="443"     # Порт для Shadowsocks-трафика
# =====================

CERT_DAYS="36500"          # Срок действия самоподписанных сертификатов (≈100 лет)
DOCKER_GPG_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_REPO="https://download.docker.com/linux/ubuntu"
# Или, если вы на Debian, поменяйте `ubuntu` на `debian` в строке выше

# Цвета для логов
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;36m"    # голубой
COLOR_OK="\033[0;32m"      # зелёный
COLOR_WARN="\033[0;33m"    # жёлтый
COLOR_ERROR="\033[0;31m"   # красный

###############################################################################
# Функции логирования
###############################################################################
LOG_INFO() {
  echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"
}

LOG_OK() {
  echo -e "${COLOR_OK}[OK]${COLOR_RESET}   $*"
}

LOG_WARN() {
  echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"
}

LOG_ERROR() {
  echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*"
  ((SCRIPT_ERRORS++))
}

###############################################################################
# Функция проверки наличия команды в PATH
###############################################################################
command_exists() {
  command -v "$1" &>/dev/null
}

###############################################################################
# 1. Удаляем старые контейнеры Shadowbox и Watchtower (если есть),
#    а также директорию /opt/outline
###############################################################################
remove_old_containers_and_dir() {
  LOG_INFO "Удаляем старые контейнеры ($SHADOWBOX_CONTAINER, $WATCHTOWER_CONTAINER) и директорию $OUTLINE_DIR"
  
  # Останавливаем и удаляем контейнеры
  if docker ps -a --format '{{.Names}}' | grep -q "^${SHADOWBOX_CONTAINER}$"; then
    if ! docker rm -f "${SHADOWBOX_CONTAINER}" &>/dev/null; then
      LOG_ERROR "Не удалось удалить контейнер ${SHADOWBOX_CONTAINER}"
    else
      LOG_OK "Контейнер ${SHADOWBOX_CONTAINER} удалён"
    fi
  fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${WATCHTOWER_CONTAINER}$"; then
    if ! docker rm -f "${WATCHTOWER_CONTAINER}" &>/dev/null; then
      LOG_ERROR "Не удалось удалить контейнер ${WATCHTOWER_CONTAINER}"
    else
      LOG_OK "Контейнер ${WATCHTOWER_CONTAINER} удалён"
    fi
  fi

  # Удаляем директорию /opt/outline
  if [ -d "${OUTLINE_DIR}" ]; then
    rm -rf "${OUTLINE_DIR}" 2>/dev/null
    if [ $? -eq 0 ]; then
      LOG_OK "Директория ${OUTLINE_DIR} удалена"
    else
      LOG_ERROR "Не удалось удалить директорию ${OUTLINE_DIR}"
    fi
  fi
}

###############################################################################
# 2. Установка Docker из официального репозитория
###############################################################################
install_docker() {
  LOG_INFO "Устанавливаем Docker из официального репозитория"

  # Проверяем, не установлены ли уже docker-ce и т.п.
  if command_exists docker && docker --version &>/dev/null; then
    LOG_WARN "Docker уже установлен, пропускаем установку."
    return
  fi

  # Обновляем apt и ставим зависимости для apt по https
  apt-get update -y && apt-get install -y ca-certificates curl gnupg lsb-release
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось установить пакеты зависимости (ca-certificates, curl, gnupg, lsb-release)"
    return
  fi
  
  # Добавляем GPG-ключ Docker
  curl -fsSL "${DOCKER_GPG_KEY_URL}" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось загрузить или сохранить GPG-ключ Docker"
    return
  fi

  # Добавляем репозиторий Docker в sources.list.d
  DISTRO_CODENAME="$(lsb_release -cs)"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${DOCKER_REPO} \
    ${DISTRO_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  # Устанавливаем Docker CE, CLI, containerd, docker-compose-plugin
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось установить docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin"
    return
  fi

  # Проверяем, что Docker установлен и включаем сервис
  systemctl enable docker
  systemctl start docker

  if ! command_exists docker; then
    LOG_ERROR "Docker не был корректно установлен"
  else
    LOG_OK "Docker установлен"
  fi
}

###############################################################################
# 3. Установка необходимых пакетов (iptables, openssl, jq, net-tools, curl, coreutils и т.д.)
###############################################################################
install_required_packages() {
  LOG_INFO "Устанавливаем необходимые пакеты (iptables, openssl, jq, net-tools, curl, coreutils и т.д.)"
  apt-get update -y
  apt-get install -y iptables openssl jq net-tools curl coreutils
  if [ $? -ne 0 ]; then
    LOG_ERROR "При установке необходимых пакетов произошла ошибка"
  else
    LOG_OK "Все необходимые пакеты установлены"
  fi
}

###############################################################################
# 4. Настройка NAT, блокировка ICMP, MTU
###############################################################################
setup_iptables_and_network() {
  LOG_INFO "Настраиваем iptables (MASQUERADE, блокировка ICMP), MTU"

  # Включаем MASQUERADE для исходящего трафика (универсально)
  iptables -t nat -A POSTROUTING -o "${ETH_INTERFACE}" -j MASQUERADE
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось добавить правило iptables MASQUERADE"
  else
    LOG_OK "MASQUERADE успешно добавлен для интерфейса ${ETH_INTERFACE}"
  fi

  # Блокируем ICMP (ping) входящий и исходящий
  iptables -A INPUT -p icmp -j DROP
  iptables -A OUTPUT -p icmp -j DROP
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось добавить правила iptables для блокировки ICMP"
  else
    LOG_OK "ICMP-запросы блокированы"
  fi

  # Устанавливаем MTU на интерфейсе
  if ip link set dev "${ETH_INTERFACE}" mtu "${MTU_VALUE}"; then
    LOG_OK "MTU=${MTU_VALUE} установлен на интерфейсе ${ETH_INTERFACE}"
  else
    LOG_ERROR "Не удалось установить MTU=${MTU_VALUE} на интерфейсе ${ETH_INTERFACE}"
  fi
}

###############################################################################
# 5. Генерация сертификатов, ключей, SHA-256 отпечатка
###############################################################################
generate_certs_and_keys() {
  LOG_INFO "Генерируем самоподписанный сертификат и ключ"

  # Создаём /opt/outline и структуру директорий
  mkdir -p "${STATE_DIR}"
  chmod 700 "${OUTLINE_DIR}"
  chmod 700 "${STATE_DIR}"

  local CERTIFICATE_NAME="${STATE_DIR}/shadowbox-selfsigned"
  local SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
  local SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"

  # Пример: -subj "/CN=MyOutlineServer"
  openssl req -x509 -nodes -days "${CERT_DAYS}" -newkey rsa:4096 \
    -subj "/CN=Outline-Server" \
    -keyout "${SB_PRIVATE_KEY_FILE}" \
    -out "${SB_CERTIFICATE_FILE}" &>/dev/null

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось сгенерировать сертификат и ключ"
    return 1
  fi

  LOG_OK "Сертификат: ${SB_CERTIFICATE_FILE}"
  LOG_OK "Приватный ключ: ${SB_PRIVATE_KEY_FILE}"

  LOG_INFO "Генерируем SHA-256 отпечаток сертификата"
  local CERT_OPENSSL_FINGERPRINT
  CERT_OPENSSL_FINGERPRINT=$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint)
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось получить SHA-256 отпечаток"
    return 1
  fi

  # Убираем префикс 'SHA256 Fingerprint=' и двоеточия
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT=$(echo "${CERT_OPENSSL_FINGERPRINT#*=}" | tr -d ':')
  LOG_OK "SHA-256 отпечаток: ${CERT_HEX_FINGERPRINT}"

  # Генерируем API_SECRET (префикс) для Shadowbox
  local RAW_SECRET
  RAW_SECRET=$(head -c 16 /dev/urandom | base64 2>/dev/null)
  # Убираем недопустимые символы +, /, =
  local SB_API_PREFIX
  SB_API_PREFIX=$(echo "${RAW_SECRET}" | tr -d '+/=')
  LOG_OK "Секретный префикс API: ${SB_API_PREFIX}"

  # Сохраняем всё в конфигурационные файлы
  {
    echo "certSha256:${CERT_HEX_FINGERPRINT}"
    echo "apiSecret:${SB_API_PREFIX}"
    echo "certFile:${SB_CERTIFICATE_FILE}"
    echo "keyFile:${SB_PRIVATE_KEY_FILE}"
    echo "apiPort:${SHADOWBOX_API_PORT}"
    echo "ssPort:${SHADOWSOCKS_PORT}"
  } > "${OUTLINE_DIR}/access.txt"

  LOG_OK "Конфигурация записана в ${OUTLINE_DIR}/access.txt"
}

###############################################################################
# 6. Запуск контейнеров Outline (Shadowbox) + Watchtower с --net=host,
#    разделение портов (Management API и Shadowsocks)
###############################################################################
start_outline_containers() {
  LOG_INFO "Запуск контейнеров Shadowbox и Watchtower"

  # Читаем конфиг, чтобы получить нужные переменные
  if [ ! -f "${OUTLINE_DIR}/access.txt" ]; then
    LOG_ERROR "Не найден конфигурационный файл ${OUTLINE_DIR}/access.txt. Пропускаем запуск контейнеров."
    return 1
  fi

  local SB_CERT_FILE="$(grep '^certFile:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)"
  local SB_KEY_FILE="$(grep '^keyFile:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)"
  local SB_API_SECRET="$(grep '^apiSecret:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)"
  local SB_API_PORT_CFG="$(grep '^apiPort:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)"
  local SS_PORT_CFG="$(grep '^ssPort:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)"

  # Создаём start_container.sh
  mkdir -p "${STATE_DIR}"
  local START_SCRIPT="${STATE_DIR}/start_container.sh"
  cat <<EOF > "${START_SCRIPT}"
#!/usr/bin/env bash

# Останавливаем и удаляем, если уже запущено
docker stop "${SHADOWBOX_CONTAINER}" 2>/dev/null || true
docker rm -f "${SHADOWBOX_CONTAINER}" 2>/dev/null || true

docker run -d \\
  --name "${SHADOWBOX_CONTAINER}" \\
  --restart always \\
  --net=host \\
  --label "com.centurylinklabs.watchtower.enable=true" \\
  --label "com.centurylinklabs.watchtower.scope=outline" \\
  --log-driver local \\
  -v "${STATE_DIR}:${STATE_DIR}" \\
  -e "SB_STATE_DIR=${STATE_DIR}" \\
  -e "SB_API_PORT=${SB_API_PORT_CFG}" \\
  -e "SB_API_PREFIX=${SB_API_SECRET}" \\
  -e "SB_CERTIFICATE_FILE=${SB_CERT_FILE}" \\
  -e "SB_PRIVATE_KEY_FILE=${SB_KEY_FILE}" \\
  -e "SHADOWSOCKS_PORT=${SS_PORT_CFG}" \\
  -e "SHADOWSOCKS_PASSWORD=\$(head -c 16 /dev/urandom | base64 | tr -d '+/=')" \\
  -e "SHADOWSOCKS_METHOD=aes-256-gcm" \\
  quay.io/outline/shadowbox:stable
EOF

  chmod +x "${START_SCRIPT}"
  # Запускаем скрипт
  "${START_SCRIPT}" &>/dev/null
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось запустить контейнер ${SHADOWBOX_CONTAINER}"
  else
    LOG_OK "Контейнер ${SHADOWBOX_CONTAINER} запущен"
  fi

  # Запуск Watchtower
  docker stop "${WATCHTOWER_CONTAINER}" 2>/dev/null || true
  docker rm -f "${WATCHTOWER_CONTAINER}" 2>/dev/null || true
  docker run -d \
    --name "${WATCHTOWER_CONTAINER}" \
    --restart always \
    --net=host \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower \
    --cleanup --label-enable --scope=outline --interval 3600 &>/dev/null

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось запустить контейнер ${WATCHTOWER_CONTAINER}"
  else
    LOG_OK "Контейнер ${WATCHTOWER_CONTAINER} запущен"
  fi
}

###############################################################################
# 7. Проверка доступности контейнеров и вывод итоговой конфигурации
###############################################################################
check_containers_and_print_final() {
  LOG_INFO "Проверяем работу контейнеров и выводим итоговую конфигурацию"

  # Смотрим docker ps
  local SHADOWBOX_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^${SHADOWBOX_CONTAINER}$" && echo 1 || echo 0)
  local WATCHTOWER_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^${WATCHTOWER_CONTAINER}$" && echo 1 || echo 0)

  if [ "${SHADOWBOX_RUNNING}" -eq 1 ]; then
    LOG_OK "Контейнер ${SHADOWBOX_CONTAINER} работает"
  else
    LOG_ERROR "Контейнер ${SHADOWBOX_CONTAINER} не найден в docker ps"
  fi

  if [ "${WATCHTOWER_RUNNING}" -eq 1 ]; then
    LOG_OK "Контейнер ${WATCHTOWER_CONTAINER} работает"
  else
    LOG_ERROR "Контейнер ${WATCHTOWER_CONTAINER} не найден в docker ps"
  fi

  # Проверяем, что наши порты слушаются
  if command_exists ss; then
    if ss -tuln | grep -q ":${SHADOWBOX_API_PORT} "; then
      LOG_OK "Management API порт ${SHADOWBOX_API_PORT} слушается"
    else
      LOG_WARN "Порт ${SHADOWBOX_API_PORT} (Management API) не слушается"
    fi

    if ss -tuln | grep -q ":${SHADOWSOCKS_PORT} "; then
      LOG_OK "Shadowsocks порт ${SHADOWSOCKS_PORT} слушается"
    else
      LOG_WARN "Порт ${SHADOWSOCKS_PORT} (Shadowsocks) не слушается"
    fi
  else
    LOG_WARN "Команда ss не найдена, пропускаем проверку портов"
  fi

  # Выводим JSON-строку и инструкции
  if [ -f "${OUTLINE_DIR}/access.txt" ]; then
    local CERT_SHA256=$(grep '^certSha256:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2- | tr -d ' ')
    local API_SECRET=$(grep '^apiSecret:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)
    local API_PORT=$(grep '^apiPort:' "${OUTLINE_DIR}/access.txt" | cut -d':' -f2-)
    
    local PUBLIC_IP="$(curl -s https://icanhazip.com/ | tr -d '\n')"
    [ -z "${PUBLIC_IP}" ] && PUBLIC_IP="127.0.0.1"  # fallback

    local API_URL="https://${PUBLIC_IP}:${API_PORT}/${API_SECRET}"

    echo
    LOG_INFO "JSON-конфигурация для Outline Manager:"
    echo -e "${COLOR_OK}{\"apiUrl\":\"${API_URL}\",\"certSha256\":\"${CERT_SHA256}\"}${COLOR_RESET}"
    echo

    LOG_INFO "Содержимое ${OUTLINE_DIR}/access.txt:"
    cat "${OUTLINE_DIR}/access.txt"
    echo

    LOG_INFO "Скопируйте вышеуказанный JSON в Outline Manager (шаг 'Add Server' / 'Добавить сервер')"
    LOG_INFO "Не забудьте открыть порты 443 (TCP/UDP) и 8443 (TCP) в фаерволе/облаке."
  else
    LOG_ERROR "Файл с конфигурацией не найден. Нечего выводить."
  fi
}

###############################################################################
# Основная логика (main)
###############################################################################
main() {
  remove_old_containers_and_dir
  install_docker
  install_required_packages
  setup_iptables_and_network
  generate_certs_and_keys
  start_outline_containers
  check_containers_and_print_final

  echo
  if [ "${SCRIPT_ERRORS}" -eq 0 ]; then
    LOG_OK "Скрипт выполнен успешно, ошибок не обнаружено."
  else
    LOG_ERROR "Скрипт завершён с проблемами. Количество ошибок: ${SCRIPT_ERRORS}"
  fi
}

# Запуск
main
