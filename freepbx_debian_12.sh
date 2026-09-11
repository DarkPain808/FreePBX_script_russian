#!/bin/bash
#####################################################################################

VERSION="1.0"
export LC_ALL=C

#####################################################################################
#
#                 Скрипт установки FreePBX 17 на Debian 12 (bookworm)
#
# ВЕРСИЯ: 1.0
# ОПУБЛИКОВАНО: 10 сентября 2026 года, 12:00 GMT
# ЛИЦЕНЗИЯ: GNU General Public License v3.0
#
# ОТКАЗ ОТ ОТВЕТСТВЕННОСТИ:
# Содержимое предоставляется «как есть», без каких-либо гарантий,
# явных или подразумеваемых. Вы можете изменять, распространять и использовать
# этот скрипт; разработчик не несёт ответственности за любой ущерб или
# проблемы, возникшие в результате использования.
#
# НАЗНАЧЕНИЕ:
# Автоматизированная установка FreePBX 17 с минимальным ручным вмешательством.
# Скрипт выполняет предустановочные проверки, настраивает окружение,
# загружает и запускает официальный установщик FreePBX, а затем
# проверяет корректность развёртывания.
#
# ВНИМАНИЕ:
# Тщательно протестируйте скрипт в контролируемой среде перед
# развёртыванием на production-сервере.
#
#####################################################################################
#
#    Команды запуска
#
#    bash Freepbx17_debian12.sh              Полная установка с screen и всеми проверками
#    bash Freepbx17_debian12.sh --menu       Интерактивное меню из 15 пунктов
#    bash Freepbx17_debian12.sh --full       Полная установка без меню, с индикацией шагов
#
#####################################################################################


# ===================================================================================
# СТРОГИЙ РЕЖИМ И КОНСТАНТЫ
# ===================================================================================


# Прерывать скрипт при любой ошибке, неинициализированной переменной
# или сбое в конвейере (pipe)
set -euo pipefail

# --- Пороговые значения для проверки системы ---
REQUIRED_DISK_KB=10485760       # Минимум 10 ГБ свободного места на /
MIN_RAM_MB=900                  # Минимум 900 МБ RAM (иначе — ошибка)
MIN_RAM_WARN_MB=1000            # Предупреждение, если RAM < 1 ГБ
MIN_SWAP_MB=100                 # Минимум 100 МБ swap (если RAM мала)

# --- Тайм-ауты и повторы (в секундах) ---
APT_LOCK_TIMEOUT_S=300          # Ожидание снятия блокировки APT перед update
APT_LOCK_INSTALL_TIMEOUT_S=120  # Ожидание снятия блокировки APT перед install
MIRROR_MAX=3                    # Количество попыток проверки зеркал
MIRROR_RETRY_DELAY_S=30        # Пауза между попытками проверки зеркал
GUI_RETRY_MAX=3                 # Количество попыток проверки веб-интерфейса
GUI_RETRY_DELAY_S=10            # Пауза между попытками проверки GUI
RELOAD_RETRY_DELAY_S=15         # Пауза между попытками перезагрузки FreePBX

# --- Прочее ---
SLEEP_DELAY=0.5                 # Короткая пауза между шагами для читаемости вывода


# ===================================================================================
# ГЛОБАЛЬНЫЕ ФЛАГИ И ПЕРЕМЕННЫЕ
# ===================================================================================


# --- Режимы запуска ---
SKIP_CHECKS=false               # --skip-checks: пропустить предустановочные проверки
IS_NONINTERACTIVE=false         # Автоопределение: нет TTY → неинтерактивный режим
IS_HEQET=false                  # Запуск с ISO-образа Heqet (особый путь очистки)
RUN_FULL=false                  # --full: полная установка без меню
MENU_MODE=false                 # --menu: интерактивное меню

# --- Выбор зеркала FreePBX ---
SELECTED_MIRROR=""              # URL APT-репозитория
SELECTED_MIRROR_NAME=""         # Человекочитаемое имя зеркала
SELECTED_MIRROR_GPG=""          # URL GPG-ключа зеркала

# --- Доступные зеркала (имя | APT-URL | URL GPG-ключа) ---
MIRRORS=(
  "git.freepbx.asterisk.ru|http://git.freepbx.asterisk.ru/freepbx17-prod|http://git.freepbx.asterisk.ru/gpg/aptly-pubkey.asc"
  "deb.freepbx.org (официальное)|http://deb.freepbx.org/freepbx-17-prod|http://deb.freepbx.org/freepbx-17-prod/pubkey.gpg"
)

# --- Разбор аргументов командной строки ---
if [[ "${1:-}" == "--skip-checks" ]]; then
  SKIP_CHECKS=true
fi

if [[ "${1:-}" == "--menu" ]]; then
  MENU_MODE=true
fi

if [[ "${1:-}" == "--full" ]]; then
  RUN_FULL=true
fi

# Если stdin не привязан к терминалу — считаем запуск неинтерактивным
# (например, через pipe: curl ... | sh)
if [ ! -t 0 ]; then
  IS_NONINTERACTIVE=true
fi

# Запоминаем время старта для отчёта о длительности установки
START_TIME=$(date +%s)


# ===================================================================================
# ЦВЕТА ВЫВОДА (ANSI escape-коды)
# Используются только для терминального вывода; в лог-файлы попадают
# как литералы, что нормально для диагностики.
# ===================================================================================


BGRN='\033[1;32m'          # Жирный зелёный  — успех, готовность
BRED='\033[1;31m'          # Жирный красный  — ошибки, прерывание
CYAN='\033[38;5;51m'       # Циан            — информационные сообщения, прощание
BYEL='\e[93m'              # Жирный жёлтый   — предупреждения, меню
WHT='\033[1;37m'           # Жирный белый    — обычный текст, пояснения
NC='\033[0m'               # Сброс           — возврат к стандартному цвету
BMAG='\033[1;35m'          # Жирный пурпурный — заголовки блоков, рамки меню


# ===================================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ===================================================================================


# --- Таймер обратного отсчёта ---
# Выводит секунды до следующей попытки, затирая строку каждую секунду.
countdown() {
  local secs=$1
  local i=$secs
  while [ "$i" -ge 1 ]; do
    printf "\r  ${BYEL}Повтор через %2s...${NC}" "$i"
    sleep 1
    i=$((i - 1))
  done
  printf "\r                        \r"
}

# --- Вывод заголовка шага ---
# Зелёная строка-разделитель перед каждым этапом установки.
print_step() {
  echo -e "\n${BGRN}$1${NC}\n"
}

# --- Обработчик сбоя установки FreePBX ---
# Вызывается, если официальный установщик завершился с ошибкой.
# Выводит диагностику и завершает скрипт.
handle_install_failure() {
  local line="────────────────────────────────────────────────────────"

  echo
  echo -e "${BRED}ВНИМАНИЕ: Установка FreePBX 17 завершилась с ошибкой.${NC}"
  echo -e "${WHT}Это сбой официального установщика FreePBX.${NC}"
  echo -e "$line"

  echo -e "${WHT}Возможные причины:${NC}"
  echo -e "  ${BYEL}• Пакет не установился — отсутствует зависимость или устаревший репозиторий${NC}"
  echo -e "  ${BYEL}• Asterisk не запустился — сломанный модуль или неверная конфигурация${NC}"
  echo -e "  ${BYEL}• GUI не работает — сбой Apache или неверная конфигурация PHP${NC}"
  echo -e "$line"

  echo -e "${WHT}Диагностика:${NC}"
  printf "  ${BYEL}%-45s${WHT}%s${NC}\n" \
    "Логи установки FreePBX:"        "cat /var/log/pbx/freepbx-*.log" \
    "Статус Asterisk:"               "systemctl status asterisk" \
    "Ошибки во время установки:"     "tail -n 100 /var/log/asterisk/full" \
    "Перезапуск FreePBX:"            "fwconsole restart"

  echo
  echo -e "  ${BYEL}WinSCP: SCP → ваш IP → порт 22 → /var/log/pbx/freepbx-*.log${NC}"
  echo
  echo -e "$line"

  echo -e "${BRED}Скрипт завершает работу.${CYAN} До свидания.${NC}"
  exit 1
}

# --- Ожидание освобождения блокировок APT/dpkg ---
# Если другой процесс пакетного менеджера держит lock-файлы,
# ждёт до max_wait секунд, затем прерывает выполнение.
wait_apt_lock() {
  local max_wait="${1:-$APT_LOCK_TIMEOUT_S}"
  local wait=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
        /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if [ "$wait" -eq 0 ]; then
      echo -e "${BYEL}Другой менеджер пакетов запущен. Ожидание завершения...${NC}"
    fi
    wait=$((wait + 1))
    if [ "$wait" -ge "$max_wait" ]; then
      echo -e "${BRED}Блокировка APT удерживается более $((max_wait / 60)) мин. Завершение работы.${NC}"
      exit 1
    fi
    sleep 1
  done
  if [ "$wait" -gt 0 ]; then
    echo -e "Блокировка снята через ${wait} секунд. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "Блокировки APT не обнаружены. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY
}

# --- Проверка существующей установки ---
# Универсальная функция: принимает имя компонента и команду проверки.
# Если компонент уже установлен — прерывает выполнение.
check_existing_install() {
  local name="$1"
  local check_cmd="$2"

  print_step "Проверка существующей установки $name..."
  if eval "$check_cmd"; then
    if [ "$IS_HEQET" = true ]; then
      echo -e "${BRED}Остановка. $name уже установлен(а).${NC}"
      echo
      echo -e "${WHT}Предыдущая установка могла завершиться с ошибкой или быть выполнена частично.${NC}"
      echo -e "${WHT}Загрузитесь с ISO-образа Heqet, чтобы начать новую установку.${NC}"
      echo
      echo -e "${CYAN}Скрипт завершает работу. До свидания.${NC}"
      echo
    else
      echo -e "${BRED}Остановка. $name уже установлен(а). Скрипт не предназначен для обновления поверх существующей установки.${NC}"
      echo
    fi
    exit 1
  else
    echo -e "Существующая установка $name не найдена. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  fi
}

# --- Финальное сообщение об успешной установке ---
# Выводит сводку: IP-адрес, URL входа, затраченное время.
print_completion() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  local ip=$(hostname -I | awk '{print $1}')
  local border="════════════════════════════════════════════════════════"

  echo
  echo "${border}"
  echo -e "${BGRN}  Установка FreePBX 17 успешно завершена!${NC}"
  echo "${border}"
  echo
  echo -e "  Версия скрипта: ${WHT}${VERSION}${NC}"
  echo -e "  IP-адрес сервера: ${BGRN}${ip}${NC}"
  echo -e "  URL для входа: ${BGRN}http://${ip}${NC}"
  echo -e "  Длительность установки: ${WHT}${minutes} мин ${seconds} сек${NC}"
  echo
  echo "${border}"
  echo -e "${CYAN}  До свидания. Спасибо за использование скрипта.${NC}"
  echo "${border}"
  echo
}


# ===================================================================================
# ФУНКЦИИ ПРОВЕРКИ ЗЕРКАЛ FreePBX
# Проверяют доступность зеркал модулей и APT-репозитория через
# внешний сервис mirrors.in1.click
# ===================================================================================


MIRROR_ATTEMPTS=0           # Счётчик выполненных попыток в текущем цикле
MIRROR_OK=false             # Флаг: хотя бы одно зеркало прошло проверку
MIRROR_GOOD_COUNT=0         # Количество успешных проверок из MIRROR_MAX
mirror_status=""            # Статус зеркал модулей: good/warn/bad/server/unreachable/unknown
deb_status=""               # Статус APT-репозитория: good/captcha/bad/invalid/unknown

# --- Однократная проверка состояния зеркал ---
# Загружает и выполняет скрипт проверки с mirrors.in1.click,
# анализирует его вывод для определения статуса.
mirror_check_once() {
  local output_file
  output_file="$(mktemp)"

  # Загружаем скрипт проверки, удаляем из него интерактивный prompt
  # (чтобы он не ждал ввода пользователя) и выполняем
  if ! curl -fsS "https://in1.click/mirrors/cli.sh" 2>/dev/null \
    | sed '/^read -r -p/,$d' \
    | bash 2>&1 | tee "$output_file"; then
    mirror_status="unreachable"
    deb_status="unknown"
    rm -f "$output_file"
    return
  fi

  # Анализируем вывод скрипта — определяем статус зеркал модулей
  if grep -Fq "It should be safe to proceed with module updates." "$output_file"; then
    mirror_status="good"
  elif grep -Fq "Degraded performance. Mirrors responding but not fully healthy — proceed with caution." "$output_file"; then
    mirror_status="warn"
  elif grep -Fq "Mirrors unstable. Hold fire on updates until things improve." "$output_file"; then
    mirror_status="bad"
  elif grep -Fq "Our monitoring server is struggling. Results unreliable — hold fire and retry shortly." "$output_file"; then
    mirror_status="server"
  else
    mirror_status="unknown"
  fi

  # Анализируем вывод — определяем статус APT-репозитория (deb.freepbx.org)
  if grep -Fq "Packages.gz valid" "$output_file"; then
    deb_status="good"
  elif grep -Fq "captcha page instead of Packages.gz" "$output_file"; then
    deb_status="captcha"
  elif grep -Fq "FreePBX installations will fail" "$output_file"; then
    deb_status="bad"
  elif grep -Fq "not valid gzip data" "$output_file"; then
    deb_status="invalid"
  else
    deb_status="unknown"
  fi

  rm -f "$output_file"
}

# --- Вывод статуса одной проверки ---
# Расшифровывает результаты mirror_check_once для пользователя.
# Увеличивает MIRROR_GOOD_COUNT, если оба компонента здоровы.
print_mirror_status() {
  if [ "$mirror_status" = "good" ] && [ "$deb_status" = "good" ]; then
    MIRROR_GOOD_COUNT=$((MIRROR_GOOD_COUNT + 1))
    echo -e "Проверьте https://in1.click/mirrors в браузере. ${WHT}($MIRROR_GOOD_COUNT/$MIRROR_MAX проверок пройдено)${NC}"
  elif [ "$mirror_status" = "good" ] && [ "$deb_status" != "good" ]; then
    echo -e "${BYEL}Зеркала модулей стабильны, но репозиторий deb.freepbx.org (APT) работает нестабильно.${NC}"
  elif [ "$mirror_status" = "unreachable" ]; then
    echo -e "${BRED}Не удаётся связаться с сервисом проверки зеркал. Возможно, ваш IP-адрес заблокирован Cloudflare.${NC}"
  elif [ "$mirror_status" = "bad" ]; then
    echo -e "${BRED}Зеркала недоступны или сильно деградировали.${NC}"
  elif [ "$mirror_status" = "warn" ]; then
    echo -e "${BYEL}Зеркала отвечают, но не полностью исправны.${NC}"
  elif [ "$mirror_status" = "server" ]; then
    echo -e "${BYEL}Сам сервер мониторинга испытывает проблемы.${NC}"
  else
    echo -e "${BRED}Статус зеркала не удалось определить.${NC}"
  fi
}

# --- Цикл проверки зеркал (до MIRROR_MAX попыток) ---
# Выполняет несколько проверок с паузами между ними.
run_mirror_checks() {
  MIRROR_ATTEMPTS=0
  MIRROR_GOOD_COUNT=0
  while [ "$MIRROR_ATTEMPTS" -lt "$MIRROR_MAX" ]; do
    MIRROR_ATTEMPTS=$((MIRROR_ATTEMPTS + 1))
    echo -e "\n${BGRN}Используем mirrors.in1.click для проверки официальных зеркал FreePBX… (попытка $MIRROR_ATTEMPTS/$MIRROR_MAX)${NC}\n"
    mirror_check_once
    print_mirror_status
    # Пауза перед следующей попыткой, кроме последней
    if [ "$MIRROR_ATTEMPTS" -lt "$MIRROR_MAX" ]; then
      countdown "$MIRROR_RETRY_DELAY_S"
    fi
  done
}

# --- Интерактивный диалог при сбое зеркал ---
# Если все проверки провалились, предлагает пользователю выбор:
# повторить, прервать или продолжить вопреки предупреждению.
mirror_failure_dialog() {
  while [ "$MIRROR_OK" = false ]; do
    # --- Неинтерактивный режим: выводим диагностику и выходим ---
    if [ "$IS_HEQET" = true ] || [ "$IS_NONINTERACTIVE" = true ]; then
      echo
      echo -e "${BRED}Зеркала FreePBX недоступны после $MIRROR_MAX попыток.${NC}"
      echo
      echo -e "${WHT}Скрипт не может установить FreePBX без рабочих зеркал.${NC}"
      echo -e "${WHT}Это не проблема вашей системы — зеркала на стороне поставщика не отвечают корректно.${NC}"
      echo
      # Подсказка: по субботам зеркала часто перегружены
      if [ "$(date +%u)" -eq 6 ]; then
        echo -e "${BYEL}Сегодня суббота — официальные зеркала FreePBX могут быть перегружены.${NC}"
        echo -e "${BYEL}Попробуйте снова завтра.${NC}"
        echo
      fi
      echo -e "${BYEL}Что делать дальше:${NC}"
      echo
      echo -e "${WHT}  1. Подождите до 15 минут, затем запустите установщик снова.${NC}"
      echo
      echo -e "${WHT}     Проверить статус в браузере:${NC}"
      echo -e "${BGRN}       https://in1.click/mirrors${NC}"
      echo
      echo -e "${WHT}     Или из терминала:${NC}"
      echo -e "${BGRN}       curl mirrors.in1.click | sh${NC}"
      echo
      echo -e "${WHT}  2. Как только зеркала станут стабильными, запустите установщик снова.${NC}"
      echo
      echo -e "${WHT}  3. Если проблема сохраняется, обратитесь в службу поддержки.${NC}"
      echo
      echo -e "${CYAN}Скрипт прекращает установку. До свидания.${NC}"
      echo
      exit 1
    fi

    # --- Интерактивный режим: показываем меню выбора ---
    echo
    echo -e "${WHT}Установка приостановлена.${NC}"
    echo
    echo -e "${BYEL}Зеркала нестабильны!${NC}"
    echo -e "${BYEL} 1) Проверить зеркала снова${NC}"
    echo -e "${BYEL} 2) Прервать установку${NC}"
    echo -e "${BYEL} 3) Продолжить в любом случае${NC}"
    printf "${BYEL}Внимание. Попробовать снова? [1]: ${NC}"
    read -r mirror_choice

    case "$mirror_choice" in
      ""|1)
        # Повторная проверка зеркал
        run_mirror_checks
        if [ "$MIRROR_GOOD_COUNT" -gt 0 ]; then
          MIRROR_OK=true
        else
          echo -e "${BRED}Все зеркала по-прежнему недоступны.${NC}"
        fi
        ;;
      3)
        # Игнорировать предупреждения и продолжить
        echo -e "${BYEL}Продолжаем, несмотря на предупреждения о состоянии зеркал.${NC}"
        MIRROR_OK=true
        ;;
      2)
        # Прервать установку
        echo -e "${BRED}Прерывание установки из-за проблем со статусом зеркал.${NC}"
        echo
        echo "Вы можете перезапустить скрипт следующей командой:"
        echo
        echo "curl https://freepbx.in1.click | sh"
        echo
        echo -e "${CYAN}До свидания.${NC}"
        exit 1
        ;;
      *)
        echo -e "${BRED}Неверный выбор. Пожалуйста, попробуйте снова.${NC}"
        ;;
    esac
  done
}


# ===================================================================================
# БЛОК ПРЕДВАРИТЕЛЬНЫХ ПРОВЕРОК СИСТЕМЫ
# Гарантирует, что ОС и окружение подходят под требования FreePBX 17
# ===================================================================================


preflight_system_checks() {
  # --- Приветствие ---
  echo
  echo -e "${CYAN}Здравствуйте. Запуск скрипта установки FreePBX 17 на Debian 12 (bookworm).${NC}"
  sleep 4
  echo
  echo -e "${BYEL}Версия скрипта: ${VERSION}.${NC}"
  sleep 4

  # --- Отключение unattended-upgrades на время установки ---
  # Автоматические обновления могут конфликтовать с установщиком FreePBX
  print_step "Отключение unattended-upgrades на время установки..."
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.timer 2>/dev/null || true
  systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
  systemctl stop apt-daily.service 2>/dev/null || true
  systemctl stop apt-daily-upgrade.service 2>/dev/null || true
  echo -e "Автоматические обновления отключены. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Определение запуска с ISO-образа Heqet ---
  # Если найдены служебные service-файлы — считаем, что это Heqet ISO
  print_step "Проверка ISO-образа Heqet..."
  if [ -f /etc/systemd/system/fpbx-installer-firstboot.service ] \
     || [ -f /etc/systemd/system/fpbx-installer-cleanup.service ]; then
    IS_HEQET=true
    echo -e "ISO-образ Heqet обнаружен. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "ISO-образ Heqet не обнаружен. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка версии ОС ---
  print_step "Проверка версии ОС (Debian 12)..."
  if grep -q 'Debian GNU/Linux 12' /etc/os-release; then
    echo -e "Debian 12 подтверждён. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  else
    echo -e "${BRED}Скрипт поддерживается только на Debian 12. Завершение работы.${NC}"
    exit 1
  fi

  # --- Проверка свободного места на диске ---
  print_step "Проверка свободного места на диске..."
  local available_kb
  available_kb=$(df / | tail -1 | awk '{print $4}')
  if (( available_kb < REQUIRED_DISK_KB )); then
    echo -e "${BRED}Недостаточно места на корневом разделе (/). Требуется минимум 10 ГБ.${NC}"
    echo -e "Доступно: $(awk "BEGIN {printf \"%.2f\", $available_kb/1024/1024}") ГБ."
    exit 1
  else
    echo -e "Доступно: $(awk "BEGIN {printf \"%.2f\", $available_kb/1024/1024}") ГБ. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка памяти и swap ---
  print_step "Проверка оперативной памяти и swap..."
  local total_mem_kb total_swap_kb total_mem_mb total_swap_mb
  total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  total_mem_mb=$(( total_mem_kb / 1024 ))
  total_swap_mb=$(( total_swap_kb / 1024 ))

  # Сценарий 1: RAM слишком мала и swap отсутствует — критично
  if (( total_mem_mb < MIN_RAM_MB )) && (( total_swap_mb < MIN_SWAP_MB )); then
    echo -e "${BRED}Недостаточно памяти. FreePBX 17 требует минимум 1 ГБ RAM.${NC}"
    echo -e "${WHT}В системе ${total_mem_mb} МБ RAM и swap не настроен.${NC}"
    echo -e "${WHT}Установщик, скорее всего, будет убит ядром (OOM) до завершения.${NC}"
    echo
    if [ "$IS_HEQET" = true ] || [ "$IS_NONINTERACTIVE" = true ]; then
      echo -e "${BYEL}Неинтерактивная установка: продолжаем несмотря на нехватку памяти.${NC}"
      echo -e "${WHT}Если установка упадёт — добавьте swap и повторите:${NC}"
      echo -e "${BGRN}  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
    else
      echo -e "${BYEL} 1) Продолжить в любом случае${NC}"
      echo -e "${BYEL} 2) Прервать установку${NC}"
      echo
      read -r -p "$(echo -e "${BYEL}Выбор [2]: ${NC}")" mem_choice
      case "${mem_choice:-2}" in
        1)
          echo -e "${BYEL}Продолжаем несмотря на нехватку памяти. Удачи.${NC}"
          echo -e "${WHT}Добавить swap можно в другой сессии:${NC}"
          echo -e "${BGRN}  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
          ;;
        *)
          echo
          echo -e "${CYAN}До свидания.${NC}"
          echo
          exit 1
          ;;
      esac
    fi
  # Сценарий 2: RAM меньше 1 ГБ, но swap есть — предупреждение
  elif (( total_mem_mb < MIN_RAM_WARN_MB )) && (( total_swap_mb < MIN_SWAP_MB )); then
    echo -e "${BYEL}ПРЕДУПРЕЖДЕНИЕ: Обнаружено менее 1 ГБ RAM (${total_mem_mb} МБ). Продолжаем...${NC}"
    echo -e "${WHT}Если установка упадёт с OOM — добавьте swap и повторите:${NC}"
    echo -e "${BGRN}  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
  # Сценарий 3: памяти достаточно
  else
    echo -e "Память: ${total_mem_mb} МБ, Swap: ${total_swap_mb} МБ. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка архитектуры ---
  # FreePBX 17 поддерживает только x86_64
  print_step "Проверка архитектуры системы..."
  local arch
  arch=$(uname -m)
  if [[ "$arch" != "x86_64" ]]; then
    echo -e "${BRED}Неподдерживаемая архитектура: $arch. Требуется 64-битная (x86_64).${NC}"
    exit 1
  else
    echo -e "Архитектура: 64-бит. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка формата имени хоста ---
  # Имя хоста не должно состоять только из цифр — это ломает FreePBX
  print_step "Проверка формата имени хоста..."
  local host hostname_label
  host=$(hostname)
  hostname_label="${host%%.*}"
  if [[ ! "$host" =~ ^[a-z0-9.-]+$ ]]; then
    echo -e "${BRED}Неверный формат имени хоста. Используйте только строчные буквы, цифры и дефисы. Завершение работы.${NC}"
    exit 1
  fi
  # Если метка состоит только из цифр — устанавливаем стандартное имя
  if [[ "$hostname_label" =~ ^[0-9]+$ ]]; then
    echo -e "${BYEL}Метка имени хоста состоит только из цифр. Устанавливаем freepbx.sangoma.local...${NC}"
    echo
    hostnamectl set-hostname "freepbx.sangoma.local"
    echo -e "  - Имя хоста установлено в freepbx.sangoma.local"
    echo
    echo "freepbx.sangoma.local" > /etc/hostname
    echo -e "  - Файл /etc/hostname обновлён"
    echo
    sed -i "s/127.0.1.1.*/127.0.1.1\tfreepbx.sangoma.local freepbx/" /etc/hosts
    echo -e "  - Файл /etc/hosts обновлён"
    echo
    # Проверяем, что новое имя корректно
    host=$(hostname)
    hostname_label="${host%%.*}"
    if [[ "$hostname_label" =~ ^[0-9]+$ ]]; then
      echo -e "${BRED}Недопустимая метка имени хоста: не должна состоять только из цифр. Завершение работы.${NC}"
      exit 1
    fi
  fi
  echo -e "Метка имени хоста корректна. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Проверка среды рабочего стола ---
  # FreePBX требует минимальную установку без GUI
  print_step "Проверка среды рабочего стола..."
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" || -d /usr/share/xsessions ]]; then
    echo -e "${BRED}Обнаружена среда рабочего стола. Для FreePBX требуется минимальная конфигурация Debian. Завершение работы.${NC}"
    exit 1
  else
    echo -e "Среда рабочего стола не обнаружена. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  fi

  # --- Проверка монтирования /tmp ---
  # Флаг noexec на /tmp мешает установщику FreePBX
  print_step "Проверка прав на /tmp..."
  if mount | grep '/tmp' | grep -q noexec; then
    echo -e "${BRED}/tmp смонтирован с флагом noexec. Это нарушит установку FreePBX. Перемонтируйте или исправьте fstab.${NC}"
    exit 1
  else
    echo -e "/tmp доступен для записи и выполнения. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  fi
}


# ===================================================================================
# БЛОК ПРОВЕРОК КОНФЛИКТОВ
# Проверяет, что целевые компоненты ещё не установлены —
# скрипт не предназначен для обновления поверх существующей установки.
# ===================================================================================


preflight_conflict_checks() {
  # --- Существующая установка FreePBX ---
  check_existing_install "FreePBX" \
    '[[ -f /etc/freepbx.conf || -d /var/www/html/admin ]]'

  # --- Существующая установка Asterisk ---
  check_existing_install "Asterisk" \
    'command -v asterisk >/dev/null 2>&1 || systemctl list-units --type=service | grep -q "asterisk"'

  # --- Существующая установка MariaDB ---
  check_existing_install "MariaDB" \
    'systemctl list-units --type=service | grep -q "mariadb" || command -v mariadbd >/dev/null 2>&1'

  # --- Проверка Node.js ---
  # Node.js не блокирует установку, но предупреждаем о возможных конфликтах
  print_step "Проверка Node.js..."
  if command -v node >/dev/null 2>&1; then
    local node_version
    node_version=$(node -v)
    echo -e "${BRED}ВНИМАНИЕ: Node.js уже установлен (${node_version}). ${BYEL}Продолжаем в любом случае...${NC}"
  else
    echo -e "Установленная версия Node.js не найдена. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY
}


# ===================================================================================
# БЛОК ПОДГОТОВКИ APT
# Проверяет и исправляет источники пакетов, обновляет списки и сами пакеты.
# Также блокирует нежелательные репозитории (stable → bookworm, trixie → отключение).
# ===================================================================================


preflight_apt_prepare() {
  # --- Проверка и исправление источников APT ---
  # Если источники не указывают на официальные зеркала Debian — перезаписываем
  print_step "Проверка источников APT..."
  local apt_sources_ok=false
  if grep -qE 'deb(\.|-security\.)debian\.org' /etc/apt/sources.list 2>/dev/null; then
    apt_sources_ok=true
  fi
  if grep -qrE 'debian\.org' /etc/apt/sources.list.d/ 2>/dev/null; then
    apt_sources_ok=true
  fi
  if [ "$apt_sources_ok" = false ]; then
    echo -e "${BYEL}Источники APT не указывают на официальные зеркала Debian. Перезаписываем...${NC}"
    cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org/debian-security bookworm-security main
EOF
    echo -e "Источники APT перезаписаны. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "Источники APT указывают на официальные зеркала Debian. ${WHT}Можно продолжать.${NC}"
  fi

  # --- Удаление зеркал провайдера (например, DigitalOcean) ---
  # Эти зеркала могут быть недоступны или конфликтовать
  if [ -d /etc/apt/mirrors ]; then
    rm -f /etc/apt/mirrors/*.list 2>/dev/null || true
    echo -e "Файлы списков зеркал провайдера удалены. ${WHT}Можно продолжать.${NC}"
    echo
  fi
  if grep -q 'mirror+file\|mirrorlist\|mirrors\.' /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
    rm -f /etc/apt/sources.list.d/debian.sources
    echo -e "Файл debian.sources провайдера удалён. ${WHT}Можно продолжать.${NC}"
    echo
  fi
  if grep -rlE 'digitalocean|mirrors\.' /etc/apt/sources.list.d/ 2>/dev/null | grep -q .; then
    grep -rlE 'digitalocean|mirrors\.' /etc/apt/sources.list.d/ | xargs rm -f
    echo -e "Записи sources.list.d провайдера удалены. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Блокировка репозиториев stable и trixie ---
  # 'stable' — синоним, который может указывать на неправильную версию;
  # 'trixie' (Debian 13) — не поддерживается FreePBX 17
  print_step "Проверка и исправление запрещённых источников APT (stable/trixie)..."
  local fixed=0
  for src in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$src" ] || continue
    if grep -q 'stable' "$src"; then
      sed -i 's/stable/bookworm/g' "$src"
      echo -e "${BYEL}Заменено «stable» на «bookworm» в $src.${NC}"
      fixed=1
    fi
    if grep -q 'trixie' "$src"; then
      sed -i '/trixie/s/^/# DISABLED BY INSTALLER: /' "$src"
      echo -e "${BYEL}Строки с «trixie» закомментированы в $src.${NC}"
      fixed=1
    fi
  done
  if [ "$fixed" -eq 1 ]; then
    echo -e "${BRED}Источники APT были автоматически исправлены. Проверьте свои источники при проблемах.${NC}"
  else
    echo -e "Запрещённых записей в источниках APT нет. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Ожидание блокировок APT перед update ---
  print_step "Проверка блокировок APT перед обновлением списков пакетов..."
  wait_apt_lock "$APT_LOCK_TIMEOUT_S"

  # --- apt update ---
  print_step "Обновление списков пакетов..."
  apt update -qq > /dev/null 2>&1
  echo -e "Списки пакетов обновлены. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Повторная проверка trixie после apt update ---
  # apt update может подтянуть новые источники из добавленных репозиториев
  print_step "Проверка ссылок на Debian 13 (trixie) после обновления..."
  local trixie_found=0
  for src in /etc/apt/sources.list /etc/apt/sources.list.d/* /var/lib/apt/lists/*; do
    [ -f "$src" ] || continue
    if grep -q 'trixie' "$src"; then
      sed -i '/trixie/s/^/# DISABLED BY INSTALLER: /' "$src"
      echo -e "${BYEL}Строки с «trixie» закомментированы в $src после обновления.${NC}"
      trixie_found=1
    fi
  done
  if [ "$trixie_found" -eq 1 ]; then
    echo -e "${BRED}Источники APT были исправлены для «trixie». Проверьте настройки при проблемах.${NC}"
  else
    echo -e "Упоминаний «trixie» после обновления не найдено. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- apt upgrade ---
  # Используем noninteractive, чтобы dpkg не задавал вопросов
  # о конфигурационных файлах (сохраняем старые)
  print_step "Обновление пакетов... Это может занять время."
  local upgrade_output
  upgrade_output=$(DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" upgrade 2>/dev/null)
  if echo "$upgrade_output" | grep -q '0 upgraded'; then
    echo -e "Все пакеты уже актуальны. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "Пакеты успешно обновлены. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка необходимости перезагрузки ---
  # Если обновилось ядро или системные библиотеки — перезагрузка обязательна
  if [ "$IS_HEQET" = false ] && [ "$IS_NONINTERACTIVE" = false ] && [ -f /var/run/reboot-required ]; then
    echo
    echo -e "${BRED}Требуется перезагрузка перед установкой FreePBX.${NC}"
    echo -e "${WHT}Обычно это вызвано обновлением ядра или системных библиотек.${NC}"
    echo
    echo -e "${BYEL}Скрипт перезагрузит сервер прямо сейчас.${NC}"
    echo -e "${WHT}После перезагрузки запустите установщик снова командой:${NC}"
    echo -e "${BGRN}  curl https://freepbx.in1.click | sh${NC}"
    echo
    read -r -p "$(echo -e "${BYEL}Нажмите Enter для перезагрузки или Ctrl+C для отмены: ${NC}")"
    reboot
    exit 0
  fi

  # --- Повторная проверка ОС ---
  # После upgrade дистрибутив мог измениться — проверяем снова
  print_step "Повторная проверка версии ОС (Debian 12)..."
  if grep -q 'Debian GNU/Linux 12' /etc/os-release; then
    echo -e "Подтверждено: Debian 12. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  else
    echo -e "${BRED}Скрипт поддерживается только на Debian 12. Завершение работы.${NC}"
    exit 1
  fi
}


# ===================================================================================
# БЛОК СЕТЕВЫХ ПРОВЕРОК
# Проверяет наличие сетевого интерфейса, корректность DNS,
# отсутствие конфликтов на порту 80 и доступность необходимых инструментов.
# ===================================================================================


preflight_network_checks() {
  # --- Проверка сетевого интерфейса и типа IP ---
  print_step "Проверка сетевого интерфейса и типа IP-адреса..."
  local iface ip_info
  iface=$(ip -o -4 addr show | awk '{print $2}' | head -n1)
  if [[ -z "$iface" ]]; then
    echo -e "${BRED}Не найден активный сетевой интерфейс с IPv4-адресом. Скрипт не может продолжить работу.${NC}"
    echo
    echo -e "${CYAN}До свидания.${NC}"
    echo
    exit 1
  fi
  ip_info=$(ip -o -4 addr show "$iface")
  if echo "$ip_info" | grep -q 'dynamic'; then
    echo -e "${BRED}ВНИМАНИЕ: IP-адрес назначен динамически (DHCP). ${BYEL}Продолжаем в любом случае...${NC}"
  elif echo "$ip_info" | grep -q 'inet'; then
    echo -e "Обнаружен статический IP-адрес. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "${BRED}ВНИМАНИЕ: Не удалось определить тип назначения IP-адреса. ${BYEL}Продолжаем в любом случае...${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка iptables ---
  print_step "Проверка iptables..."
  if ! command -v iptables >/dev/null 2>&1; then
    echo -e "${BRED}ВНИМАНИЕ: iptables не найден. ${BYEL}Устанавливаем...${NC}"
    echo
    apt install -y iptables
    echo
    echo -e "iptables успешно установлен. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "iptables уже установлен. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка активных правил iptables ---
  # Правила DROP/REJECT могут блокировать доступ к веб-интерфейсу или SIP
  print_step "Проверка активных правил iptables..."
  if ! command -v iptables >/dev/null 2>&1; then
    echo -e "${BRED}ВНИМАНИЕ: iptables не найден. ${BYEL}Продолжаем в любом случае...${NC}"
  else
    if iptables -L -n | grep -q 'DROP\|REJECT'; then
      echo -e "${BRED}ВНИМАНИЕ: обнаружены правила iptables, которые могут блокировать доступ к веб-интерфейсу или SIP. ${BYEL}Продолжаем в любом случае...${NC}"
    else
      echo -e "Активные правила DROP/REJECT в iptables не обнаружены. ${WHT}Можно продолжать.${NC}"
    fi
  fi
  sleep $SLEEP_DELAY

  # --- Проверка конфликта порта 80 ---
  # Если порт 80 занят не Apache — FreePBX не сможет запустить веб-интерфейс
  print_step "Проверка конфликта на порту 80..."
  if ss -tlnp | grep ':80 ' | grep -vq 'apache2'; then
    echo -e "${BRED}ВНИМАНИЕ: порт 80 уже используется процессом, не являющимся Apache.${NC}"
    echo -e "FreePBX может не запуститься, либо веб-интерфейс будет недоступен."
    echo -e "Проверьте с помощью команды: ${WHT}ss -tlnp | grep ':80'${NC}"
  else
    echo -e "Конфликтов на порту 80 не обнаружено. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка DNS ---
  print_step "Проверка разрешения DNS..."
  if ! host cloudflare.com >/dev/null 2>&1; then
    echo -e "${BRED}Сбой разрешения DNS. Исправьте настройки DNS перед продолжением.${NC}"
    exit 1
  else
    echo -e "Разрешение DNS работает корректно. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  fi

  # --- Проверка curl ---
  print_step "Проверка curl..."
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${BRED}ВНИМАНИЕ: curl не найден. ${BYEL}Устанавливаем...${NC}"
    apt install -y curl
    echo
    echo -e "curl успешно установлен. ${WHT}Можно продолжать.${NC}"
    echo
  else
    echo -e "curl установлен. ${WHT}Можно продолжать.${NC}"
  fi
}


# ===================================================================================
# БЛОК ПРОВЕРКИ ЗЕРКАЛ FreePBX
# Запускает цикл проверок и, при необходимости, интерактивный диалог.
# ===================================================================================


preflight_mirror_checks() {
  run_mirror_checks

  # Если все проверки пройдены — отлично, продолжаем
  if [ "$MIRROR_GOOD_COUNT" -eq "$MIRROR_MAX" ]; then
    echo
    echo -e "${BGRN}Все $MIRROR_MAX проверок пройдены. ${WHT}Можно продолжать.${NC}"
    MIRROR_OK=true
  else
    MIRROR_OK=false
  fi

  # Если хотя бы одна проверка провалилась — запускаем диалог
  if [ "$MIRROR_OK" = false ]; then
    mirror_failure_dialog
  fi
}


# ===================================================================================
# БЛОК ПРОВЕРКИ ДОСТУПНОСТИ УСТАНОВЩИКА
# Проверяет, что установщик FreePBX доступен на GitHub
# и что есть исходящий интернет.
# ===================================================================================


preflight_installer_checks() {
  # --- Проверка доступности установщика на GitHub ---
  print_step "Проверка доступности установщика FreePBX на GitHub..."
  if ! curl -sSfI --max-time 10 \
     https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh \
     >/dev/null; then
    echo -e "${BRED}Не удалось получить доступ к установщику FreePBX на GitHub.${NC}"
    echo -e "Проверьте подключение к интернету, настройки DNS или ограничения фаервола."
    echo
    echo -e "${BRED}Завершение работы: скрипт не может продолжить без установщика FreePBX.${NC}"
    echo
    exit 1
  else
    echo -e "Установщик FreePBX на GitHub доступен. ${WHT}Можно продолжать.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Проверка исходящего интернета ---
  print_step "Проверка исходящего интернет-соединения (публичный IP)..."
  local public_ip
  public_ip=$(curl -s --max-time 10 ifconfig.me)
  if [[ -n "$public_ip" ]]; then
    echo -e "Исходящее интернет-соединение подтверждено. Публичный IP: ${WHT}$public_ip. Можно продолжать.${NC}"
  else
    echo -e "${BRED}Не удалось получить ответ от ifconfig.me или соединение отсутствует.${NC}"
    echo -e "${BRED}Завершение работы: скрипт не может продолжить без доступа в интернет.${NC}"
    exit 1
  fi
  sleep 4

  # --- Ожидание блокировок APT перед установкой ---
  print_step "Проверка блокировок APT перед установкой FreePBX 17..."
  wait_apt_lock "$APT_LOCK_INSTALL_TIMEOUT_S"
}


# ===================================================================================
# БЛОК ЗАПУСКА В SCREEN
# Запускает установку в сессии screen, чтобы установка продолжалась
# при отключении SSH-сессии. При повторном входе предлагает переподключиться.
# ===================================================================================


launch_in_screen() {
  # Если уже внутри screen или неинтерактивный режим — пропускаем
  if [ -z "${STY:-}" ] && [ "$IS_NONINTERACTIVE" = false ]; then
    apt-get install -y screen -qq > /dev/null 2>&1

    # Скрипт переподключения, который срабатывает при новом входе в систему
    cat > /etc/profile.d/fpbx-reattach.sh << 'PROFILE'
#!/bin/bash
if screen -ls fpbx-install | grep -q fpbx-install; then
  echo
  echo "Установка FreePBX продолжает работать в фоновом режиме."
  echo
  echo "  1) Да — посмотреть вывод"
  echo "  2) Нет — оставить работать"
  echo "  3) Остановить — прервать установку"
  echo
  read -r -p "  Выбор [1]: " choice
  case "${choice:-1}" in
    1) screen -D -r fpbx-install ;;
    2) ;;
    3)
      ELAPSED=$(( $(date +%s) - $(stat -c %Y /etc/profile.d/fpbx-reattach.sh) ))
      echo
      echo "  ВНИМАНИЕ: установка работает уже $((ELAPSED / 60)) мин $((ELAPSED % 60)) сек."
      echo "  Прерывание сейчас может оставить систему в нерабочем состоянии."
      echo
      read -r -p "  Вы уверены? [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        screen -S fpbx-install -X stuff $'\003'
        rm -f /etc/profile.d/fpbx-reattach.sh
        echo "  Установка прервана. Система может находиться в нерабочем состоянии."
      fi
      ;;
  esac
  echo
fi
PROFILE
    chmod +x /etc/profile.d/fpbx-reattach.sh

    # Перезапускаем скрипт внутри screen с флагом --skip-checks
    screen -S fpbx-install bash "$0" --skip-checks "$@"

    print_completion
    exit 0
  fi
}


# ===================================================================================
# БЛОК ВЫБОРА И ПРИМЕНЕНИЯ ЗЕРКАЛА FreePBX
# Позволяет выбрать альтернативное зеркало (например, для РФ)
# и применить его к новой или существующей установке.
# ===================================================================================


# --- Показ текущего выбранного зеркала ---
show_current_mirror() {
  if [[ -z "$SELECTED_MIRROR" ]]; then
    echo -e "  Текущее зеркало: ${BYEL}не выбрано${NC}"
  else
    echo -e "  Текущее зеркало: ${BGRN}$SELECTED_MIRROR_NAME${NC}"
    echo -e "  URL: ${WHT}$SELECTED_MIRROR${NC}"
  fi
}

# --- Меню выбора зеркала ---
# Предлагает преднастроенные зеркала и возможность ввести свой URL.
select_mirror() {
  echo
  echo -e "${BMAG}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BMAG}║          ВЫБОР ЗЕРКАЛА FreePBX 17                          ║${NC}"
  echo -e "${BMAG}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo

  show_current_mirror
  echo
  echo -e "  ${WHT}Доступные зеркала:${NC}"
  echo

  # Выводим список зеркал из массива MIRRORS
  local i=1
  for mirror in "${MIRRORS[@]}"; do
    local name url gpg
    IFS='|' read -r name url gpg <<< "$mirror"
    if [[ "$i" -eq 1 ]]; then
      echo -e "  ${BGRN}$i)${NC} $name ${BYEL}(рекомендуется для РФ)${NC}"
    else
      echo -e "  ${BGRN}$i)${NC} $name"
    fi
    echo -e "     URL: ${WHT}$url${NC}"
    echo
    i=$((i + 1))
  done

  # Дополнительный пункт — свой URL
  local custom_idx=$(( ${#MIRRORS[@]} + 1 ))
  echo -e "  ${BGRN}$custom_idx)${NC} Свой URL (ввести вручную)"
  echo
  echo -e "  ${BGRN}0)${NC} Назад в главное меню"
  echo
  printf "${BYEL}  Выберите зеркало [1]: ${NC}"
  read -r mirror_choice

  case "${mirror_choice:-1}" in
    [1-9])
      # Выбор из преднастроенного списка
      if (( mirror_choice >= 1 && mirror_choice <= ${#MIRRORS[@]} )); then
        local name url gpg
        IFS='|' read -r name url gpg <<< "${MIRRORS[$((mirror_choice - 1))]}"
        SELECTED_MIRROR_NAME="$name"
        SELECTED_MIRROR="$url"
        SELECTED_MIRROR_GPG="$gpg"
        echo
        echo -e "${BGRN}Выбрано зеркало: $name${NC}"
        echo -e "${WHT}URL: $url${NC}"
        echo
        echo -e "${BYEL}Зеркало будет применено:${NC}"
        echo -e "  • При установке FreePBX (пункт 7) — установщик будет использовать выбранное зеркало"
        echo -e "  • Можно применить отдельно через пункт 15"
        sleep 2
      # Ввод собственного URL
      elif (( mirror_choice == custom_idx )); then
        echo
        printf "${BYEL}  Введите URL зеркала: ${NC}"
        read -r custom_url
        if [[ -z "$custom_url" ]]; then
          echo -e "${BRED}URL не введён.${NC}"
          return
        fi
        printf "${BYEL}  Введите URL GPG-ключа (или Enter для пропуска): ${NC}"
        read -r custom_gpg
        SELECTED_MIRROR_NAME="Своё зеркало ($custom_url)"
        SELECTED_MIRROR="$custom_url"
        SELECTED_MIRROR_GPG="$custom_gpg"
        echo
        echo -e "${BGRN}Выбрано зеркало: $SELECTED_MIRROR_NAME${NC}"
        sleep 2
      else
        echo -e "${BRED}Неверный выбор.${NC}"
      fi
      ;;
    0)
      return
      ;;
    *)
      echo -e "${BRED}Неверный выбор.${NC}"
      ;;
  esac
}

# --- Применение зеркала к существующей установке ---
# Перезаписывает /etc/apt/sources.list.d/freepbx.list и обновляет GPG-ключ.
apply_mirror_existing() {
  if [[ -z "$SELECTED_MIRROR" ]]; then
    echo -e "${BRED}Зеркало не выбрано. Сначала выберите зеркало (пункт 14).${NC}"
    sleep 2
    return
  fi

  print_step "Применение зеркала $SELECTED_MIRROR_NAME к существующей установке..."

  local freepbx_list="/etc/apt/sources.list.d/freepbx.list"
  local old_mirror=""

  # Читаем текущее зеркало из файла, если он существует
  if [[ -f "$freepbx_list" ]]; then
    old_mirror=$(grep -oE 'https?://[^ "]+' "$freepbx_list" | head -1)
  fi

  echo -e "  Текущее зеркало в freepbx.list: ${WHT}${old_mirror:-не найдено}${NC}"
  echo -e "  Новое зеркало: ${BGRN}$SELECTED_MIRROR${NC}"
  echo

  # Установка GPG-ключа нового зеркала
  if [[ -n "$SELECTED_MIRROR_GPG" ]]; then
    print_step "Установка GPG-ключа для $SELECTED_MIRROR_NAME..."
    if curl -fsSL "$SELECTED_MIRROR_GPG" 2>/dev/null \
      | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg 2>/dev/null; then
      echo -e "${BGRN}GPG-ключ установлен.${NC}"
    else
      echo -e "${BYEL}Не удалось установить GPG-ключ (возможно, он уже установлен).${NC}"
    fi
  fi

  # Перезапись файла источников
  print_step "Обновление /etc/apt/sources.list.d/freepbx.list..."
  cat > "$freepbx_list" << EOF
deb [arch=amd64] $SELECTED_MIRROR bookworm main
#deb-src [arch=amd64] $SELECTED_MIRROR bookworm main
EOF
  echo -e "${BGRN}Файл freepbx.list обновлён.${NC}"
  echo

  # Обновление списков пакетов с новым зеркалом
  print_step "Выполняем apt update..."
  apt update -qq 2>/dev/null
  echo -e "${BGRN}Списки пакетов обновлены. Зеркало $SELECTED_MIRROR_NAME активно.${NC}"
  sleep $SLEEP_DELAY
}

# --- Подмена зеркала в установщике перед запуском ---
# Меняет URL deb.freepbx.org на выбранное зеркало прямо в скачанном скрипте.
patch_installer_mirror() {
  local script_file="$1"

  # Если зеркало не выбрано — ничего не делаем
  if [[ -z "$SELECTED_MIRROR" ]]; then
    return 0
  fi

  print_step "Подмена зеркала в установщике на $SELECTED_MIRROR_NAME..."

  # Заменяем URL репозитория
  sed -i "s|deb.freepbx.org/freepbx-17-prod|${SELECTED_MIRROR}|g" "$script_file"
  sed -i "s|deb.freepbx.org|${SELECTED_MIRROR%/freepbx17-prod}|g" "$script_file"

  # Подменяем URL GPG-ключа, если задан
  if [[ -n "$SELECTED_MIRROR_GPG" ]]; then
    sed -i "s|deb.freepbx.org/freepbx-17-prod/pubkey.gpg|${SELECTED_MIRROR_GPG}|g" "$script_file"
    sed -i "s|deb.freepbx.org/pubkey.gpg|${SELECTED_MIRROR_GPG}|g" "$script_file"
  fi

  echo -e "${BGRN}Установщик пропатчен: deb.freepbx.org → $SELECTED_MIRROR${NC}"

  # Предустановка GPG-ключа, чтобы установщику не пришлось его скачивать
  if [[ -n "$SELECTED_MIRROR_GPG" ]]; then
    print_step "Предустановка GPG-ключа для $SELECTED_MIRROR_NAME..."
    if curl -fsSL "$SELECTED_MIRROR_GPG" 2>/dev/null \
      | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg 2>/dev/null; then
      echo -e "${BGRN}GPG-ключ предустановлен.${NC}"
    else
      echo -e "${BYEL}Не удалось предустановить GPG-ключ. Установщик может сделать это сам.${NC}"
    fi
  fi

  sleep $SLEEP_DELAY
}


# ===================================================================================
# БЛОК УСТАНОВКИ FreePBX
# Скачивает официальный установщик FreePBX с GitHub, при необходимости
# подменяет зеркало, и запускает установку.
# ===================================================================================


install_freepbx() {
  print_step "Установка FreePBX 17..."
  sleep $SLEEP_DELAY
  cd /usr/src

  # Скачивание официального установщика
  wget -q https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh \
    -O freepbx17-install.sh
  chmod +x freepbx17-install.sh

  # Подмена зеркала, если выбрано альтернативное
  if [[ -n "$SELECTED_MIRROR" ]]; then
    patch_installer_mirror "$(pwd)/freepbx17-install.sh"
  else
    echo -e "${BYEL}Зеркало не выбрано — используется deb.freepbx.org по умолчанию.${NC}"
    echo -e "${BYEL}Рекомендуется выбрать зеркало через пункт 14 меню.${NC}"
    sleep 2
  fi

  # Запуск установщика; при ошибке — вызываем handle_install_failure
  ./freepbx17-install.sh || handle_install_failure
  # Снимаем перехват Ctrl+C, чтобы пользователь мог прервать постустановку
  trap - INT
  sleep $SLEEP_DELAY
}


# ===================================================================================
# БЛОК ПОСТУСТАНОВКИ МОДУЛЕЙ
# Обновляет модули FreePBX, устанавливает правильные права и перезагружает систему.
# ===================================================================================


postinstall_modules() {
  # --- Обновление модулей ---
  print_step "Обновление модулей FreePBX..."
  fwconsole ma upgradeall \
    || echo -e "${BYEL}Обновление модулей завершено с некоторыми предупреждениями. Продолжаем...${NC}"

  # --- Установка владельцев файлов ---
  print_step "Установка правильных владельцев файлов..."
  fwconsole chown
  echo
  echo -e "Права собственности на файлы установлены. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Перезагрузка FreePBX ---
  # Иногда первая перезагрузка падает из-за гонки состояний — делаем до двух попыток
  print_step "Перезагрузка FreePBX..."
  if ! fwconsole reload; then
    echo -e "${BRED}Первая попытка перезагрузки не удалась. Повторим через ${RELOAD_RETRY_DELAY_S} секунд...${NC}"
    sleep "$RELOAD_RETRY_DELAY_S"
    if ! fwconsole reload; then
      echo -e "${BRED}Вторая попытка перезагрузки также не удалась. Продолжаем в любом случае...${NC}"
    else
      echo -e "Вторая попытка перезагрузки успешна. ${WHT}Можно продолжать.${NC}"
    fi
  else
    echo -e "Модули обновлены, система перезагружена. ${WHT}Можно продолжать.${NC}"
  fi
}


# ===================================================================================
# БЛОК НАСТРОЙКИ APACHE И ПРОВЕРКИ GUI
# Настраивает Apache (модули, редирект) и проверяет, что
# веб-интерфейс FreePBX отвечает корректно.
# ===================================================================================


IP_ADDR=""

# --- Настройка Apache: модули, сайт, редирект ---
apache_configure() {
  a2enmod rewrite expires headers 2>/dev/null || true
  a2ensite freepbx.conf 2>/dev/null || true
  # Редирект корня сайта на /admin/, чтобы пользователь сразу попадал в FreePBX
  if ! grep -q 'RedirectMatch' /etc/apache2/sites-enabled/000-default.conf 2>/dev/null; then
    sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html\n\tRedirectMatch ^/$ /admin/|' \
      /etc/apache2/sites-enabled/000-default.conf
    echo -e "Добавлен редирект корня на /admin/. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "Редирект корня уже настроен. ${WHT}Можно продолжать.${NC}"
  fi
  systemctl restart apache2
}

postinstall_apache() {
  # --- Проверка статуса Apache ---
  print_step "Проверка работы Apache..."
  if systemctl is-active --quiet apache2; then
    echo -e "Apache запущен. ${WHT}Можно продолжать.${NC}"
  else
    echo -e "${BRED}Apache не запущен. Проверьте статус службы вручную.${NC}"
  fi
  sleep $SLEEP_DELAY

  # --- Настройка Apache и проверка веб-интерфейса ---
  print_step "Настройка Apache и проверка веб-интерфейса FreePBX..."
  IP_ADDR=$(hostname -I | awk '{print $1}')
  apache_configure

  # --- Проверка порта 80 ---
  if ! nc -zv "$IP_ADDR" 80 2>&1 | grep -Eq 'open|succeeded'; then
    echo -e "${BRED}Порт 80 на $IP_ADDR не открыт. Повторно применяем конфигурацию Apache...${NC}"
    apache_configure
  fi

  # --- Проверка веб-интерфейса FreePBX ---
  # Делаем до GUI_RETRY_MAX попыток с паузами.
  # Ожидаем страницу с «Welcome to FreePBX».
  local gui_ok=false
  local retry=0
  local http_body

  while [ "$retry" -lt "$GUI_RETRY_MAX" ]; do
    retry=$((retry + 1))
    http_body=$(curl -s --max-time 10 "http://$IP_ADDR/admin/config.php")
    if echo "$http_body" | grep -q 'Welcome to FreePBX'; then
      echo -e "Страница настройки FreePBX подтверждена по адресу http://$IP_ADDR. ${WHT}Можно продолжать.${NC}"
      gui_ok=true
      break
    elif echo "$http_body" | grep -q 'ionCube'; then
      # ionCube Loader не работает — установка прошла некорректно
      echo -e "${BRED}Обнаружена ошибка ionCube Loader. Установка FreePBX прошла некорректно.${NC}"
      echo -e "${WHT}Это сбой установки FreePBX, а не проблема с Apache.${NC}"
      handle_install_failure
    elif echo "$http_body" | grep -q 'Apache2 Debian Default Page'; then
      # Видна страница Apache по умолчанию — конфигурация не применилась
      echo -e "${BRED}Обнаружена страница Apache по умолчанию вместо FreePBX. [$retry/$GUI_RETRY_MAX] Повторно применяем конфигурацию...${NC}"
      apache_configure
    else
      echo -e "${BRED}Неожиданный ответ от http://$IP_ADDR. [$retry/$GUI_RETRY_MAX] Повторяем попытку...${NC}"
    fi
    if [ "$retry" -lt "$GUI_RETRY_MAX" ]; then
      countdown "$GUI_RETRY_DELAY_S"
    fi
  done

  # --- Если GUI так и не ответил — выводим диагностику ---
  if [ "$gui_ok" = false ]; then
    echo -e "${BRED}Веб-интерфейс FreePBX не ответил корректно после $GUI_RETRY_MAX попыток.${NC}"
    echo -e "${WHT}Установка может быть незавершённой. Не продолжайте, пока проблема не будет решена.${NC}"
    echo -e "${WHT}Проверьте Apache командой: ${BGRN}systemctl status apache2${NC}"
    echo -e "${WHT}Проверьте FreePBX командой: ${BGRN}fwconsole sa${NC}"
    echo
    if [ "$IS_HEQET" = true ] || [ "$IS_NONINTERACTIVE" = true ]; then
      echo -e "${BRED}Неинтерактивная установка: веб-интерфейс не запустился. Завершение работы.${NC}"
      exit 1
    fi
    echo -e "${BYEL}Установка приостановлена. Нажмите Enter для выхода после диагностики.${NC}"
    read -r
    exit 1
  fi
  sleep $SLEEP_DELAY
}


# ===================================================================================
# БЛОК ОЧИСТКИ
# Удаляет логи, временные файлы, следы установщика и историю Bash.
# Для ISO Heqet — удаляет служебные service-файлы.
# ===================================================================================


postinstall_cleanup() {
  # --- Очистка логов Asterisk ---
  print_step "Очистка логов Asterisk..."
  rm -f /var/log/asterisk/full /var/log/asterisk/fail2ban /var/spool/mail/root
  echo -e "Файлы full, fail2ban и почта root очищены. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Удаление компонентов ISO Heqet ---
  # Если запуск с Heqet ISO — удаляем служебные service-файлы
  # и помечаем установку как завершённую
  if [ "$IS_HEQET" = true ]; then
    print_step "Обнаружен первый запуск с ISO. Выполняем очистку..."
    touch /opt/fpbx-installer/.installed
    echo -e "  - Установка помечена как завершённая"
    echo

    # Удаление службы firstboot при следующей загрузке
    if [ -f /etc/systemd/system/fpbx-installer-firstboot.service ]; then
      systemctl disable fpbx-installer-firstboot.service
      cat <<'EOF' > /usr/local/bin/fpbx-final-cleanup.sh
#!/bin/bash
rm -f /etc/systemd/system/fpbx-installer-firstboot.service
rm -f /usr/local/bin/fpbx-final-cleanup.sh
EOF
      chmod +x /usr/local/bin/fpbx-final-cleanup.sh
      if ! grep -q fpbx-final-cleanup /etc/crontab; then
        echo "@reboot root /usr/local/bin/fpbx-final-cleanup.sh" >> /etc/crontab
      fi
      echo -e "  - fpbx-installer-firstboot.service запланировано к удалению при следующей загрузке"
      echo
    fi

    # Удаление службы cleanup при следующей загрузке
    if [ -f /etc/systemd/system/fpbx-installer-cleanup.service ]; then
      systemctl disable fpbx-installer-cleanup.service
      cat <<'EOF' > /usr/local/bin/fpbx-cleanup-final.sh
#!/bin/bash
rm -f /etc/systemd/system/fpbx-installer-cleanup.service
rm -f /usr/local/bin/fpbx-cleanup-final.sh
EOF
      chmod +x /usr/local/bin/fpbx-cleanup-final.sh
      if ! grep -q fpbx-cleanup-final /etc/crontab; then
        echo "@reboot root /usr/local/bin/fpbx-cleanup-final.sh" >> /etc/crontab
      fi
      echo -e "  - fpbx-installer-cleanup.service запланировано к удалению при следующей загрузке"
      echo
    fi

    # Удаление файлов preseed
    rm -f /root/preseed.cfg /etc/preseed.cfg /opt/fpbx-installer/preseed.cfg 2>/dev/null || true
    echo -e "  - Файлы preseed очищены"
    echo
    echo -e "Очистка завершена. ${WHT}Можно продолжать.${NC}"
    sleep $SLEEP_DELAY
  fi

  # --- Удаление хука переподключения к screen ---
  rm -f /etc/profile.d/fpbx-reattach.sh

  # --- Очистка истории Bash ---
  print_step "Очистка истории Bash..."
  unset HISTFILE; history -c 2>/dev/null || true
  echo -e "История Bash очищена. ${WHT}Можно продолжать.${NC}"
  sleep $SLEEP_DELAY

  # --- Удаление следов установщика ---
  print_step "Удаление следов установщика..."
  if [ "$IS_HEQET" = true ]; then
    echo "Обработано предустановкой ISO. Дополнительных действий не требуется."
  fi
  if [ "$IS_HEQET" = false ]; then
    local script_path
    script_path=$(realpath "$0")
    echo "Попытка удалить файл скрипта: $script_path"
    echo
    if [[ -w "$script_path" ]]; then
      if rm -- "$script_path"; then
        echo "Скрипт успешно удалён."
      else
        echo "ВНИМАНИЕ: Не удалось удалить файл скрипта: $script_path"
      fi
    else
      echo "ВНИМАНИЕ: Файл скрипта недоступен для записи. Пропуск удаления."
    fi
    echo
    # Проверка, что файл действительно удалён
    if find /tmp /usr/local/bin /root -name 'Freepbx17_debian12.sh' 2>/dev/null | grep -q .; then
      echo -e "${BRED}ВНИМАНИЕ: скрипт всё ещё найден на диске. Удалите вручную.${NC}"
    else
      echo -e "Проверка… Удаление подтверждено. ${WHT}Можно продолжать.${NC}"
    fi
    echo
    sleep 4
  fi
}


# ===================================================================================
# БЛОК ФИНАЛИЗАЦИИ
# Выводит финальное сообщение и восстанавливает приглашение входа
# на tty1 (для ISO Heqet).
# ===================================================================================


postinstall_finalize() {
  # --- Сообщение для cloud-init (неинтерактивный режим без ISO) ---
  if [ "$IS_HEQET" = false ] && [ "$IS_NONINTERACTIVE" = true ]; then
    print_completion
    sleep 4
  fi

  # --- Восстановление getty на tty1 (только для ISO Heqet) ---
  # На Heqet ISO tty1 маскируется, чтобы показать вывод установки.
  # После установки возвращаем обычное приглашение входа.
  if [ "$IS_HEQET" = true ]; then
    print_completion
    sleep 4
    echo -e "    Восстанавливается приглашение входа в систему..."
    print_step "Восстановление приглашения входа на tty1..."
    systemctl unmask getty@tty1.service
    systemctl enable getty@tty1.service
    systemctl restart getty@tty1.service
  fi
}


# ===================================================================================
# ИНТЕРАКТИВНОЕ МЕНЮ
# Позволяет запускать отдельные шаги установки по выбору или
# запустить полную установку.
# ===================================================================================


# --- Описание пунктов меню ---
MENU_ITEMS=(
  "1.  Предварительные проверки системы"
  "2.  Проверка конфликтов (FreePBX/Asterisk/MariaDB/Node.js)"
  "3.  Подготовка APT (источники, обновление, upgrade)"
  "4.  Сетевые проверки (IP, iptables, DNS, порт 80)"
  "5.  Проверка зеркал FreePBX"
  "6.  Проверка доступности установщика"
  "7.  Установка FreePBX 17"
  "8.  Постустановка модулей (upgradeall, chown, reload)"
  "9.  Настройка Apache и проверка GUI"
  "10. Очистка (логи, следы, история)"
  "11. Финализация"
  "12. Запустить полную установку (все шаги по порядку)"
  "13. Проверить статус установки"
  "14. Выбор зеркала FreePBX (git.freepbx.asterisk.ru и др.)"
  "15. Применить выбранное зеркало к существующей установке"
  "0.  Выход"
)

# --- Маршрутизация пунктов меню к функциям ---
run_menu_item() {
  local choice="$1"
  case "$choice" in
    1)
      print_step ">>> Запуск: Предварительные проверки системы"
      preflight_system_checks
      ;;
    2)
      print_step ">>> Запуск: Проверка конфликтов"
      preflight_conflict_checks
      ;;
    3)
      print_step ">>> Запуск: Подготовка APT"
      preflight_apt_prepare
      ;;
    4)
      print_step ">>> Запуск: Сетевые проверки"
      preflight_network_checks
      ;;
    5)
      print_step ">>> Запуск: Проверка зеркал FreePBX"
      MIRROR_OK=false
      MIRROR_GOOD_COUNT=0
      preflight_mirror_checks
      ;;
    6)
      print_step ">>> Запуск: Проверка доступности установщика"
      preflight_installer_checks
      ;;
    7)
      print_step ">>> Запуск: Установка FreePBX 17"
      install_freepbx
      ;;
    8)
      print_step ">>> Запуск: Постустановка модулей"
      postinstall_modules
      ;;
    9)
      print_step ">>> Запуск: Настройка Apache и проверка GUI"
      postinstall_apache
      ;;
    10)
      print_step ">>> Запуск: Очистка"
      postinstall_cleanup
      ;;
    11)
      print_step ">>> Запуск: Финализация"
      postinstall_finalize
      ;;
    12)
      print_step ">>> Запуск полной установки (все шаги по порядку)"
      run_full_install
      ;;
    13)
      print_step ">>> Проверка статуса установки"
      check_install_status
      ;;
    14)
      print_step ">>> Выбор зеркала FreePBX"
      select_mirror
      ;;
    15)
      print_step ">>> Применение зеркала к существующей установке"
      apply_mirror_existing
      ;;
    0)
      echo -e "${CYAN}До свидания.${NC}"
      exit 0
      ;;
    *)
      echo -e "${BRED}Неверный выбор: $choice${NC}"
      ;;
  esac
}

# --- Запуск полной установки (все шаги по порядку) ---
# Если зеркало не выбрано — по умолчанию используется первое из массива MIRRORS
run_full_install() {
  if [[ -z "$SELECTED_MIRROR" ]]; then
    local name url gpg
    IFS='|' read -r name url gpg <<< "${MIRRORS[0]}"
    SELECTED_MIRROR_NAME="$name"
    SELECTED_MIRROR="$url"
    SELECTED_MIRROR_GPG="$gpg"
    echo -e "${BYEL}Зеркало по умолчанию: $name${NC}"
  fi

  # Последовательность шагов полной установки
  local steps=(1 2 3 4 5 6 7 8 9 10 11)
  local total=${#steps[@]}
  local current=0

  for step in "${steps[@]}"; do
    current=$((current + 1))
    echo
    echo -e "${BMAG}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BMAG}  Шаг $current из $total ${NC}"
    echo -e "${BMAG}═══════════════════════════════════════════════════════════${NC}"
    run_menu_item "$step"
  done

  echo
  echo -e "${BGRN}Полная установка завершена.${NC}"
  echo
  print_completion
}


# ===================================================================================
# ПРОВЕРКА СТАТУСА УСТАНОВКИ
# Выводит сводную таблицу состояния всех компонентов FreePBX.
# ===================================================================================


check_install_status() {
  echo
  echo -e "${BMAG}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BMAG}  ПРОВЕРКА СТАТУСА УСТАНОВКИ${NC}"
  echo -e "${BMAG}═══════════════════════════════════════════════════════════${NC}"
  echo

  # --- FreePBX ---
  echo -ne "  FreePBX:           "
  if [[ -f /etc/freepbx.conf || -d /var/www/html/admin ]]; then
    echo -e "${BGRN}установлен${NC}"
  else
    echo -e "${BRED}не найден${NC}"
  fi

  # --- Asterisk ---
  echo -ne "  Asterisk:          "
  if command -v asterisk >/dev/null 2>&1; then
    local ast_ver
    ast_ver=$(asterisk -V 2>/dev/null || echo "версия недоступна")
    echo -e "${BGRN}$ast_ver${NC}"
  else
    echo -e "${BRED}не установлен${NC}"
  fi

  # --- MariaDB ---
  echo -ne "  MariaDB:           "
  if systemctl is-active --quiet mariadb 2>/dev/null; then
    echo -e "${BGRN}запущена${NC}"
  elif command -v mariadbd >/dev/null 2>&1; then
    echo -e "${BYEL}установлена, но не запущена${NC}"
  else
    echo -e "${BRED}не установлена${NC}"
  fi

  # --- Apache ---
  echo -ne "  Apache:            "
  if systemctl is-active --quiet apache2 2>/dev/null; then
    echo -e "${BGRN}запущен${NC}"
  elif command -v apache2 >/dev/null 2>&1; then
    echo -e "${BYEL}установлен, но не запущен${NC}"
  else
    echo -e "${BRED}не установлен${NC}"
  fi

  # --- Node.js ---
  echo -ne "  Node.js:           "
  if command -v node >/dev/null 2>&1; then
    echo -e "${BGRN}$(node -v 2>/dev/null)${NC}"
  else
    echo -e "${BRED}не установлен${NC}"
  fi

  # --- fwconsole ---
  echo -ne "  fwconsole:         "
  if command -v fwconsole >/dev/null 2>&1; then
    echo -e "${BGRN}доступен${NC}"
  else
    echo -e "${BRED}не найден${NC}"
  fi

  # --- ionCube Loader ---
  echo -ne "  ionCube Loader:    "
  if command -v php >/dev/null 2>&1; then
    local ioncube_info
    ioncube_info=$(php -m 2>/dev/null | grep -i '^ionCube' | head -1)
    if [[ -n "$ioncube_info" ]]; then
      local ioncube_ver
      ioncube_ver=$(php -r 'if (function_exists("ioncube_loader_version")) { echo ioncube_loader_version(); }' 2>/dev/null || echo "")
      if [[ -n "$ioncube_ver" ]]; then
        echo -e "${BGRN}$ioncube_info — v$ioncube_ver${NC}"
      else
        echo -e "${BGRN}$ioncube_info${NC}"
      fi
    else
      echo -e "${BRED}не загружен (FreePBX не будет работать)${NC}"
    fi
  else
    echo -e "${BRED}PHP не установлен${NC}"
  fi

  # --- Порт 80 ---
  echo -ne "  Порт 80:           "
  if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    local port80_proc
    port80_proc=$(ss -tlnp 2>/dev/null | grep ':80 ' | awk -F'"' '{print $2}' | sort -u | head -1)
    echo -e "${BGRN}слушается ($port80_proc)${NC}"
  else
    echo -e "${BRED}не слушается${NC}"
  fi

  # --- Веб-интерфейс FreePBX ---
  echo -ne "  FreePBX GUI:       "
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -n "$ip" ]]; then
    local http_check
    http_check=$(curl -s --max-time 5 "http://$ip/admin/config.php" 2>/dev/null)
    if echo "$http_check" | grep -q 'Welcome to FreePBX'; then
      echo -e "${BGRN}доступна (http://$ip/admin)${NC}"
    elif echo "$http_check" | grep -q 'ionCube'; then
      echo -e "${BRED}ошибка ionCube Loader${NC}"
    elif [[ -n "$http_check" ]]; then
      echo -e "${BYEL}отвечает, но содержимое не распознано${NC}"
    else
      echo -e "${BRED}не отвечает${NC}"
    fi
  else
    echo -e "${BRED}IP не определён${NC}"
  fi

  # --- Текущее зеркало FreePBX (из файла) ---
  echo -ne "  Зеркало FreePBX:   "
  local freepbx_list="/etc/apt/sources.list.d/freepbx.list"
  if [[ -f "$freepbx_list" ]]; then
    local mirror_url
    mirror_url=$(grep -oE 'https?://[^ "]+' "$freepbx_list" | head -1)
    if [[ -n "$mirror_url" ]]; then
      echo -e "${BGRN}$mirror_url${NC}"
    else
      echo -e "${BYEL}найден, но URL не распознан${NC}"
    fi
  else
    echo -e "${BRED}freepbx.list не найден${NC}"
  fi

  # --- Зеркало, выбранное в меню ---
  echo -ne "  Выбрано в меню:    "
  if [[ -n "$SELECTED_MIRROR" ]]; then
    echo -e "${BGRN}$SELECTED_MIRROR_NAME${NC}"
  else
    echo -e "${BYEL}не выбрано${NC}"
  fi

  # --- Свободное место на диске ---
  echo -ne "  Свободно на /:     "
  local avail_kb
  avail_kb=$(df / | tail -1 | awk '{print $4}')
  echo -e "${WHT}$(awk "BEGIN {printf \"%.2f\", $avail_kb/1024/1024}") ГБ${NC}"

  # --- Память ---
  echo -ne "  RAM / Swap:        "
  local mem_mb swap_mb
  mem_mb=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
  swap_mb=$(($(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024))
  echo -e "${WHT}${mem_mb} МБ / ${swap_mb} МБ${NC}"

  echo
  echo -e "${BMAG}═══════════════════════════════════════════════════════════${NC}"
  echo

  # Пауза перед возвратом в меню (только в интерактивном режиме)
  if [ "$IS_NONINTERACTIVE" = false ] && [ "$MENU_MODE" = true ]; then
    read -r -p "$(echo -e "${BYEL}  Нажмите Enter для возврата в меню...${NC}")"
  fi
}

# --- Отрисовка главного меню ---
# Цикл с отображением списка пунктов и маршрутизацией выбора.
show_menu() {
  while true; do
    echo
    echo -e "${BMAG}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BMAG}║         Скрипт ${VERSION} — Меню установки FreePBX 17      ║${NC}"
    echo -e "${BMAG}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo

    # Показ выбранного зеркала в шапке меню
    if [[ -n "$SELECTED_MIRROR" ]]; then
      echo -e "  ${BGRN}Зеркало:${NC} $SELECTED_MIRROR_NAME"
    else
      echo -e "  ${BYEL}Зеркало:${NC} не выбрано (пункт 14)"
    fi
    echo

    for item in "${MENU_ITEMS[@]}"; do
      echo -e "  ${WHT}$item${NC}"
    done
    echo
    echo -e "${BYEL}  Любой пункт можно запускать повторно для проверки.${NC}"
    echo
    printf "${BYEL}  Выберите пункт [0-15]: ${NC}"
    read -r menu_choice

    if [[ -z "$menu_choice" ]]; then
      echo -e "${BRED}  Пустой ввод. Введите число от 0 до 15.${NC}"
      continue
    fi

    run_menu_item "$menu_choice"

    # После выполнения пункта (кроме выхода) — возвращаемся в меню
    if [[ "$menu_choice" != "0" ]]; then
      echo
      echo -e "${BYEL}  ──────────────────────────────────────────${NC}"
      echo -e "${BGRN}  Шаг завершён. Возвращаемся в меню...${NC}"
      echo -e "${BYEL}  ──────────────────────────────────────────${NC}"
      sleep 2
    fi
  done
}


#####################################################################################
#       ОСНОВНОЙ ХОД ВЫПОЛНЕНИЯ 
#####################################################################################


# --- Режим меню (--menu) ---
if [ "$MENU_MODE" = true ]; then
  show_menu
  exit 0
fi

# --- Режим полной установки (--full) ---
if [ "$RUN_FULL" = true ]; then
  run_full_install
  exit 0
fi

# --- Стандартный режим: предустановочные проверки → установка ---
if [ "$SKIP_CHECKS" = false ]; then
  preflight_system_checks           # Проверка ОС, диска, памяти, архитектуры
  preflight_conflict_checks         # Проверка отсутствия конфликтующих установок
  preflight_apt_prepare             # Подготовка APT: источники, update, upgrade
  preflight_network_checks          # Сетевые проверки: IP, DNS, порты
  preflight_mirror_checks           # Проверка зеркал FreePBX
  preflight_installer_checks        # Проверка доступности установщика
  launch_in_screen "$@"             # Перезапуск в screen для устойчивости
  SKIP_CHECKS=true
fi

# --- Установка (внутри screen, если применимо) ---
if [ "$SKIP_CHECKS" = true ]; then
  echo
  echo -e "${BGRN}Предварительные проверки завершены. Подготовка к запуску, пристегните ремни.${NC}"
  sleep 4
  echo

  # Перехват Ctrl+C — вызываем обработчик сбоя
  trap 'handle_install_failure' INT

  install_freepbx                  # Скачивание и запуск официального установщика
  postinstall_modules              # Обновление модулей, права, перезагрузка
  postinstall_apache               # Настройка Apache и проверка веб-интерфейса
  postinstall_cleanup              # Очистка логов, временных файлов, истории
  postinstall_finalize             # Финальное сообщение, восстановление tty1
fi

exit 0
