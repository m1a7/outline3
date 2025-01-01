#!/bin/bash
#
# Скрипт для отмены (сброса) всех изменений, внесённых предыдущим скриптом:
#  - Удаляет контейнеры Outline (Shadowbox) и Watchtower
#  - Удаляет iptables-правила (блокировку ICMP, правила NAT, mangle)
#  - Сбрасывает MTU на исходное (1500)
#  - Удаляет созданные файлы сертификатов/ключей
#  - Очищает директорию /opt/outline
#
# Все логи цветные, для удобства чтения.
# Скрипт не использует exit (кроме конца), чтобы не прерываться при ошибках.
# ---------------------------------------------------------------------------

##############################################################################
#                         ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                              #
##############################################################################

SCRIPT_ERRORS=0

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"


##############################################################################
#                             ФУНКЦИИ ЛОГИРОВАНИЯ                            #
##############################################################################

function LOG_INFO() {
  echo -e "${BLUE}[INFO]${RESET} $1"
}

function LOG_OK() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

function LOG_WARN() {
  echo -e "${YELLOW}[WARNING]${RESET} $1"
}

function LOG_ERROR() {
  echo -e "${RED}[ERROR]${RESET} $1"
  (( SCRIPT_ERRORS++ ))
}


##############################################################################
#                           СБРОС MTU (ВЕРНУТЬ 1500)                         #
##############################################################################

function reset_mtu() {
  LOG_INFO "Сбрасываем MTU на интерфейсе eth0 (по умолчанию ставим 1500)..."
  local IFACE="eth0"
  local DEFAULT_MTU="1500"

  if ip link set dev "${IFACE}" mtu "${DEFAULT_MTU}"; then
    LOG_OK "MTU на интерфейсе ${IFACE} сброшен до ${DEFAULT_MTU}."
  else
    LOG_ERROR "Не удалось сбросить MTU на интерфейсе ${IFACE}."
  fi

  local CURRENT_MTU
  CURRENT_MTU="$(ip addr show "${IFACE}" | grep mtu | awk '{print $5}')"
  if [[ "${CURRENT_MTU}" == "${DEFAULT_MTU}" ]]; then
    LOG_OK "Проверка MTU: текущее значение ${CURRENT_MTU}."
  else
    LOG_ERROR "Проверка MTU: ожидалось ${DEFAULT_MTU}, но сейчас ${CURRENT_MTU}."
  fi
}


##############################################################################
#      СНЯТИЕ ПРАВИЛ IPTABLES (ICMP, NAT, MANGLE ДЛЯ «ОБФУСКАЦИИ» И Т.Д.)     #
##############################################################################

function reset_iptables() {
  LOG_INFO "Снимаем блокировку ICMP..."

  # Снимаем правила, добавленные ранее:
  #   iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  #   iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  # Аналогично, но с -D (Delete)
  if iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
    LOG_OK "Правило блокировки входящих ICMP (echo-request) удалено."
  else
    LOG_WARN "Не удалось удалить правило INPUT для ICMP. Возможно, оно не было добавлено."
  fi

  if iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP 2>/dev/null; then
    LOG_OK "Правило блокировки исходящих ICMP (echo-reply) удалено."
  else
    LOG_WARN "Не удалось удалить правило OUTPUT для ICMP. Возможно, оно не было добавлено."
  fi

  LOG_INFO "Сбрасываем NAT-маскарадинг..."
  # Удаляем правило:
  #   iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  if iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
    LOG_OK "Правило MASQUERADE (nat) удалено."
  else
    LOG_WARN "Не удалось удалить правило MASQUERADE (nat). Возможно, оно не было добавлено."
  fi

  LOG_INFO "Снимаем примерное mangle-правило..."
  # Удаляем правило:
  #   iptables -t mangle -A POSTROUTING -p tcp --dport 443 -j MARK --set-mark 1
  if iptables -t mangle -D POSTROUTING -p tcp --dport 443 -j MARK --set-mark 1 2>/dev/null; then
    LOG_OK "Mangle-правило для порта 443 удалено."
  else
    LOG_WARN "Не удалось удалить mangle-правило. Возможно, оно не было добавлено."
  fi

  # Другие возможные правила, если что-то ещё добавлялось 
  # (в зависимости от вашей реальной конфигурации) — добавьте сюда.
}


##############################################################################
#                     УДАЛЕНИЕ КОНТЕЙНЕРОВ OUTLINE / WATCHTOWER              #
##############################################################################

function remove_docker_containers() {
  LOG_INFO "Останавливаем и удаляем контейнер Shadowbox..."

  if docker ps -a --format '{{.Names}}' | grep -q "^shadowbox$"; then
    # Контейнер существует
    if docker rm -f shadowbox &>/dev/null; then
      LOG_OK "Контейнер Shadowbox удалён."
    else
      LOG_ERROR "Не удалось удалить контейнер Shadowbox."
    fi
  else
    LOG_WARN "Контейнер Shadowbox не найден среди существующих."
  fi

  LOG_INFO "Останавливаем и удаляем контейнер Watchtower..."
  if docker ps -a --format '{{.Names}}' | grep -q "^watchtower$"; then
    if docker rm -f watchtower &>/dev/null; then
      LOG_OK "Контейнер Watchtower удалён."
    else
      LOG_ERROR "Не удалось удалить контейнер Watchtower."
    fi
  else
    LOG_WARN "Контейнер Watchtower не найден среди существующих."
  fi
}

##############################################################################
#        УДАЛЕНИЕ СЕРТИФИКАТОВ, КЛЮЧЕЙ И САМОЙ ДИРЕКТОРИИ /OPT/OUTLINE        #
##############################################################################

function remove_outline_files() {
  LOG_INFO "Удаляем файлы и каталоги, созданные для Outline..."

  local OUTLINE_DIR="/opt/outline"
  if [[ -d "${OUTLINE_DIR}" ]]; then
    # Удалим всю директорию
    if rm -rf "${OUTLINE_DIR}"; then
      LOG_OK "Директория ${OUTLINE_DIR} удалена."
    else
      LOG_ERROR "Не удалось удалить директорию ${OUTLINE_DIR}."
    fi
  else
    LOG_WARN "Директория ${OUTLINE_DIR} не найдена. Возможно, уже была удалена ранее."
  fi
}


##############################################################################
#                                   MAIN                                     #
##############################################################################

function main() {
  LOG_INFO "Скрипт отката изменений для сервера Outline и дополнительных настроек obfuscation запущен..."

  # 1. Сброс MTU
  reset_mtu

  # 2. Сброс iptables
  reset_iptables

  # 3. Удаление контейнеров Docker (Shadowbox и Watchtower)
  remove_docker_containers

  # 4. Удаление сертификатов/ключей и всей директории /opt/outline
  remove_outline_files

  # Выведем результат
  if (( SCRIPT_ERRORS > 0 )); then
    LOG_WARN "Скрипт отката выполнился с ошибками/предупреждениями (SCRIPT_ERRORS=${SCRIPT_ERRORS}). См. логи выше."
  else
    LOG_OK "Все настройки, внесённые предыдущим скриптом, успешно сброшены."
  fi
}

main "$@"
