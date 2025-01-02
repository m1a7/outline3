#!/bin/bash

# Скрипт для установки и настройки Outline Server с обфускацией через shadowsocks-libev и v2ray-plugin

set -euo pipefail

# Инициализация переменных
SCRIPT_ERRORS=0

# Функции для цветного логирования
LOG_INFO() {
  echo -e "\033[0;34m[INFO]\033[0m $1"
}

LOG_OK() {
  echo -e "\033[0;32m[OK]\033[0m $1"
}

LOG_WARN() {
  echo -e "\033[0;33m[WARN]\033[0m $1"
}

LOG_ERROR() {
  echo -e "\033[0;31m[ERROR]\033[0m $1"
  SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
}

# Функция для установки Docker из официального репозитория
install_docker() {
  LOG_INFO "Добавление GPG ключа Docker..."
  if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
    LOG_ERROR "Не удалось добавить GPG ключ Docker."
    return 1
  fi

  LOG_INFO "Добавление репозитория Docker..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  LOG_INFO "Обновление списка пакетов..."
  if ! sudo apt-get update -y; then
    LOG_ERROR "Не удалось обновить список пакетов."
    return 1
  fi

  LOG_INFO "Установка Docker и необходимых компонентов..."
  if ! sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    LOG_ERROR "Не удалось установить Docker."
    return 1
  fi

  LOG_INFO "Запуск и включение Docker..."
  if ! sudo systemctl start docker && sudo systemctl enable docker; then
    LOG_ERROR "Не удалось запустить Docker."
    return 1
  fi

  LOG_OK "Docker установлен и запущен."
}

# Функция для установки необходимых пакетов
install_packages() {
  REQUIRED_PACKAGES=(iptables openssl jq net-tools curl coreutils shadowsocks-libev v2ray-plugin)

  LOG_INFO "Обновление списка пакетов..."
  if ! sudo apt-get update -y; then
    LOG_ERROR "Не удалось обновить список пакетов."
    return 1
  fi

  LOG_INFO "Установка необходимых пакетов: ${REQUIRED_PACKAGES[*]}..."
  if ! sudo apt-get install -y "${REQUIRED_PACKAGES[@]}"; then
    LOG_ERROR "Не удалось установить некоторые из необходимых пакетов."
    return 1
  fi

  # Проверка доступности команд
  for cmd in "${REQUIRED_PACKAGES[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      LOG_ERROR "Команда $cmd недоступна после установки."
      return 1
    fi
  done

  LOG_OK "Необходимые пакеты установлены и доступны."
}

# Функция для очистки старой конфигурации
clean_old_config() {
  LOG_INFO "Проверка и удаление старых контейнеров Docker..."

  for container in shadowbox watchtower shadowsocks; do
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      LOG_INFO "Удаление контейнера ${container}..."
      if ! sudo docker rm -f "${container}"; then
        LOG_ERROR "Не удалось удалить контейнер ${container}."
      else
        LOG_OK "Контейнер ${container} удален."
      fi
    fi
  done

  if [ -d "/opt/outline" ]; then
    LOG_INFO "Удаление директории /opt/outline..."
    if ! sudo rm -rf /opt/outline; then
      LOG_ERROR "Не удалось удалить директорию /opt/outline."
    else
      LOG_OK "Директория /opt/outline удалена."
    fi
  fi
}

# Функция для генерации самоподписанного сертификата
generate_self_signed_cert() {
  LOG_INFO "Генерация самоподписанного сертификата..."

  CERT_DIR="/opt/certs"
  sudo mkdir -p "${CERT_DIR}"
  sudo chmod 700 "${CERT_DIR}"

  CERT_FILE="${CERT_DIR}/cert.pem"
  KEY_FILE="${CERT_DIR}/key.pem"

  SERVER_IP=$(curl -s ifconfig.me)

  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/CN=${SERVER_IP}" || {
      LOG_ERROR "Не удалось сгенерировать сертификат."
      return 1
    }

  LOG_OK "Самоподписанный сертификат сгенерирован."
}

# Функция для установки shadowsocks-libev с v2ray-plugin
install_shadowsocks() {
  LOG_INFO "Настройка shadowsocks-libev с v2ray-plugin..."

  # Генерация случайного пароля и порта
  SS_PASSWORD=$(openssl rand -base64 16)
  SS_PORT=$(shuf -i 2000-65000 -n 1)

  # Генерация случайного UUID для v2ray-plugin
  V2_UUID=$(cat /proc/sys/kernel/random/uuid)

  # Генерация самоподписанного сертификата
  generate_self_signed_cert

  # Создание конфигурационного файла
  SS_CONFIG_DIR="/opt/shadowsocks"
  sudo mkdir -p "${SS_CONFIG_DIR}"
  sudo chmod 700 "${SS_CONFIG_DIR}"

  SS_CONFIG_FILE="${SS_CONFIG_DIR}/config.json"

  sudo tee "${SS_CONFIG_FILE}" > /dev/null <<EOF
{
    "server":"0.0.0.0",
    "server_port":${SS_PORT},
    "password":"${SS_PASSWORD}",
    "timeout":300,
    "method":"aes-256-gcm",
    "plugin":"v2ray-plugin",
    "plugin_opts":"server;uuid=${V2_UUID};tls;host=${SERVER_IP};cert=/etc/shadowsocks/cert.pem"
}
EOF

  # Копирование сертификата в контейнер
  sudo mkdir -p /etc/shadowsocks
  sudo cp /opt/certs/cert.pem /etc/shadowsocks/

  # Запуск контейнера shadowsocks-libev с v2ray-plugin
  LOG_INFO "Запуск контейнера shadowsocks-libev с v2ray-plugin..."

  if ! sudo docker run -d \
    --name shadowsocks \
    --restart unless-stopped \
    -p "${SS_PORT}:${SS_PORT}/tcp" \
    -p "${SS_PORT}:${SS_PORT}/udp" \
    -v "${SS_CONFIG_DIR}/config.json:/etc/shadowsocks/config.json" \
    -v /etc/shadowsocks/cert.pem:/etc/shadowsocks/cert.pem \
    shadowsocks/shadowsocks-libev \
    ss-server -c /etc/shadowsocks/config.json; then
    LOG_ERROR "Не удалось запустить контейнер shadowsocks."
    return 1
  fi

  LOG_OK "shadowsocks-libev с v2ray-plugin установлен и запущен."
}

# Функция для проверки состояния контейнеров и портов
check_services() {
  LOG_INFO "Проверка состояния контейнеров Docker..."

  for container in shadowsocks watchtower; do
    if sudo docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
      LOG_OK "Контейнер ${container} работает."
    else
      LOG_WARN "Контейнер ${container} не запущен."
      SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
  done

  LOG_INFO "Проверка прослушивающих портов..."

  REQUIRED_PORTS=("${SS_PORT}")
  for port in "${REQUIRED_PORTS[@]}"; do
    if ss -tuln | grep -q ":${port} "; then
      LOG_OK "Порт ${port} слушается."
    else
      LOG_WARN "Порт ${port} НЕ слушается."
      SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
  done
}

# Функция для вывода финальной информации
final_output() {
  LOG_INFO "Генерация строки подключения..."

  METHOD="aes-256-gcm"
  PASSWORD="${SS_PASSWORD}"
  HOST=$(curl -s ifconfig.me)
  PORT="${SS_PORT}"
  PLUGIN="v2ray-plugin"
  PLUGIN_OPTS="tls;host=${HOST};cert=/etc/shadowsocks/cert.pem"

  SS_BASE64=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0)
  SS_URL="ss://${SS_BASE64}@${HOST}:${PORT}?plugin=${PLUGIN}&plugin-opts=${PLUGIN_OPTS}"

  echo -e "\033[1;32mКонфигурация Shadowsocks с обфускацией:\033[0m"
  echo "${SS_URL}"
  echo

  LOG_INFO "Содержимое файла доступа (если применимо):"
  ACCESS_FILE="/opt/shadowsocks/access.txt"
  if [ -f "${ACCESS_FILE}" ]; then
    sudo cat "${ACCESS_FILE}"
  else
    LOG_WARN "Файл доступа ${ACCESS_FILE} не найден."
  fi

  echo
  echo "Инструкции для пользователя:"
  echo "1. Скопируйте строку подключения выше."
  echo "2. Вставьте её в ваш клиент Shadowsocks."
  echo "3. Поскольку используется самоподписанный сертификат, настройте клиент для игнорирования проверок сертификата или добавьте сертификат в доверенные."
  echo "   - В некоторых клиентах можно добавить параметр для игнорирования проверок TLS."
  echo "4. Убедитесь, что соединение устанавливается и работает корректно."

  if [ "${SCRIPT_ERRORS}" -gt 0 ]; then
    LOG_ERROR "Скрипт завершился с ошибками. Пожалуйста, проверьте вышеуказанные сообщения."
  else
    LOG_OK "Скрипт успешно выполнен без ошибок."
  fi
}

# Основная функция
main() {
  # Проверка прав суперпользователя
  if [ "$EUID" -ne 0 ]; then
    LOG_ERROR "Пожалуйста, запустите скрипт с правами суперпользователя (sudo)."
    exit 1
  fi

  # Установка Docker
  install_docker

  # Установка необходимых пакетов
  install_packages

  # Очистка старой конфигурации
  clean_old_config

  # Установка и настройка shadowsocks-libev с v2ray-plugin
  install_shadowsocks

  # Проверка состояния сервисов и портов
  check_services

  # Финальный вывод информации
  final_output
}

main "$@"
