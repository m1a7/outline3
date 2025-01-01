#!/usr/bin/env bash
###############################################################################
# Скрипт для "отката" изменений, внесённых обновлённым req1:
#   1) Удаляет контейнеры shadowbox и watchtower
#   2) Стирает /opt/outline (включая сертификаты, ключи)
#   3) Снимает iptables-правила (MASQUERADE, блокировку ICMP)
#   4) Возвращает MTU обратно на 1500
#   5) Отключает net.ipv4.ip_forward
#
# Все логи окрашены, скрипт не прерывается при ошибках.
###############################################################################

#####################
### Цветные логи  ###
#####################
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
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
#                   1. Останавливаем и удаляем контейнеры                    #
###############################################################################

function remove_outline_containers() {
  LOG_INFO "Ищем и удаляем контейнеры shadowbox, watchtower (если они есть)..."

  local sb
  sb="$(docker ps -a --format '{{.Names}}' | grep '^shadowbox$' || true)"
  if [[ -n "$sb" ]]; then
    if docker rm -f shadowbox &>/dev/null; then
      LOG_OK "Контейнер shadowbox удалён."
    else
      LOG_ERROR "Не удалось удалить контейнер shadowbox."
    fi
  else
    LOG_WARN "Контейнер shadowbox не найден."
  fi

  local wt
  wt="$(docker ps -a --format '{{.Names}}' | grep '^watchtower$' || true)"
  if [[ -n "$wt" ]]; then
    if docker rm -f watchtower &>/dev/null; then
      LOG_OK "Контейнер watchtower удалён."
    else
      LOG_ERROR "Не удалось удалить контейнер watchtower."
    fi
  else
    LOG_WARN "Контейнер watchtower не найден."
  fi
}

###############################################################################
#                2. Удаляем директорию /opt/outline (сертификаты)            #
###############################################################################

function remove_outline_directory() {
  LOG_INFO "Удаляем /opt/outline (если существует)..."
  if [[ -d "/opt/outline" ]]; then
    if rm -rf "/opt/outline"; then
      LOG_OK "Директория /opt/outline удалена."
    else
      LOG_ERROR "Не удалось удалить /opt/outline."
    fi
  else
    LOG_WARN "Директория /opt/outline не найдена."
  fi
}

###############################################################################
#               3. Сброс iptables (ICMP-блокировка, MASQUERADE)              #
###############################################################################

function reset_iptables() {
  LOG_INFO "Снимаем iptables-правила, добавленные скриптом req1..."

  # 3.1. Снимаем блокировку ICMP:
  #    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  #    iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  if iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
    LOG_OK "Удалено правило блокировки входящих ICMP echo-request."
  else
    LOG_WARN "Правило INPUT для ICMP echo-request не найдено (или уже удалено)."
  fi

  if iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP 2>/dev/null; then
    LOG_OK "Удалено правило блокировки исходящих ICMP echo-reply."
  else
    LOG_WARN "Правило OUTPUT для ICMP echo-reply не найдено (или уже удалено)."
  fi

  # 3.2. Снимаем MASQUERADE:
  #    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  local OUT_IFACE="eth0"
  if iptables -t nat -D POSTROUTING -o "$OUT_IFACE" -j MASQUERADE 2>/dev/null; then
    LOG_OK "Правило MASQUERADE в POSTROUTING удалено."
  else
    LOG_WARN "Правило MASQUERADE (nat) не найдено (или уже удалено)."
  fi
}

###############################################################################
#         4. Возвращаем MTU на eth0 обратно к 1500 (по умолчанию)            #
###############################################################################

function reset_mtu() {
  LOG_INFO "Сбрасываем MTU на 1500 на интерфейсе eth0..."
  if ip link set dev eth0 mtu 1500; then
    LOG_OK "MTU восстановлен (1500)."
  else
    LOG_ERROR "Не удалось вернуть MTU=1500 на eth0."
  fi
}

###############################################################################
#         5. Отключаем net.ipv4.ip_forward (возвращаем в default=0)          #
###############################################################################

function disable_ip_forward() {
  LOG_INFO "Отключаем net.ipv4.ip_forward (возвращаем =0 в /etc/sysctl.conf)..."
  sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=0/' /etc/sysctl.conf

  # Считываем заново
  if sysctl -p | grep -q 'net.ipv4.ip_forward = 0'; then
    LOG_OK "net.ipv4.ip_forward успешно отключён."
  else
    LOG_ERROR "Не удалось отключить net.ipv4.ip_forward."
  fi
}

###############################################################################
#                                  MAIN                                       #
###############################################################################

function main() {
  LOG_INFO "Скрипт отката изменений req1 запущен..."

  remove_outline_containers
  remove_outline_directory
  reset_iptables
  reset_mtu
  disable_ip_forward

  # Итоговый вывод
  if (( SCRIPT_ERRORS > 0 )); then
    echo -e "${COLOR_RED}Скрипт завершён с ошибками (кол-во: ${SCRIPT_ERRORS}). Проверьте логи выше.${COLOR_RESET}"
  else
    echo -e "${COLOR_GREEN}Все внесённые req1 изменения отменены успешно. Ошибок не обнаружено.${COLOR_RESET}"
  fi
}

main "$@"
