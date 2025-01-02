#!/bin/bash

# Скрипт для установки и настройки Shadowsocks VPN с обфускацией через v2ray-plugin
# Использует Docker-образ, включающий v2ray-plugin

set -euo pipefail

###############################################################################
# Глобальные переменные и настройки
###############################################################################

SCRIPT_ERRORS=0

# Названия контейнеров и директории
SHADOWSOCKS_CONTAINER="shadowsocks_v2ray"
WATCHTOWER_CONTAINER="watchtower"
OUTLINE_DIR="/opt/outline"
STATE_DIR="${OUTLINE_DIR}/persisted-state"

# Диапазон портов для выбора Shadowsocks
PORT_RANGE_START=20000
PORT_RANGE_END=60000

# Метод шифрования (рекомендуем AEAD, напр. chacha20-ietf-poly1305 или aes-256-gcm)
SHADOWSOCKS_METHOD="chacha20-ietf-poly1305"

# Срок действия самоподписанного сертификата
CERT_DAYS="3650"  # ~10 лет

# Docker репозиторий
DOCKER_GPG_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_REPO="https://download.docker.com/linux/ubuntu"

# Введите ваш домен здесь или передайте как аргумент
DOMAIN="${1:-google.com}"

# Цвета для логов
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;36m"    # Голубой
COLOR_OK="\033[0;32m"      # Зелёный
COLOR_WARN="\033[0;33m"    # Жёлтый
COLOR_ERROR="\033[0;31m"   # Красный

###############################################################################
# Функции логирования
###############################################################################
LOG_INFO() {
  echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*" >&2
}

LOG_OK() {
  echo -e "${COLOR_OK}[OK]${COLOR_RESET}   $*" >&2
}

LOG_WARN() {
  echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*" >&2
}

LOG_ERROR() {
  echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2
  ((SCRIPT_ERRORS++))
}

###############################################################################
# Функция проверки наличия команды в PATH
###############################################################################
command_exists() {
  command -v "$1" &>/dev/null
}

###############################################################################
# Функция выбора свободного порта
###############################################################################
find_free_port() {
  LOG_INFO "Ищем свободный порт в диапазоне ${PORT_RANGE_START}-${PORT_RANGE_END}..."

  for ((i=0; i<100; i++)); do
    port=$((RANDOM % (PORT_RANGE_END - PORT_RANGE_START +1) + PORT_RANGE_START))
    if ! ss -tuln | grep -q ":${port} "; then
      # Проверка для UDP
      if ! ss -uln | grep -q ":${port} "; then
        echo "${port}"
        return 0
      fi
    fi
  done

  LOG_ERROR "Не удалось найти свободный порт после 100 попыток в диапазоне ${PORT_RANGE_START}-${PORT_RANGE_END}"
  return 1
}

###############################################################################
# 1. Удаляем старые контейнеры Shadowsocks и Watchtower (если есть),
#    а также директорию /opt/outline
###############################################################################
remove_old_containers_and_dir() {
  LOG_INFO "Удаляем старые контейнеры (${SHADOWSOCKS_CONTAINER}, ${WATCHTOWER_CONTAINER}) и директорию ${OUTLINE_DIR}"

  # Останавливаем и удаляем контейнеры
  for container in "${SHADOWSOCKS_CONTAINER}" "${WATCHTOWER_CONTAINER}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      if ! docker rm -f "${container}" &>/dev/null; then
        LOG_ERROR "Не удалось удалить контейнер ${container}"
      else
        LOG_OK "Контейнер ${container} удалён"
      fi
    fi
  done

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

  # Обновляем apt и устанавливаем зависимости для apt по https
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
# 3. Установка необходимых пакетов (iptables, openssl, jq, net-tools, curl и т.д.)
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
# 4. (Удалён) Настройка NAT, блокировка ICMP, MTU
###############################################################################

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
    -subj "/CN=${DOMAIN}" \
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
  SS_PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -d '+/=' | cut -c1-16)"
  [ -z "${SS_PASSWORD}" ] && SS_PASSWORD="defaultPass123"

  # Пути к сертификату/ключу внутри контейнера
  local SS_CERT_FILE="/etc/shadowsocks-libev/ss-selfsigned.crt"
  local SS_KEY_FILE="/etc/shadowsocks-libev/ss-selfsigned.key"

  # Проверка существования сертификатов
  if [ ! -f "${STATE_DIR}/ss-selfsigned.crt" ] || [ ! -f "${STATE_DIR}/ss-selfsigned.key" ]; then
    LOG_ERROR "Сертификаты не найдены в ${STATE_DIR}. Убедитесь, что функция generate_certs прошла успешно."
    return 1
  fi

  # Останавливаем и удаляем предыдущий контейнер (если есть)
  docker stop "${SHADOWSOCKS_CONTAINER}" &>/dev/null || true
  docker rm -f "${SHADOWSOCKS_CONTAINER}" &>/dev/null || true

  # Запускаем Docker-контейнер
  #
  # Используем Docker-образ teddysun/shadowsocks-libev, который включает v2ray-plugin
  # Конфигурация задаётся через переменные окружения
  #
  docker run -d \
    --name "${SHADOWSOCKS_CONTAINER}" \
    --restart always \
    --net=host \
    -v "${STATE_DIR}:/etc/shadowsocks-libev" \
    -e PASSWORD="${SS_PASSWORD}" \
    -e METHOD="${SHADOWSOCKS_METHOD}" \
    -e PLUGIN="v2ray-plugin" \
    -e PLUGIN_OPTS="server;tls;host=${DOMAIN};cert=${SS_CERT_FILE};key=${SS_KEY_FILE}" \
    teddysun/shadowsocks-libev:latest

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось запустить контейнер ${SHADOWSOCKS_CONTAINER}"
    return 1
  fi

  LOG_OK "Контейнер ${SHADOWSOCKS_CONTAINER} запущен. Пароль: ${SS_PASSWORD}"

  # Сохраним параметры в текстовый файл для удобства
  {
    echo "ssPassword:${SS_PASSWORD}"
    echo "ssMethod:${SHADOWSOCKS_METHOD}"
    echo "ssPort:${SHADOWSOCKS_PORT}"
    echo "tlsCert:${SS_CERT_FILE}"
    echo "tlsKey:${SS_KEY_FILE}"
  } > "${OUTLINE_DIR}/ss-config.txt"

  LOG_OK "Конфигурация сохранена в ${OUTLINE_DIR}/ss-config.txt"
}

###############################################################################
# 7. Запуск Watchtower для автоматического обновления контейнеров
###############################################################################
start_watchtower() {
  LOG_INFO "Запускаем контейнер Watchtower для автоматического обновления"

  docker run -d \
    --name "${WATCHTOWER_CONTAINER}" \
    --restart always \
    --net=host \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower \
      --cleanup \
      --label-enable \
      --scope=outline \
      --interval 3600

  if [ $? -ne 0 ]; then
    LOG_ERROR "Не удалось запустить контейнер ${WATCHTOWER_CONTAINER}"
  else
    LOG_OK "Контейнер ${WATCHTOWER_CONTAINER} запущен"
  fi
}

###############################################################################
# 8. Проверка контейнера и вывод ss:// ссылки
###############################################################################
check_container_and_print_link() {
  LOG_INFO "Проверяем работу контейнера и выводим итоговую ss:// ссылку"

  # Проверка, что контейнер запущен
  local RUNNING
  RUNNING=$(docker inspect -f '{{.State.Running}}' "${SHADOWSOCKS_CONTAINER}" 2>/dev/null || echo "false")
  if [ "${RUNNING}" = "true" ]; then
    LOG_OK "Контейнер ${SHADOWSOCKS_CONTAINER} работает"
  else
    LOG_ERROR "Контейнер ${SHADOWSOCKS_CONTAINER} не работает. Проверьте логи: docker logs ${SHADOWSOCKS_CONTAINER}"
    return 1
  fi

  # Проверка порта на хосте
  if command_exists ss; then
    if ss -tuln | grep -q ":${SHADOWSOCKS_PORT} "; then
      LOG_OK "Порт ${SHADOWSOCKS_PORT} слушается (TCP/UDP)"
    else
      LOG_WARN "Порт ${SHADOWSOCKS_PORT} не слушается. Проверьте настройки контейнера и файрвол."
    fi
  else
    LOG_WARN "Команда ss не найдена, пропускаем проверку портов"
  fi

  # Выводим ссылку ss://...
  # Читаем сохранённые параметры
  if [ -f "${OUTLINE_DIR}/ss-config.txt" ]; then
    local SS_PASS
    SS_PASS="$(grep '^ssPassword:' "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2-)"
    local SS_METH
    SS_METH="$(grep '^ssMethod:'   "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2- | tr -d ' ')"
    local SS_PORT
    SS_PORT="$(grep '^ssPort:'     "${OUTLINE_DIR}/ss-config.txt" | cut -d':' -f2- | tr -d ' ')"

    # Определяем IP
    local PUBLIC_IP
    PUBLIC_IP="$(curl -s https://icanhazip.com/ | tr -d '\n')"
    [ -z "${PUBLIC_IP}" ] && PUBLIC_IP="127.0.0.1"

    # Проверяем, задан ли домен корректно
    if [[ "${DOMAIN}" == "google.com" ]]; then
      LOG_WARN "Вы используете дефолтный домен 'google.com'. Замените его на ваш реальный домен для корректной работы TLS."
    fi

    # Формируем base64("method:password")
    local BASE64_PART
    BASE64_PART="$(echo -n "${SS_METH}:${SS_PASS}" | base64 | tr -d '=\n')"

    # Формируем ссылку
    local SS_URL="ss://${BASE64_PART}@${PUBLIC_IP}:${SS_PORT}?plugin=v2ray-plugin%3bserver%3btls%3bhost%3d${DOMAIN}"

    echo
    LOG_INFO "Готовая ссылка Shadowsocks + v2ray-plugin:"
    echo -e "${COLOR_OK}${SS_URL}${COLOR_RESET}"
    echo

    LOG_INFO "Убедитесь, что в клиенте Shadowsocks настроены следующие параметры плагина:"
    LOG_INFO "  Plugin: v2ray-plugin"
    LOG_INFO "  Plugin Options: server;tls;host=${DOMAIN}"
    echo

    LOG_INFO "Если у вас настроен реальный домен, убедитесь, что сертификат и ключ соответствуют этому домену."
  else
    LOG_ERROR "Файл с конфигурацией ${OUTLINE_DIR}/ss-config.txt не найден."
  fi
}

###############################################################################
# Основная логика (main)
###############################################################################
main() {
  # Проверяем, передан ли домен
  if [ "${DOMAIN}" = "google.com" ]; then
    LOG_WARN "Вы не задали домен. Используется дефолтный 'google.com'. Рекомендуется задать реальный домен."
    LOG_WARN "Для задания домена, запустите скрипт с аргументом: sudo ./setup_shadowsocks.sh yourdomain.com"
  fi

  # Удаляем старые контейнеры и директории
  remove_old_containers_and_dir

  # Устанавливаем Docker
  install_docker

  # Устанавливаем необходимые пакеты
  install_required_packages

  # Генерируем сертификаты
  generate_certs

  # Выбираем свободный порт
  local CHOSEN_PORT
  CHOSEN_PORT=$(find_free_port) || {
    LOG_ERROR "Не удалось выбрать свободный порт. Скрипт завершён с ошибками."
    exit 1
  }
  LOG_OK "Выбран свободный порт: ${CHOSEN_PORT}"

  # Обновляем переменную порта для Shadowsocks
  SHADOWSOCKS_PORT="${CHOSEN_PORT}"

  # Запускаем контейнер Shadowsocks + v2ray-plugin с выбранным портом
  start_shadowsocks_v2ray_container

  # Запускаем Watchtower для автоматических обновлений
  start_watchtower

  # Проверяем контейнер и выводим ss:// ссылку
  check_container_and_print_link

  echo
  if [ "${SCRIPT_ERRORS}" -eq 0 ]; then
    LOG_OK "Скрипт выполнен успешно, ошибок не обнаружено."
  else
    LOG_ERROR "Скрипт завершён с проблемами. Количество ошибок: ${SCRIPT_ERRORS}"
    LOG_ERROR "Проверьте логи выше для детальной информации."
  fi
}

###############################################################################
# Проверка запуска от root
###############################################################################
if [ "$(id -u)" -ne 0 ]; then
  LOG_ERROR "Скрипт должен запускаться от root. Используйте sudo."
  exit 1
fi

# Запуск
main
