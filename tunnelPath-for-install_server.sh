#!/bin/bash
#
# Enhanced Outline Server Installation Script
# Добавлены функции для затруднения определения туннеля (блокировка ICMP, настройка NAT и MTU)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# ...

set -euo pipefail

# =========================================
# Логирование
# =========================================

function log_command() {
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

function log_error() {
  local -r ERROR_TEXT="\033[0;31m"  # красный
  local -r NO_COLOR="\033[0m"
  echo -e "${ERROR_TEXT}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

function log_start_step() {
  log_for_sentry "$@"
  local -r str="> $*"
  local -ir lineLength=47
  echo -n "${str}"
  local -ir numDots=$(( lineLength - ${#str} - 1 ))
  if (( numDots > 0 )); then
    echo -n " "
    for _ in $(seq 1 "${numDots}"); do echo -n .; done
  fi
  echo -n " "
}

function run_step() {
  local -r msg="$1"
  log_start_step "${msg}"
  shift 1
  if log_command "$@"; then
    echo "OK"
  else
    return
  fi
}

function confirm() {
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

function command_exists {
  command -v "$@" &> /dev/null
}

function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date "+%Y-%m-%d@%H:%M:%S")] install_server.sh" "$@" >> "${SENTRY_LOG_FILE}"
  fi
  echo "$@" >> "${FULL_LOG}"
}

# =========================================
# Переменные для логирования
# =========================================

FULL_LOG="$(mktemp -t outline_logXXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_errorXXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

# =========================================
# Функции установки Outline Server
# =========================================

# ... (Оригинальные функции из вашего скрипта install_server.sh) ...

# =========================================
# Новые функции для повышения скрытности
# =========================================

###############################################################################
# 3. Установка необходимых пакетов (iptables, openssl, jq, net-tools, curl, coreutils и т.д.)
###############################################################################
install_required_packages() {
  log_start_step "Установка необходимых пакетов (iptables, openssl, jq, net-tools, curl, coreutils и т.д.)"
  if apt-get update -y && apt-get install -y iptables openssl jq net-tools curl coreutils; then
    echo "OK"
  else
    log_error "При установке необходимых пакетов произошла ошибка"
    exit 1
  fi
}

###############################################################################
# 4. Настройка NAT, блокировка ICMP, MTU
###############################################################################
setup_iptables_and_network() {
  log_start_step "Настройка iptables (MASQUERADE, блокировка ICMP), MTU"

  # Определение сетевого интерфейса по умолчанию
  ETH_INTERFACE=$(ip route get 1 | awk '{print $5; exit}')
  if [[ -z "${ETH_INTERFACE}" ]]; then
    log_error "Не удалось определить сетевой интерфейс по умолчанию."
    exit 1
  fi

  # Установка значения MTU (можно изменить при необходимости)
  MTU_VALUE=1400

  # Включаем MASQUERADE для исходящего трафика
  if iptables -t nat -A POSTROUTING -o "${ETH_INTERFACE}" -j MASQUERADE; then
    echo "OK"
    log_start_step "MASQUERADE успешно добавлен для интерфейса ${ETH_INTERFACE}"
  else
    log_error "Не удалось добавить правило iptables MASQUERADE"
    exit 1
  fi

  # Блокируем ICMP (ping) входящий и исходящий
  if iptables -A INPUT -p icmp -j DROP && iptables -A OUTPUT -p icmp -j DROP; then
    echo "OK"
    log_start_step "ICMP-запросы блокированы"
  else
    log_error "Не удалось добавить правила iptables для блокировки ICMP"
    exit 1
  fi

  # Устанавливаем MTU на интерфейсе
  if ip link set dev "${ETH_INTERFACE}" mtu "${MTU_VALUE}"; then
    echo "OK"
    log_start_step "MTU=${MTU_VALUE} установлен на интерфейсе ${ETH_INTERFACE}"
  else
    log_error "Не удалось установить MTU=${MTU_VALUE} на интерфейсе ${ETH_INTERFACE}"
    exit 1
  fi
}

# =========================================
# Модифицированная функция установки Shadowbox
# =========================================

install_shadowbox_enhanced() {
  install_required_packages
  setup_iptables_and_network
  install_shadowbox
}

# =========================================
# Функция завершения
# =========================================

function finish {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nLast error: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nSorry! Something went wrong. If you can't figure this out, please copy and paste all this output into the Outline Manager screen, and send it to us, to see if we can help you." >&2
    log_error "Full log: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}

# =========================================
# Основная функция
# =========================================

function main() {
  trap finish EXIT
  declare FLAGS_HOSTNAME=""
  declare -i FLAGS_API_PORT=0
  declare -i FLAGS_KEYS_PORT=0
  parse_flags "$@"
  install_shadowbox_enhanced
}

main "$@"
