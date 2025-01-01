#!/usr/bin/env bash
###############################################################################
#  Скрипт для ПОЛНОГО отката изменений, сделанных req1:
#    1. Удаляет контейнеры shadowbox/watchtower.
#    2. Удаляет директорию /opt/outline (с ключами/сертификатами).
#    3. Снимает правила iptables (блокировку ICMP, NAT).
#    4. Возвращает MTU=1500, отключает net.ipv4.ip_forward.
#    5. (Опционально) Удаляет Docker и репозиторий download.docker.com.
#  ---------------------------------------------------------------------------
#  Используйте на свой страх и риск!
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
#                      1. УДАЛЕНИЕ CONTAINER'ОВ OUTLINE                       #
###############################################################################
function remove_containers() {
  LOG_INFO "Ищем и удаляем контейнеры shadowbox, watchtower..."
  local shadowbox_exists
  shadowbox_exists="$(docker ps -a --format '{{.Names}}' | grep '^shadowbox$' || true)"
  if [[ -n "$shadowbox_exists" ]]; then
    LOG_INFO "Останавливаем/удаляем контейнер shadowbox..."
    docker rm -f shadowbox &>/dev/null \
      && LOG_OK "Контейнер shadowbox удалён." \
      || LOG_ERROR "Не удалось удалить shadowbox."
  else
    LOG_WARN "Контейнер shadowbox не найден."
  fi

  local watchtower_exists
  watchtower_exists="$(docker ps -a --format '{{.Names}}' | grep '^watchtower$' || true)"
  if [[ -n "$watchtower_exists" ]]; then
    LOG_INFO "Останавливаем/удаляем контейнер watchtower..."
    docker rm -f watchtower &>/dev/null \
      && LOG_OK "Контейнер watchtower удалён." \
      || LOG_ERROR "Не удалось удалить watchtower."
  else
    LOG_WARN "Контейнер watchtower не найден."
  fi
}


###############################################################################
#        2. УДАЛЕНИЕ /OPT/OUTLINE (С КЛЮЧАМИ, СЕРТИФИКАТАМИ И ПРОЧИМ)         #
###############################################################################
function remove_outline_directory() {
  local OUTLINE_DIR="/opt/outline"
  if [[ -d "$OUTLINE_DIR" ]]; then
    LOG_INFO "Удаляем директорию ${OUTLINE_DIR} (сертификаты, ключи и прочее)..."
    rm -rf "$OUTLINE_DIR" \
      && LOG_OK "Директория $OUTLINE_DIR удалена." \
      || LOG_ERROR "Не удалось удалить $OUTLINE_DIR."
  else
    LOG_WARN "Директория $OUTLINE_DIR не найдена. Возможно, уже удалена."
  fi
}


###############################################################################
#           3. СНЯТИЕ ПРАВИЛ IPTABLES (ICMP, MASQUERADE) И СБРОС IP_FORWARD   #
###############################################################################
function revert_iptables() {
  LOG_INFO "Сбрасываем iptables-правила, внесённые req1 (ICMP, MASQUERADE)."

  # Удаляем правила, которые блокировали ICMP:
  #   iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  #   iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  iptables -D INPUT -p icmp --icmp-type echo-request -j DROP &>/dev/null \
    && LOG_OK "Удалено правило блокировки входящих ICMP echo-request." \
    || LOG_WARN "Не удалось удалить INPUT-правило. Возможно, его не было."

  iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP &>/dev/null \
    && LOG_OK "Удалено правило блокировки исходящих ICMP echo-reply." \
    || LOG_WARN "Не удалось удалить OUTPUT-правило. Возможно, его не было."

  # Удаляем MASQUERADE (eth0)
  iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE &>/dev/null \
    && LOG_OK "Убрали MASQUERADE на eth0." \
    || LOG_WARN "MASQUERADE на eth0 не найдено/не удалено."

  # Отключаем IP-forward
  LOG_INFO "Отключаем IPv4 forwarding (net.ipv4.ip_forward=0)..."
  sed -i 's/^net\.ipv4\.ip_forward=1/net.ipv4.ip_forward=0/g' /etc/sysctl.conf
  # Перечитываем sysctl
  sysctl -p &>/dev/null
  # Проверка
  local ipfwd
  ipfwd="$(sysctl net.ipv4.ip_forward | awk '{print $3}')"
  if [[ "$ipfwd" == "0" ]]; then
    LOG_OK "Теперь net.ipv4.ip_forward=0."
  else
    LOG_WARN "Не удалось вернуть ip_forward в 0 (текущее значение: ${ipfwd})."
  fi
}


###############################################################################
#                     4. СБРОС MTU ДО ЗНАЧЕНИЯ 1500                           #
###############################################################################
function reset_mtu() {
  LOG_INFO "Сбрасываем MTU на eth0 (1500 по умолчанию)..."
  if ip link set dev eth0 mtu 1500; then
    LOG_OK "MTU=1500 для eth0."
  else
    LOG_ERROR "Не удалось сбросить MTU для eth0."
  fi
}


###############################################################################
#          5. (ОПЦИОНАЛЬНО) УДАЛЕНИЕ DOCKER И РЕПОЗИТОРИЯ download.docker.com #
###############################################################################
function remove_docker() {
  LOG_INFO "Удаляем Docker (docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin)..."
  # ОСТОРОЖНО: эта операция удаляет Docker из системы.
  # Если Docker используется другими сервисами, они будут сломаны!

  # Останавливаем Docker
  systemctl stop docker &>/dev/null || LOG_WARN "Не удалось остановить docker.service (может быть, уже остановлен)."

  # Удаляем пакеты
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    && LOG_OK "Docker и связанные пакеты удалены (purge)." \
    || LOG_ERROR "Ошибка при удалении пакетов Docker."

  # Удаляем репозиторий
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    rm -f /etc/apt/sources.list.d/docker.list \
      && LOG_OK "Файл репозитория Docker (docker.list) удалён." \
      || LOG_WARN "Не удалось удалить docker.list."
  fi

  if [[ -f /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg \
      && LOG_OK "GPG-ключ Docker удалён." \
      || LOG_WARN "Не удалось удалить GPG-ключ Docker."
  fi

  # apt-get update
  apt-get update -y &>/dev/null || LOG_WARN "apt-get update с ошибками после удаления Docker."

  LOG_INFO "Проверка, остался ли docker..."
  if command -v docker &>/dev/null; then
    LOG_WARN "Docker всё ещё виден в системе (возможно, пакеты не полностью удалены)."
  else
    LOG_OK "Docker более не обнаружен в системе."
  fi
}


###############################################################################
#                                 MAIN                                        #
###############################################################################
function main() {
  LOG_INFO "Запущен скрипт ОТКАТА изменений req1..."

  # 1. Удаляем контейнеры shadowbox/watchtower
  remove_containers

  # 2. Удаляем /opt/outline (сертификаты, ключи)
  remove_outline_directory

  # 3. Снимаем iptables-правила (ICMP, MASQUERADE), отключаем ip_forward
  revert_iptables

  # 4. Возвращаем MTU = 1500
  reset_mtu

  # 5. (Опционально) Удаляем Docker (закомментируйте, если не нужно)
  remove_docker

  LOG_INFO "Все основные действия отката выполнены."

  if (( SCRIPT_ERRORS > 0 )); then
    echo -e "${COLOR_RED}В ходе отката возникли ошибки: ${SCRIPT_ERRORS}. См. логи выше.${COLOR_RESET}"
  else
    echo -e "${COLOR_GREEN}Откат завершён без ошибок. Система вернулась в исходное состояние.${COLOR_RESET}"
  fi
}

main "$@"
