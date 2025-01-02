#!/bin/bash

# Скрипт для отмены всех изменений на сервере, внесённых установочным скриптом Outline Server
# Исключение: Обновления самой ОС остаются нетронутыми

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

# Функция для удаления Docker-контейнеров
remove_docker_containers() {
  CONTAINERS=("shadowsocks" "watchtower")
  for container in "${CONTAINERS[@]}"; do
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      LOG_INFO "Остановка и удаление контейнера Docker: ${container}..."
      if sudo docker rm -f "${container}"; then
        LOG_OK "Контейнер ${container} успешно удалён."
      else
        LOG_ERROR "Не удалось удалить контейнер ${container}."
      fi
    else
      LOG_INFO "Контейнер ${container} не найден. Пропуск."
    fi
  done
}

# Функция для удаления Docker-образов
remove_docker_images() {
  IMAGES=("shadowsocks/shadowsocks-libev" "containrrr/watchtower")
  for image in "${IMAGES[@]}"; do
    if sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
      LOG_INFO "Удаление Docker-образа: ${image}..."
      if sudo docker rmi "${image}"; then
        LOG_OK "Образ ${image} успешно удалён."
      else
        LOG_ERROR "Не удалось удалить образ ${image}."
      fi
    else
      LOG_INFO "Образ ${image} не найден. Пропуск."
    fi
  done
}

# Функция для остановки и удаления Docker
remove_docker() {
  LOG_INFO "Остановка и удаление Docker..."
  if sudo systemctl stop docker && sudo systemctl disable docker; then
    LOG_OK "Docker остановлен и отключён от автозагрузки."
  else
    LOG_ERROR "Не удалось остановить или отключить Docker."
  fi

  if sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    LOG_OK "Пакеты Docker успешно удалены."
  else
    LOG_ERROR "Не удалось удалить пакеты Docker."
  fi

  LOG_INFO "Удаление Docker-репозитория и GPG ключа..."
  if sudo rm -f /etc/apt/sources.list.d/docker.list && sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg; then
    LOG_OK "Docker-репозиторий и GPG ключ успешно удалены."
  else
    LOG_ERROR "Не удалось удалить Docker-репозиторий или GPG ключ."
  fi

  LOG_INFO "Удаление оставшихся файлов Docker..."
  if sudo rm -rf /var/lib/docker /var/lib/containerd; then
    LOG_OK "Оставшиеся файлы Docker удалены."
  else
    LOG_ERROR "Не удалось удалить некоторые файлы Docker."
  fi
}

# Функция для удаления установленных пакетов
remove_packages() {
  PACKAGES=(iptables openssl jq net-tools curl coreutils shadowsocks-libev v2ray-plugin)

  LOG_INFO "Удаление установленных пакетов: ${PACKAGES[*]}..."
  if sudo apt-get purge -y "${PACKAGES[@]}"; then
    LOG_OK "Пакеты успешно удалены."
  else
    LOG_ERROR "Не удалось удалить некоторые из пакетов: ${PACKAGES[*]}."
  fi

  LOG_INFO "Автоочистка неиспользуемых зависимостей..."
  if sudo apt-get autoremove -y; then
    LOG_OK "Неиспользуемые зависимости удалены."
  else
    LOG_ERROR "Не удалось выполнить автоочистку зависимостей."
  fi
}

# Функция для удаления конфигурационных файлов и директорий
remove_configurations() {
  DIRECTORIES=("/opt/shadowsocks" "/opt/certs" "/etc/shadowsocks" "/opt/outline")

  for dir in "${DIRECTORIES[@]}"; do
    if [ -d "${dir}" ]; then
      LOG_INFO "Удаление директории: ${dir}..."
      if sudo rm -rf "${dir}"; then
        LOG_OK "Директория ${dir} успешно удалена."
      else
        LOG_ERROR "Не удалось удалить директорию ${dir}."
      fi
    else
      LOG_INFO "Директория ${dir} не найдена. Пропуск."
    fi
  done
}

# Функция для удаления файлов сертификатов
remove_certificates() {
  CERT_DIR="/etc/shadowsocks"
  if [ -d "${CERT_DIR}" ]; then
    LOG_INFO "Удаление сертификатов в ${CERT_DIR}..."
    if sudo rm -f "${CERT_DIR}/cert.pem" "${CERT_DIR}/key.pem"; then
      LOG_OK "Сертификаты успешно удалены."
    else
      LOG_ERROR "Не удалось удалить сертификаты в ${CERT_DIR}."
    fi
  else
    LOG_INFO "Директория сертификатов ${CERT_DIR} не найдена. Пропуск."
  fi
}

# Функция для удаления файлов Docker
remove_docker_files() {
  FILES=("/etc/shadowsocks/cert.pem" "/etc/shadowsocks/key.pem")

  for file in "${FILES[@]}"; do
    if [ -f "${file}" ]; then
      LOG_INFO "Удаление файла: ${file}..."
      if sudo rm -f "${file}"; then
        LOG_OK "Файл ${file} успешно удалён."
      else
        LOG_ERROR "Не удалось удалить файл ${file}."
      fi
    else
      LOG_INFO "Файл ${file} не найден. Пропуск."
    fi
  done
}

# Функция для очистки системного кеша
clean_system_cache() {
  LOG_INFO "Очистка кеша пакетов APT..."
  if sudo apt-get clean; then
    LOG_OK "Кеш пакетов APT очищен."
  else
    LOG_ERROR "Не удалось очистить кеш пакетов APT."
  fi
}

# Функция для проверки состояния системы после удаления
check_cleanup() {
  LOG_INFO "Проверка, что Docker больше не установлен..."
  if command -v docker &>/dev/null; then
    LOG_WARN "Docker всё ещё установлен."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
  else
    LOG_OK "Docker успешно удалён."
  fi

  LOG_INFO "Проверка, что shadowsocks-libev и v2ray-plugin удалены..."
  for pkg in shadowsocks-libev v2ray-plugin; do
    if dpkg -l | grep -qw "${pkg}"; then
      LOG_WARN "Пакет ${pkg} всё ещё установлен."
      SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    else
      LOG_OK "Пакет ${pkg} успешно удалён."
    fi
  done
}

# Функция для финального вывода
final_output() {
  if [ "${SCRIPT_ERRORS}" -gt 0 ]; then
    LOG_ERROR "Скрипт завершился с ошибками. Пожалуйста, проверьте вышеуказанные сообщения."
  else
    LOG_OK "Скрипт успешно выполнен без ошибок. Все изменения отменены."
  fi
}

# Функция завершения работы скрипта
finish() {
  final_output
}

# Установка ловушки для завершения
trap finish EXIT

# Основная функция
main() {
  # Проверка прав суперпользователя
  if [ "$EUID" -ne 0 ]; then
    LOG_ERROR "Пожалуйста, запустите скрипт с правами суперпользователя (sudo)."
    exit 1
  fi

  LOG_INFO "Начало процесса отката изменений..."

  # Удаление Docker-контейнеров
  remove_docker_containers

  # Удаление Docker-образов
  remove_docker_images

  # Удаление Docker
  remove_docker

  # Удаление установленных пакетов
  remove_packages

  # Удаление конфигурационных файлов и директорий
  remove_configurations

  # Удаление сертификатов
  remove_certificates

  # Удаление файлов Docker, если есть
  remove_docker_files

  # Очистка системного кеша
  clean_system_cache

  # Проверка состояния системы после удаления
  check_cleanup

  LOG_INFO "Процесс отката изменений завершён."
}

main "$@"
