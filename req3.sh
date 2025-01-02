#!/usr/bin/env bash
#
# Пример установки Shadowsocks (shadowsocks-libev) + v2ray-plugin в Docker
# с самоподписанными сертификатами и базовой настройкой iptables.
# НЕТ интеграции с Outline Manager.
#

###############################################################################
# Глобальные переменные и настройки
###############################################################################
SCRIPT_ERRORS=0

# Названия контейнеров и директории
SHADOWSOCKS_CONTAINER="shadowsocks_v2ray"
OUTLINE_DIR="/opt/outline"
STATE_DIR="${OUTLINE_DIR}/persisted-state"

# Настройки сети/интерфейса
ETH_INTERFACE="eth0"         # Ваш основной сетевой интерфейс
MTU_VALUE="1400"

# Порт Shadowsocks (на котором будем слушать)
SHADOWSOCKS_PORT="443"
# Метод шифрования (рекомендуем AEAD, напр. chacha20-ietf-poly1305 или aes-256-gcm)
SHADOWSOCKS_METHOD="chacha20-ietf-poly1305"
# Срок действия самоподписанного сертификата
CERT_DAYS="3650"  # ~10 лет

# Docker репозиторий
DOCKER_GPG_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_REPO="https://download.docker.com/linux/ubuntu"

# Цвета для логов
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;36m"    
COLOR_OK="\033[0;32m"      
COLOR_WARN="\033[0;33m"    
COLOR_ERROR="\033[0;31m"   

###############################################################################
# Функции логирования
###############################################################################
LOG_INFO()  { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
LOG_OK()    { echo -e "${COLOR_OK}[OK]${COLOR_RESET}   $*"; }
LOG_WARN()  { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
LOG_ERROR() { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*"; ((SCRIPT_ERRORS++)); }

###############################################################################
# Проверка наличия команды в PATH
###############################################################################
command_exists() {
  command -v "$1" &>/dev/null
}

###############################################################################
# 1. Удаляем старый контейнер (если есть), а также директорию /opt/outline
###############################################################################
remove_old_containers_and_dir() {
  LOG_INFO "Удаляем старый контейнер ($SHADOWSOCKS_CONTAINER) и директорию $OUTLINE_DIR"
  
  # Останавливаем и удаляем контейнер
  if docker ps -a --format '{{.Names}}' | grep -q "^${SHADOWSOCKS_CONTAINER}$"; then
    if ! docker rm -f "${SHADOWSOCKS_CONTAINER}" &>/dev/null; then
      LOG_ERROR "Не удалось удалить контейнер ${SHADOWSOCKS_CONTAINER}"
    else
      LOG_OK "Контейнер ${SHADOWSOCKS_CONTAINER} удалён"
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

  if command_exists docker && docker --version &>/dev/null; then
    LOG_WARN "Docker уже установлен, пропускаем установку."
    return
  fi

  apt-get update -y && apt-get install -y ca-certificates curl gnupg lsb-release
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось установить пакеты (ca-certificates, curl, gnupg, lsb-release)"
    return
  fi
  
  curl -fsSL "${DOCKER_GPG_KEY_URL}" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось загрузить или сохранить GPG-ключ Docker"
    return
  fi

  DISTRO_CODENAME="$(lsb_release -cs)"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${DOCKER_REPO} \
    ${DISTRO_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось установить docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin"
    return
  fi

  systemctl enable docker
  systemctl start docker

  if ! command_exists docker; then
    LOG_ERROR "Docker не был корректно установлен"
  else
    LOG_OK "Docker установлен"
  fi
}

###############################################################################
# 3. Установка необходимых пакетов (iptables, openssl, jq, net-tools, curl и т.д.)
###############################################################################
install_required_packages() {
  LOG_INFO "Устанавливаем необходимые пакеты (iptables, openssl, jq, net-tools, curl и т.д.)"
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

  # Маскарадинг для исходящего трафика
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

  # Устанавливаем MTU
  if ip link set dev "${ETH_INTERFACE}" mtu "${MTU_VALUE}"; then
    LOG_OK "MTU=${MTU_VALUE} установлен на интерфейсе ${ETH_INTERFACE}"
  else
    LOG_ERROR "Не удалось установить MTU=${MTU_VALUE} на интерфейсе ${ETH_INTERFACE}"
  fi
}

###############################################################################
# 5. Генерация самоподписанных сертификатов (для v2ray-plugin с TLS)
###############################################################################
generate_certs() {
  LOG_INFO "Генерируем самоподписанный сертификат и ключ для v2ray-plugin (TLS)"

  mkdir -p "${STATE_DIR}"
  chmod 700 "${OUTLINE_DIR}"
  chmod 700 "${STATE_DIR}"

  local CERTIFICATE_NAME="${STATE_DIR}/ss-selfsigned"
  local SS_CERT_FILE="${CERTIFICATE_NAME}.crt"
  local SS_KEY_FILE="${CERTIFICATE_NAME}.key"

  openssl req -x509 -nodes -days "${CERT_DAYS}" -newkey rsa:2048 \
    -subj "/CN=MyShadowsocksServer" \
    -keyout "${SS_KEY_FILE}" \
    -out "${SS_CERT_FILE}" &>/dev/null

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось сгенерировать сертификат и ключ"
    return 1
  fi

  LOG_OK "Сертификат: ${SS_CERT_FILE}"
  LOG_OK "Приватный ключ: ${SS_KEY_FILE}"
}

###############################################################################
# 6. Запуск контейнера shadowsocks-libev + v2ray-plugin
###############################################################################
start_shadowsocks_v2ray_container() {

  LOG_INFO "Запускаем контейнер Shadowsocks + v2ray-plugin (teddysun/shadowsocks-libev)"

  # Генерируем случайный пароль для Shadowsocks
  local SS_PASSWORD
  SS_PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -d '+/=')"
  [ -z "${SS_PASSWORD}" ] && SS_PASSWORD="defaultPass123"

  # Пути к сертификату/ключу
  local SS_CERT_FILE="${STATE_DIR}/ss-selfsigned.crt"
  local SS_KEY_FILE="${STATE_DIR}/ss-selfsigned.key"

  # Останавливаем и удаляем предыдущий контейнер (если есть)
  docker stop "${SHADOWSOCKS_CONTAINER}" 2>/dev/null || true
  docker rm -f "${SHADOWSOCKS_CONTAINER}" 2>/dev/null || true

  # Запускаем Docker-контейнер
  #
  # Обратите внимание:
  #  - Плагин: "v2ray-plugin"
  #  - PLUGIN_OPTS="server;tls;host=YOUR_DOMAIN;cert=/etc/shadowsocks-libev/tls.crt;key=/etc/shadowsocks-libev/tls.key"
  #  - Пробрасываем порт SHADOWSOCKS_PORT (TCP+UDP)
  #  - Монтируем папку STATE_DIR внутрь контейнера, чтобы plugin мог увидеть ssl-файлы.
  #
  docker run -d \
    --name "${SHADOWSOCKS_CONTAINER}" \
    --restart always \
    --net=host \
    -v "${STATE_DIR}:/etc/shadowsocks-libev" \
    -e SERVER_PORT="${SHADOWSOCKS_PORT}" \
    -e PASSWORD="${SS_PASSWORD}" \
    -e METHOD="${SHADOWSOCKS_METHOD}" \
    -e PLUGIN="v2ray-plugin" \
    -e PLUGIN_OPTS="server;tls;host=example.com;cert=/etc/shadowsocks-libev/ss-selfsigned.crt;key=/etc/shadowsocks-libev/ss-selfsigned.key" \
    teddysun/shadowsocks-libev:latest

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось запустить контейнер ${SHADOWSOCKS_CONTAINER}"
    return 1
  fi

  LOG_OK "Контейнер ${SHADOWSOCKS_CONTAINER} запущен. Порт: ${SHADOWSOCKS_PORT}, пароль: ${SS_PASSWORD}"

  # Сохраним параметры в текстовый файл для удобства
  {
    echo "ssPassword:${SS_PASSWORD}"
    echo "ssMethod:${SHADOWSOCKS_METHOD}"
    echo "ssPort:${SHADOWSOCKS_PORT}"
    echo "tlsCert:${STATE_DIR}/ss-selfsigned.crt"
    echo "tlsKey:${STATE_DIR}/ss-selfsigned.key"
  } > "${OUTLINE_DIR}/ss-config.txt"
}

###############################################################################
# 7. Проверка контейнера и вывод ss:// ссылки
###############################################################################
check_container_and_print_link() {
  LOG_INFO "Проверяем работу контейнера и выводим итоговую ss:// ссылку"

  local RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^${SHADOWSOCKS_CONTAINER}$" && echo 1 || echo 0)
  if [ "${RUNNING}" -eq 1 ]; then
    LOG_OK "Контейнер ${SHADOWSOCKS_CONTAINER} работает"
  else
    LOG_ERROR "Контейнер ${SHADOWSOCKS_CONTAINER} не найден в docker ps"
  fi

  # Проверка порта
  if command_exists ss; then
    if ss -tuln | grep -q ":${SHADOWSOCKS_PORT} "; then
      LOG_OK "Порт ${SHADOWSOCKS_PORT} слушается (TCP/UDP)"
    else
      LOG_WARN "Порт ${SHADOWSOCKS_PORT} не слушается. Проверьте настройки."
    fi
  else
    LOG_WARN "Команда ss не найдена, пропускаем проверку портов"
  fi

  # Выводим ссылку ss://...
  # Читаем сохранённые параметры
  if [ -f "${OUTLINE_DIR}/ss-config.txt" ]; then
    local SS_PASS="$(grep '^ssPassword:' "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2-)"
    local SS_METH="$(grep '^ssMethod:'   "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2- | tr -d ' ')"
    local SS_PORT="$(grep '^ssPort:'     "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2- | tr -d ' ')"

    # Определяем IP
    local PUBLIC_IP="$(curl -s https://icanhazip.com/ | tr -d '\n')"
    [ -z "${PUBLIC_IP}" ] && PUBLIC_IP="127.0.0.1"

    # Формируем base64("method:password")
    local BASE64_PART
    BASE64_PART="$(echo -n "${SS_METH}:${SS_PASS}" | base64 | tr -d '=\n')"

    # Формируем ссылку (пример без plugin=..., так как у Outline-клиента другое формирование;
    # но если вы используете общий Shadowsocks-клиент, добавьте plugin=v2ray-plugin%3b..." и т.п.)
    # Можно добавить "&outline=1", если хотите.
    local SS_URL="ss://${BASE64_PART}@${PUBLIC_IP}:${SS_PORT}?plugin=v2ray-plugin%3bserver%3btls%3bhost%3dexample.com"

    echo
    LOG_INFO "Готовая ссылка Shadowsocks + v2ray-plugin:"
    echo -e "${COLOR_OK}${SS_URL}${COLOR_RESET}"
    echo

    LOG_INFO "Убедитесь, что в plugin-opts клиента укажете: \"v2ray-plugin;tls;host=example.com\""
    LOG_INFO "Если нужно, замените 'example.com' на ваш реальный домен/хост."
  else
    LOG_ERROR "Файл с конфигурацией ${OUTLINE_DIR}/ss-config.txt не найден."
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
  generate_certs          # самоподписанные сертификаты для v2ray-plugin
  start_shadowsocks_v2ray_container
  check_container_and_print_link

  echo
  if [ "${SCRIPT_ERRORS}" -eq 0 ]; then
    LOG_OK "Скрипт выполнен успешно, ошибок не обнаружено."
  else
    LOG_ERROR "Скрипт завершён с проблемами. Количество ошибок: ${SCRIPT_ERRORS}"
  fi
}

# Запуск
main
