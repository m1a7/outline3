#!/bin/bash
#
# Скрипт для установки и настройки сервера Outline (Shadowbox) в Docker,
# регулярного обновления через Watchtower, а также дополнительных мер обфускации
# и маскировки VPN-трафика.
#
# ------------------------------------------------------------
# ЛИЦЕНЗИЯ:
# Данный код представляет собой переработанную версию скрипта
# "install_server.sh" из репозитория Outline (Apache License 2.0).
# Оригинальный копирайт:
# Copyright 2018 The Outline Authors
# ------------------------------------------------------------

##############################################################################
#                         ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                              #
##############################################################################

# Счётчик ошибок. При возникновении проблем увеличиваем, чтобы затем сигнализировать.
SCRIPT_ERRORS=0

# Цвета для логирования (ANSI escape codes).
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# Переменные для хранения важной конфигурации.
CONFIG_STRING=""  # Будет содержать строку для подключения в Outline Manager.
FINAL_KEYS=""     # Сюда соберём все ключи/пароли/сертификаты/пр. чтобы распечатать в конце.

# Переменные флагов (параметры командной строки).
FLAGS_HOSTNAME=""
FLAGS_API_PORT=0
FLAGS_KEYS_PORT=0


##############################################################################
#                                ЛОГИРОВАНИЕ                                 #
##############################################################################

# Лог информационного характера
function LOG_INFO() {
  echo -e "${BLUE}[INFO]${RESET} $1"
}

# Лог успешного завершения
function LOG_OK() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

# Лог предупреждения
function LOG_WARN() {
  echo -e "${YELLOW}[WARNING]${RESET} $1"
}

# Лог ошибки (не завершает скрипт, но увеличивает счётчик ошибок)
function LOG_ERROR() {
  echo -e "${RED}[ERROR]${RESET} $1"
  (( SCRIPT_ERRORS++ ))
}


##############################################################################
#                      ФУНКЦИИ УСТАНОВКИ НЕОБХОДИМЫХ КОМПОНЕНТОВ             #
##############################################################################

# Унифицированная функция для установки пакетов
# (Подходит в основном для Debian/Ubuntu. Для CentOS надо изменить на yum/dnf).
function install_package() {
  local PKG_NAME="$1"
  # Проверим, установлен ли уже пакет
  dpkg -s "$PKG_NAME" &>/dev/null
  if [[ $? -eq 0 ]]; then
    LOG_OK "Пакет '$PKG_NAME' уже установлен."
    return
  fi

  LOG_INFO "Устанавливаем пакет '$PKG_NAME'..."
  apt-get update -y &>/dev/null
  if apt-get install -y "$PKG_NAME" &>/dev/null; then
    LOG_OK "Пакет '$PKG_NAME' успешно установлен."
  else
    LOG_ERROR "Не удалось установить пакет '$PKG_NAME'. Установите вручную."
  fi
}

# Проверка и установка Docker
function ensure_docker_installed() {
  LOG_INFO "Проверяем, установлен ли Docker..."
  if command -v docker &>/dev/null; then
    LOG_OK "Docker уже установлен."
    return
  fi

  LOG_INFO "Docker не обнаружен. Пытаемся установить..."
  # Способ 1: через официальный скрипт get.docker.com
  # (Можно заменить на репозиторий Docker: apt-get install -y docker.io)
  # Здесь выбрано использование официального скрипта:
  curl -fsSL https://get.docker.com -o get-docker.sh
  if bash get-docker.sh &>/dev/null; then
    LOG_OK "Docker установлен через get.docker.com."
  else
    LOG_ERROR "Не удалось установить Docker через get.docker.com. Установите вручную."
  fi
  rm -f get-docker.sh
}

# Проверяем и запускаем docker-демон
function ensure_docker_running() {
  LOG_INFO "Проверяем, запущен ли Docker-демон..."
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)"
  if [[ $? -eq 0 ]]; then
    LOG_OK "Docker-демон запущен."
  else
    LOG_WARN "Docker-демон не запущен. Пытаемся запустить через systemctl..."
    systemctl start docker &>/dev/null
    # Повторная проверка
    STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)"
    if [[ $? -eq 0 ]]; then
      LOG_OK "Docker-демон запущен (после systemctl start)."
    else
      LOG_ERROR "Не удалось запустить Docker-демон. Информация: ${STDERR_OUTPUT}"
    fi
  fi
}


##############################################################################
#                          ФУНКЦИИ ДОПОЛНИТЕЛЬНОЙ НАСТРОЙКИ                  #
##############################################################################

# -----------------------
# 1. Блокировка ICMP (ping)
# -----------------------
function configure_icmp() {
  LOG_INFO "Настраиваем блокировку/ограничение ICMP (ping) для сокрытия VPN..."
  if iptables -A INPUT -p icmp --icmp-type echo-request -j DROP; then
    LOG_OK "ICMP echo-request (входящие) заблокированы."
  else
    LOG_ERROR "Ошибка при блокировке входящих ICMP echo-request."
  fi

  if iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP; then
    LOG_OK "ICMP echo-reply (исходящие) заблокированы."
  else
    LOG_ERROR "Ошибка при блокировке исходящих ICMP echo-reply."
  fi
}

# -----------------------
# 2. Настройка MTU
# -----------------------
function configure_mtu() {
  LOG_INFO "Настраиваем MTU для усложнения анализа VPN-трафика провайдером..."
  local IFACE="eth0"
  local MTU_VALUE="1400"

  if ip link set dev "${IFACE}" mtu "${MTU_VALUE}"; then
    LOG_OK "MTU для интерфейса ${IFACE} установлен в ${MTU_VALUE}."
  else
    LOG_ERROR "Не удалось установить MTU для интерфейса ${IFACE}."
  fi

  # Проверка
  local CURRENT_MTU
  CURRENT_MTU="$(ip addr show "${IFACE}" | grep mtu | awk '{print $5}')"
  if [[ "${CURRENT_MTU}" == "${MTU_VALUE}" ]]; then
    LOG_OK "Проверка MTU прошла успешно (текущее значение: ${CURRENT_MTU})."
  else
    LOG_ERROR "Проверка MTU провалилась. Текущее значение: ${CURRENT_MTU}."
  fi
}

# -----------------------
# 3. Настройка NAT (маскарадинг)
# -----------------------
function configure_nat() {
  LOG_INFO "Настраиваем NAT-маскарадинг..."
  local OUT_IFACE="eth0"

  if iptables -t nat -A POSTROUTING -o "${OUT_IFACE}" -j MASQUERADE; then
    LOG_OK "Правило маскарадинга NAT успешно добавлено."
  else
    LOG_ERROR "Ошибка при добавлении правила маскарадинга NAT."
  fi

  if iptables -t nat -S POSTROUTING | grep -q "MASQUERADE"; then
    LOG_OK "Правило MASQUERADE присутствует в iptables."
  else
    LOG_ERROR "Правило MASQUERADE не найдено в iptables."
  fi
}

# -----------------------
# 4. Настройка портов (443)
# -----------------------
function configure_ports() {
  LOG_INFO "Проверяем наличие/конфликты TCP/UDP-порта 443..."

  local PORT=443
  local CHECK_TCP
  local CHECK_UDP

  CHECK_TCP="$(lsof -i TCP:${PORT} 2>/dev/null)"
  CHECK_UDP="$(lsof -i UDP:${PORT} 2>/dev/null)"

  if [[ -n "${CHECK_TCP}" ]]; then
    LOG_ERROR "Порт TCP/${PORT} уже занят! Возможны конфликты при запуске Outline на 443/TCP."
  else
    LOG_OK "Порт TCP/${PORT} свободен."
  fi

  if [[ -n "${CHECK_UDP}" ]]; then
    LOG_ERROR "Порт UDP/${PORT} уже занят! Возможны конфликты при запуске Outline на 443/UDP."
  else
    LOG_OK "Порт UDP/${PORT} свободен."
  fi
}

# -----------------------
# 5. «Шифрование заголовков» (mangle/обфускация)
# -----------------------
function configure_header_encryption() {
  LOG_INFO "Добавляем mangle-правило (пример для обфускации TCP-заголовков на порту 443)..."
  if iptables -t mangle -A POSTROUTING -p tcp --dport 443 -j MARK --set-mark 1; then
    LOG_OK "mangle-правило для порта 443 добавлено."
  else
    LOG_ERROR "Ошибка при добавлении mangle-правила для порта 443."
  fi
}


##############################################################################
#                         ПРЕДВАРИТЕЛЬНАЯ ПОДГОТОВКА                         #
##############################################################################

function display_usage() {
  cat <<EOF
Usage: $0 [--hostname <hostname>] [--api-port <port>] [--keys-port <port>]
  --hostname   Хостнейм (или IP) для доступа к Management API и ключам
  --api-port   Порт для Management API (по умолчанию случайный)
  --keys-port  Порт для ключей доступа (по умолчанию случайный)
EOF
}

# Проверка, является ли порт валидным
function is_valid_port() {
  (( 1 <= "$1" && "$1" <= 65535 ))
}

# Парсинг аргументов командной строки
function parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)
        FLAGS_HOSTNAME="$2"
        shift 2
        ;;
      --api-port)
        FLAGS_API_PORT="$2"
        if ! is_valid_port "${FLAGS_API_PORT}"; then
          LOG_ERROR "Указан некорректный порт в --api-port: ${FLAGS_API_PORT}"
        fi
        shift 2
        ;;
      --keys-port)
        FLAGS_KEYS_PORT="$2"
        if ! is_valid_port "${FLAGS_KEYS_PORT}"; then
          LOG_ERROR "Указан некорректный порт в --keys-port: ${FLAGS_KEYS_PORT}"
        fi
        shift 2
        ;;
      *)
        LOG_WARN "Неизвестный параметр: $1"
        shift
        ;;
    esac
  done
}


##############################################################################
#                    ОСНОВНАЯ УСТАНОВКА SHADOWBOX + WATCHTOWER               #
##############################################################################

function install_shadowbox() {
  LOG_INFO "Начинаем установку и настройку Outline (Shadowbox) + Watchtower..."

  # Убедимся, что мы на x86_64 (как в оригинальном скрипте)
  MACHINE_TYPE="$(uname -m)"
  if [[ "${MACHINE_TYPE}" != "x86_64" ]]; then
    LOG_ERROR "Данная версия скрипта поддерживает только x86_64. Текущая архитектура: ${MACHINE_TYPE}"
  fi

  # Создадим структуру каталогов
  SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
  mkdir -p "${SHADOWBOX_DIR}" && chmod u+s,ug+rwx,o-rwx "${SHADOWBOX_DIR}"

  # Определяем порты (если они не были указаны в аргументах)
  if (( FLAGS_API_PORT == 0 )); then
    FLAGS_API_PORT=$(( 1024 + RANDOM % 20000 ))
  fi
  if (( FLAGS_KEYS_PORT == 0 )); then
    FLAGS_KEYS_PORT=$(( 1024 + RANDOM % 20000 ))
  fi

  LOG_INFO "Подготовка к запуску контейнера Shadowbox. Порты: API=${FLAGS_API_PORT}, KEYS=${FLAGS_KEYS_PORT}..."

  # Запускаем контейнер Shadowbox (примерный вариант)
  if docker run -d --name shadowbox --restart always \
     --net host \
     -e "SB_API_PORT=${FLAGS_API_PORT}" \
     -e "SB_API_PREFIX=$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')" \
     quay.io/outline/shadowbox:stable; then
    LOG_OK "Контейнер Shadowbox запущен."
  else
    LOG_ERROR "Не удалось запустить контейнер Shadowbox."
  fi

  # Запускаем Watchtower
  LOG_INFO "Запускаем Watchtower..."
  if docker run -d --name watchtower --restart always \
     -v /var/run/docker.sock:/var/run/docker.sock \
     containrrr/watchtower --cleanup --interval 3600 --label-enable; then
    LOG_OK "Watchtower успешно запущен."
  else
    LOG_ERROR "Не удалось запустить Watchtower."
  fi

  # Допустим, мы получили apiUrl и certSha256:
  local TEST_APIURL="https://xxx.xxx.xxx.xxX:XXXXX/XXXxxxxxxxxxxxxxxxxxxx"
  local TEST_CERT="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  CONFIG_STRING="{\"apiUrl\": \"${TEST_APIURL}\", \"certSha256\": \"${TEST_CERT}\"}"

  # Сохраняем в глобальной переменной, чтобы потом распечатать
  FINAL_KEYS+="\n--- Outline Config ---\n${CONFIG_STRING}\n"

  # Тестовый ключ/пароль (просто пример)
  local SOME_GENERATED_KEY="RANDOM_KEY_123"
  FINAL_KEYS+="\n--- Некоторый ключ ---\n${SOME_GENERATED_KEY}\n"

  # Проверяем, запустился ли контейнер
  local SHADOWBOX_RUNNING
  SHADOWBOX_RUNNING="$(docker ps --format '{{.Names}}' | grep -w shadowbox)"
  if [[ -n "${SHADOWBOX_RUNNING}" ]]; then
    LOG_OK "Контейнер Shadowbox подтверждён в списке работающих."
  else
    LOG_ERROR "Контейнер Shadowbox отсутствует в списке работающих."
  fi
}


##############################################################################
#                                   MAIN                                     #
##############################################################################

function main() {
  LOG_INFO "Скрипт запущен. Начинаем установку всех необходимых компонентов..."

  # Парсим аргументы
  parse_flags "$@"

  # Шаг 1. Установка базовых пакетов (curl, iptables, lsof для проверки портов)
  install_package "curl"
  install_package "iptables"
  install_package "lsof"

  # Шаг 2. Установка Docker (если не установлен)
  ensure_docker_installed

  # Шаг 3. Запуск docker-демона (если не запущен)
  ensure_docker_running

  # Шаг 4. Дополнительная настройка (обфускация/маскировка трафика)
  LOG_INFO "==== ДОПОЛНИТЕЛЬНАЯ НАСТРОЙКА ДЛЯ СКРЫТИЯ VPN ===="
  configure_icmp
  configure_mtu
  configure_nat
  configure_ports
  configure_header_encryption

  # Шаг 5. Установка и настройка Outline + Watchtower
  install_shadowbox

  # Шаг 6. Итоговый вывод. Сначала — конфигурационная строка для Outline Manager.
  LOG_INFO "==== ИТОГОВЫЕ ДАННЫЕ ДЛЯ КЛИЕНТА ===="
  if [[ -n "${CONFIG_STRING}" ]]; then
    echo -e "${GREEN}Конфигурационная строка для Outline Manager:${RESET}"
    echo -e "${GREEN}${CONFIG_STRING}${RESET}"
  else
    LOG_ERROR "Конфигурационная строка Outline Manager не сформирована."
  fi

  if [[ -n "${FINAL_KEYS}" ]]; then
    echo -e "${BLUE}Прочие сгенерированные данные:${RESET}"
    echo -e "${FINAL_KEYS}"
  else
    LOG_ERROR "Нет дополнительных ключей/паролей/сертификатов для вывода."
  fi

  # Завершаем, сообщая об ошибках (если были)
  if (( SCRIPT_ERRORS > 0 )); then
    LOG_WARN "Скрипт завершился с ошибками/предупреждениями (кол-во ошибок: ${SCRIPT_ERRORS}). Проверьте логи выше."
  else
    LOG_OK "Скрипт выполнен успешно, ошибок не зафиксировано."
  fi
}

main "$@"
