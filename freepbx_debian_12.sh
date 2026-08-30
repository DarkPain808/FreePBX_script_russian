#!/bin/bash
#####################################################################################
#     FreePBX 17
#####################################################################################
# * Copyright 2024 by Sangoma Technologies
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3.0
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# @author kgupta@sangoma.com
#
# Этот скрипт установки FreePBX и все концепции являются собственностью
# Sangoma Technologies.
# Скрипт можно свободно использовать только для установки FreePBX
# вместе с зависимыми пакетами, но он не даёт гарантий производительности
# и используется на ваш страх и риск. Скрипт предоставляется БЕЗ ГАРАНТИЙ.
#
#####################################################################################
#     Ключи для запуска скрипта
#####################################################################################
#  ./tmp/freepbx_debian_12.sh --dahdi
#                             --testing
#                             --nofreepbx
#                             --noasterisk
#                             --dahdi-only
#                             --skipversion
#                             --opensouceonly
#
#####################################################################################
#     Предварительная настройка
#####################################################################################

# Включаем строгий режим: скрипт немедленно завершится при любой ошибке команды
set -e

# -----------------------------------------------------------------------------------
# Переменные
# -----------------------------------------------------------------------------------
SCRIPTVER="1.15"                       # Версия самого скрипта установки

DEBIAN_OS_VERSION=""                   # Переменная для хранения кодового имени версии ОС Debian (например, bookworm, trixie)

ASTVERSION=${ASTVERSION:-22}           # Версия Asterisk для установки (по умолчанию — 22)
PHPVERSION="8.2"                       # Требуемая версия PHP для работы FreePBX
NPM_MIRROR=""                          # Зеркало для NPM (может быть задано через параметр --npmmirror)

DEBIAN_MIRROR="http://ftp.debian.org/debian"             # Зеркало репозитория Debian (по умолчанию — официальное зеркало)

LOG_FOLDER="/var/log/pbx"              # Папка, где будут храниться логи процесса установки
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
                                       # Имя файла лога: включает путь, название и временную метку (год.месяц.день-час.минута.секунда)
log=$LOG_FILE                          # Удобная переменная-ссылка на файл лога

# Фиксированный «безопасный» PATH: гарантирует, что скрипт будет использовать стандартные пути,
# а не те, которые могли быть заданы в пользовательской сессии (особенно важно при запуске от root)
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Определяем версию ОС по файлу /etc/os-release: 
# ищем строку VERSION_CODENAME= и берём значение после неё
if [ -f /etc/os-release ]; then
    DEBIAN_OS_VERSION=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release)
fi

# Если версия не определена через os-release, пробуем определить по /etc/debian_version
# (это запасной вариант для старых или минималистичных установок)
if [ -z "$DEBIAN_OS_VERSION" ] && [ -f /etc/debian_version ]; then
    case "$(cat /etc/debian_version)" in
        12*|bookworm)
            # Если версия начинается с 12 или явно указана как bookworm — это Debian 12
            DEBIAN_OS_VERSION="bookworm"
            ;;
        13*|trixie)
            # Если версия начинается с 13 или явно указана как trixie — это Debian 13
            DEBIAN_OS_VERSION="trixie"
            ;;
        *)
            # Во всех остальных случаях помечаем как unknown (неизвестная версия)
            DEBIAN_OS_VERSION="unknown"
            ;;
    esac
fi

# Проверка совместимости ОС: поддерживается только Debian 12 (bookworm)
if [ "$DEBIAN_OS_VERSION" != "bookworm" ]; then
    echo "Unsupported OS version. This script supports only Debian 12 (bookworm). Detected: $DEBIAN_OS_VERSION"
    exit 1
fi

# Проверка прав суперпользователя: скрипт должен запускаться от root (EUID = 0)
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi


# Устанавливаем безопасный PATH для выполнения скрипта от root, чтобы не зависеть от пользовательских настроек
export PATH=$SANE_PATH

# -----------------------------------------------------------------------------------
# Обрабатываем аргументы командной строки, переданные при запуске скрипта
# -----------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case $1 in
		--dev)
			# Режим разработки: устанавливаются дополнительные пакеты и компоненты для разработки
			dev=true
			shift # переходим к следующему аргументу
			;;
		--disable-deb-update-v13)
			# Только обновить репозитории и заблокировать переход на Debian 13 (Trixie), без установки FreePBX
			disableDebUpdateToV13=true
			shift
			;;
		--testing)
			# Использовать тестовый репозиторий FreePBX вместо стабильного
			testrepo=true
			shift
			;;
		--nofreepbx)
			# Пропустить установку FreePBX (например, если нужно только настроить Asterisk)
			nofpbx=true
			shift
			;;
		--noasterisk)
			# Пропустить установку Asterisk
			noast=true
			shift
			;;
		--opensourceonly)
			# Установить только открытые (бесплатные) модули FreePBX, исключить коммерческие
			opensourceonly=true
			shift
			;;
		--noaac)
			# Не устанавливать кодек AAC (libfdk-aac2)
			noaac=true
			shift
			;;
		--skipversion)
			# Пропустить проверку версии скрипта на GitHub
			skipversion=true
			shift
			;;
		--dahdi)
			# Включить поддержку DAHDI (для телефонии через платы)
			dahdi=true
			shift
			;;
		--dahdi-only)
			# Установка только DAHDI без FreePBX и Asterisk (для настройки оборудования)
			nofpbx=true
			noast=true
			noaac=true
			dahdi=true
			shift
			;;
		--nochrony)
			# Не устанавливать и не настраивать chrony (синхронизацию времени)
			nochrony=true
			shift
			;;
		--debianmirror)
			# Указать альтернативное зеркало репозитория Debian
			DEBIAN_MIRROR=$2
			shift; shift # пропускаем и параметр, и его значение
			;;
    --npmmirror)
      # Указать альтернативное зеркало для NPM
      NPM_MIRROR=$2
      shift; shift
      ;;
		-*)
			# Если передан неизвестный параметр (начинается с -), выводим ошибку и завершаем скрипт
			echo "Unknown option $1"
			exit 1
			;;
		*)
			# Если передан аргумент без флага (не начинается с -), считаем его неизвестным
			echo "Unknown argument \"$1\""
			exit 1
			;;
	esac
done

# -----------------------------------------------------------------------------------
# Функция для блокировки обновлений до Debian 13 (Trixie) через приоритеты APT
# -----------------------------------------------------------------------------------
block_debian13_trixie_update() {
	cat >/etc/apt/preferences.d/99-block-trixie.pref <<'EOF'
# Блокируем обновления до Debian 13 Trixie
Package: *
Pin: release n=trixie
Pin-Priority: -1

EOF
}

# -----------------------------------------------------------------------------------
# Функция для исправления репозиториев: 
# заменить stable на bookworm, stable-security на bookworm-security
# -----------------------------------------------------------------------------------
fix_debian12_repo() {
	# --- Исправляем файлы sources.list, чтобы они указывали на bookworm ---
	for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
		[ -f "$file" ] || continue
		# Ищем строки с основным репозиторием Debian и заменяем «stable» на «bookworm»
		if grep -qE "deb\s+$DEBIAN_MIRROR\s+stable\b" "$file"; then
			sed -i.bak -E "s|(deb\s+$DEBIAN_MIRROR\s+)stable\b|\1bookworm|g" "$file"
		fi

	    # Ищем строки с репозиторием безопасности и заменяем «stable-security» на «bookworm-security»
	    if grep -qE "deb\s+http://security\.debian\.org/debian-security\s+stable-security\b" "$file"; then
		    sed -i.bak -E "s|(deb\s+http://security\.debian\.org/debian-security\s+)stable-security\b|\1bookworm-security|g" "$file"
	    fi
    done
}

# Если указан флаг --disable-deb-update-v13: обновляем репозитории, блокируем Trixie и завершаем работу
if [ -n "$disableDebUpdateToV13" ]; then
	    # Исправляем текущие репозитории Debian, чтобы они указывали на bookworm
	    fix_debian12_repo
	    # Блокируем обновления до Debian 13/Trixie, так как FreePBX пока поддерживает только Debian 12/Bookworm
	    block_debian13_trixie_update
	    echo "Debian repositories have been updated to use the Bookworm (Debian 12) sources."
	    echo "The script is exiting now because the '--disable-deb-update-v13' option was used."
	    echo "This option предназначен только для обновления источников APT без запуска полной установки."
	    echo "To run the full installation, please re-run the script **without** the '--disable-deb-update-v13' option."
	    exit 1
fi

# Создаём папку для логов (если её нет) и пустой файл лога
mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"

# Перенаправляем стандартный поток ошибок (stderr, дескриптор 2) в файл лога.
# Теперь все ошибки команд будут автоматически записываться в лог-файл.
exec 2>>"${LOG_FILE}"

# Функция сравнения версий с помощью утилиты dpkg --compare-versions
compare_version() {
        if dpkg --compare-versions "$1" "gt" "$2"; then
                # Если первая версия больше второй
                result=0
        elif dpkg --compare-versions "$1" "lt" "$2"; then
                # Если первая версия меньше второй
                result=1
        else
                # Версии равны
                result=2
        fi
}

# -----------------------------------------------------------------------------------
# Функция проверки актуальности версии скрипта на GitHub
# -----------------------------------------------------------------------------------
check_version() {
    # URL репозитория, где хранится последняя версия скрипта
    REPO_URL="https://github.com/FreePBX/sng_freepbx_debian_install/raw/master"
    # Скачиваем последнюю версию скрипта во временный файл
    wget -O /tmp/sng_freepbx_debian_install_latest_from_github.sh "$REPO_URL/sng_freepbx_debian_install.sh" >> "$log"

    # Извлекаем версию из скачанного файла (ищем строку SCRIPTVER="..." и берём значение)
    latest_version=$(grep '^SCRIPTVER="' /tmp/sng_freepbx_debian_install_latest_from_github.sh | awk -F'"' '{print $2}')
    # Вычисляем контрольную сумму (SHA‑256) скачанного файла
    latest_checksum=$(sha256sum /tmp/sng_freepbx_debian_install_latest_from_github.sh | awk '{print $1}')

    # Удаляем временный файл после использования
    rm -f /tmp/sng_freepbx_debian_install_latest_from_github.sh

    # Сравниваем текущую версию скрипта ($SCRIPTVER) с последней на GitHub ($latest_version)
    compare_version $SCRIPTVER "$latest_version"

    case $result in
            0)
                # Текущая версия скрипта новее, чем на GitHub
                echo "Your version ($SCRIPTVER) of installation script is ahead of the latest version ($latest_version) as present on the GitHub. We recommend you to Download the version present in the GitHub."
                echo "Use '$0 --skipversion' to skip the version check"
                exit 1
            ;;

            1)
                # Найдена более новая версия на GitHub
                echo "A newer version ($latest_version) of installation script is available on GitHub. We recommend you to update it or use the latest one from the GitHub."
                echo "Use '$0 --skipversion' to skip the version check."
                exit 0
            ;;

            2)
                # Версии совпадают — проверяем контрольную сумму, чтобы убедиться, что скрипт не был изменён локально
                local_checksum=$(sha256sum "$0" | awk '{print $1}')
                if [[ "$latest_checksum" != "$local_checksum" ]]; then
                        # Контрольная сумма отличается — значит, локальный скрипт был изменён
                        echo "Changes are detected between the local installation script and the latest installation script as present on GitHub. We recommend you to please use the latest installation script as present on GitHub."
                        echo "Use '$0 --skipversion' to skip the version check"
                        exit 0
                else
                        # Всё совпадает — скрипт актуален
                        echo "Perfect! You're already running the latest version."
                fi
            ;;
        esac
}

# -----------------------------------------------------------------------------------
# Функции для логирования сообщений
# -----------------------------------------------------------------------------------
# Функция с временной меткой: выводит текущую дату и время, затем все переданные аргументы
echo_ts() {
	echo "$(date +"%Y-%m-%d %T") - $*"
}

# Простая функция логирования: добавляет сообщение в файл лога с временной меткой
log() {
	echo_ts "$*" >> "$LOG_FILE"
}

# Функция вывода сообщения: показывает текст в терминале и одновременно записывает в лог-файл
message() {
	echo_ts "$*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------------
# Функция для фиксации и отображения текущего шага установки
# -----------------------------------------------------------------------------------
setCurrentStep () {
	currentStep="$1"
	message "${currentStep}"
}

# -----------------------------------------------------------------------------------
# Функция завершения установки (используется при аварийном выходе)
# -----------------------------------------------------------------------------------
terminate() {
	# Если код возврата не равен 0 (была ошибка), выводим последние 10 строк лога
	if [ $? -ne 0 ]; then
		echo_ts "Displaying last 10 lines from the log file"
		tail -n 10 "$LOG_FILE"
	fi
	# Удаляем PID‑файл, если он существует (чтобы не было ложных пометок о работающем процессе)
	rm -f "$pidfile"
	message "Exiting script"
}

# Функция обработки ошибок: логирует факт сбоя, выводит сообщение и завершает скрипт
errorHandler() {
	log "****** INSTALLATION FAILED *****"
	echo_ts "Installation failed at step ${currentStep}. Please check log ${LOG_FILE} for details."
	# Записываем в лог: номер строки, код ошибки и последнюю выполненную команду
	log "Error at line: $1 exiting with code $2 (last command was: $3)"
	exit "$2"
}

# -----------------------------------------------------------------------------------
# Функция проверки, установлен ли пакет в системе
# -----------------------------------------------------------------------------------
isinstalled() {
	# Получаем статус пакета через dpkg-query; ищем строку «install ok installed»
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null | grep "install ok installed")
	if [ "" = "$PKG_OK" ]; then
		# Если ничего не найдено — пакет не установлен, возвращаем false
		false
	else
		# Пакет установлен — возвращаем true
		true
	fi
}

# -----------------------------------------------------------------------------------
# Функция установки пакета (с проверкой, логированием и обработкой ошибок)
# -----------------------------------------------------------------------------------
pkg_install() {
    log "############################### "
    PKG=("$@")  # Сохраняем все переданные аргументы как массив пакетов
    if isinstalled "${PKG[@]}"; then
        # Если пакет уже установлен — просто логируем это
        log "${PKG[*]} already present ...."
    else
        # Выводим сообщение в терминал и пишем в лог о начале установки
        message "Installing ${PKG[*]} ...."
        # Устанавливаем пакеты через apt-get с флагами:
        # -y — автоматически подтверждать установку
        # --ignore-missing — игнорировать отсутствующие зависимости
        # --force-confnew — при конфликте конфигов использовать новую версию
        # --force-overwrite — разрешить перезапись файлов
        apt-get -y --ignore-missing -o DPkg::Options::="--force-confnew" -o Dpkg::Options::="--force-overwrite" install "${PKG[@]}" >> "$log"

        # Проверяем, действительно ли пакеты установились
        if isinstalled "${PKG[@]}"; then
            message "${PKG[*]} installed successfully...."
        else
            # Если установка не удалась — сообщаем об ошибке и инициируем завершение
            message "${PKG[*]} failed to install ...."
            message "Exiting the installation process as dependent ${PKG[*]} failed to install ...."
            terminate
        fi
    fi
    log "############################### "
}

# -----------------------------------------------------------------------------------
# Функция установки Asterisk и зависимых модулей
# -----------------------------------------------------------------------------------
install_asterisk() {
	astver=$1  # Переданная версия Asterisk (например, 22)

	# Список модулей Asterisk, которые нужно установить
	ASTPKGS=(
		"addons"
		"addons-bluetooth"
		"addons-core"
		"addons-mysql"
		"addons-ooh323"
		"core"
		"curl"
		"dahdi"
		"doc"
		"odbc"
		"ogg"
		"flite"
		"g729"
		"resample"
		"snmp"
		"speex"
		"sqlite3"
		"res-digium-phone"
		"voicemail"
	)

	# Создаём директорию для музыки на удержании (MOH) — это обязательный каталог для Asterisk
	mkdir -p /var/lib/asterisk/moh

	# Устанавливаем основную версию Asterisk
	pkg_install asterisk"$astver"

	# В цикле устанавливаем все дополнительные модули из списка ASTPKGS
	for i in "${!ASTPKGS[@]}"; do
		pkg_install asterisk"$astver"-"${ASTPKGS[$i]}"
	done

	# Устанавливаем модули Asterisk, специфичные для FreePBX
	pkg_install asterisk"$astver".0-freepbx-asterisk-modules
	# Устанавливаем утилиту переключения версий Asterisk (если нужно переключаться между разными версиями)
	pkg_install asterisk-version-switch
	# Устанавливаем звуковые файлы (озвучку) для Asterisk (все доступные варианты)
	pkg_install asterisk-sounds-*
}

# -----------------------------------------------------------------------------------
# Функция настройки репозиториев для установки FreePBX и зависимостей
# Использует российское зеркало: git.freepbx.asterisk.ru
# -----------------------------------------------------------------------------------
setup_repositories() {
	# Удаляем старый GPG‑ключ Sangoma (если он есть), чтобы избежать конфликтов с новым ключом
	apt-key del "9641 7C6E 0423 6E0A 986B  69EF DE82 7447 3C8D 0E52" >> "$log"

	# Скачиваем и импортируем новый GPG‑ключ для репозитория FreePBX
	wget -O - "http://git.freepbx.asterisk.ru/gpg/aptly-pubkey.asc" | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg  >> "$log"

	# Выбираем URL репозитория в зависимости от режима (тестовый или стабильный)
	if [ "$testrepo" ]; then
		REPO_URL="http://git.freepbx.asterisk.ru/freepbx17-dev"
	else
		REPO_URL="http://git.freepbx.asterisk.ru/freepbx17-prod"
	fi

	# Формируем строку подключения репозитория FreePBX для Debian Bookworm
	REPO_LINE="deb [arch=amd64] $REPO_URL bookworm main"
	REPO_FILE="/etc/apt/sources.list"

	# Добавляем репозиторий FreePBX, только если его ещё нет в sources.list
	if ! grep -qsF "$REPO_LINE" "$REPO_FILE" 2>/dev/null; then
		echo "$REPO_LINE" | tee -a "$REPO_FILE" >> "$log"
		echo "Added FreePBX repo: $REPO_LINE" >> "$log"
	else
		echo "FreePBX repo already exists: $REPO_LINE" >> "$log"
	fi

	# Если не указан флаг --noaac, добавляем основной репозиторий Debian (включая non-free и non-free-firmware)
	if [ -z "$noaac" ]; then
	     # Формируем строку основного репозитория Debian Bookworm с нужными секциями
	     REPO_LINE="deb $DEBIAN_MIRROR bookworm main non-free non-free-firmware"

	     # Добавляем репозиторий, только если он ещё не присутствует
	     if ! grep -qsF "$REPO_LINE" "$REPO_FILE"; then
		     echo "$REPO_LINE" | tee -a "$REPO_FILE" >> "$log"
		     echo "Added Bookworm main repo: $REPO_LINE" >> "$log"
	     else
		     echo "Bookworm main repo already exists: $REPO_LINE" >> "$log"
	     fi			

	    # Исправляем текущие репозитории Debian, чтобы они указывали на bookworm вместо stable
	    fix_debian12_repo
	    # Блокируем обновления до Debian 13/Trixie, так как FreePBX пока поддерживает только Debian 12/Bookworm
	    block_debian13_trixie_update
	fi

	# Обновляем списки пакетов после добавления новых репозиториев
	apt-get update >> "$log"

	setCurrentStep "Setting up Sangoma repository"

    local aptpref="/etc/apt/preferences.d/99sangoma-fpbx-repository"
    # Создаём файл предпочтений APT, чтобы задать приоритет для пакетов из репозитория deb.freepbx.org
    cat > "$aptpref" <<EOF
Package: *
Pin: origin deb.freepbx.org
Pin-Priority: ${MIRROR_PRIO}
EOF

    # Если указан флаг --noaac, дополнительно понижаем приоритет пакета ffmpeg из репозитория FreePBX
    if [ "$noaac" ]; then
    cat >> "$aptpref" <<EOF

Package: ffmpeg
Pin: origin deb.freepbx.org
Pin-Priority: 1
EOF
    fi
}

# -----------------------------------------------------------------------------------
# Функция создания скрипта, который запускается после каждой команды apt,
# чтобы проверить и при необходимости обновить модули ядра для dahdi/wanpipe,
# а также выполнить другие пост‑операции
# -----------------------------------------------------------------------------------
create_post_apt_script() {
    # Проверяем, существует ли уже скрипт /usr/bin/post-apt-run. Если да — удаляем его, чтобы создать заново
    if [ -e "/usr/bin/post-apt-run" ]; then
        rm -f /usr/bin/post-apt-run
    fi

    message "Creating script to run post every apt command is finished executing"
    {
        echo "#!/bin/bash"
        echo ""
        # Если запущен процесс asterisk-version-switch, пропускаем выполнение скрипта,
        # чтобы не конфликтовать с переключением версии Asterisk
        echo "if pidof -x 'asterisk-version-switch' > /dev/null; then"
	echo "echo \"Asterisk version switch process is running, skipping post-apt script.\""
	echo "exit 0"
	echo "fi"
	echo ""
        # Проверяем, установлен ли пакет dahdi-linux (модуль ядра для телефонии)
        echo "dahdi_pres=\$(dpkg -l | grep dahdi-linux | wc -l)"
        echo ""
        # Если dahdi установлен, выполняем проверку и обновление модулей ядра под текущую версию ядра
        echo "if [[ \$dahdi_pres -gt 0 ]]; then"
	echo "    kernel_idx=\$(grep -v '^#' /etc/default/grub | grep GRUB_DEFAULT | cut -d '=' -f2 | tr -d '\"')"
	echo ""
	echo "    # Проверяем, содержит ли GRUB_DEFAULT символ '>' (формат с подменю, например '2>1')"
	echo "    if [[ \"\$kernel_idx\" == *\">\"* ]]; then"
	echo "        # Извлекаем индекс ядра после '>'"
	echo "        selected_idx=\"\${kernel_idx#*>}\""
	echo "        submenu_format=true"
	echo "    else"
	echo "        # Если это просто число — используем его напрямую"
	echo "        selected_idx=\"\$kernel_idx\""
	echo "        submenu_format=false"
	echo "    fi"
	echo ""
	# Получаем список версий ядер, присутствующих в grub.cfg (ищем строки вида «Linux 6.1.0-21-amd64»)
	echo "    kernel_pres=\$(grep -oP \"menuentry '.*?Linux \K[0-9.-]+(?=-amd64)\" /boot/grub/grub.cfg)"
	echo "    kernel_count=\$(echo \"\$kernel_pres\" | wc -l)"
	echo ""
	# Проверяем, не выходит ли выбранный индекс за пределы количества доступных ядер
	echo "    if [[ \"\$selected_idx\" -ge \"\$kernel_count\" ]]; then"
	echo "        if \$submenu_format; then"
	echo "            echo \"ERROR: GRUB_DEFAULT is set to '\$kernel_idx' (submenu index: \$selected_idx), but only \$kernel_count kernel entries are available.\""
        echo "            echo \"       This likely refers to a non-existent kernel inside a submenu (e.g., 'Advanced options for Debian GNU/Linux').\""
	echo "            echo \"       Please update /etc/default/grub to a valid submenu index between 0 and \$((kernel_count - 1)), then run: update-grub\""
	echo "        else"
	echo "            echo \"ERROR: GRUB_DEFAULT is set to '\$selected_idx', but only \$kernel_count kernel entries were found.\""
	echo "            echo \"       Valid indices are between 0 and \$((kernel_count - 1)).\""
	echo "            echo \"       Please update /etc/default/grub and run: update-grub\""
	echo "        fi"
	echo "        exit 1"
	echo "    fi"
	echo ""
	echo "    idx=0"
        # Перебираем найденные версии ядер и ищем ту, которая соответствует выбранному индексу в GRUB
        echo "    for kernel in \$kernel_pres; do"
        echo "        if [[ \$idx -ne \$selected_idx ]]; then"
        echo "            idx=\$((idx+1))"
        echo "            continue"
        echo "        fi"
        echo ""
        echo "        logger \"Checking kernel modules for dahdi and wanpipe for kernel image \$kernel\""
        echo ""
        # Проверяем, установлены ли модули ядра dahdi и wanpipe именно для этой версии ядра
        echo "        dahdi_kmod_pres=\$(dpkg -l | grep dahdi-linux-kmod | grep \$kernel | wc -l)"
        echo "        wanpipe_kmod_pres=\$(dpkg -l | grep kmod-wanpipe | grep \$kernel | wc -l)"
        echo ""
        # Если оба модуля отсутствуют — планируем их обновление через at (через 1 минуту)
        echo "        if [[ \$dahdi_kmod_pres -eq 0 ]] && [[ \$wanpipe_kmod_pres -eq 0 ]]; then"
        echo "            logger \"Upgrading dahdi-linux-kmod-\$kernel and kmod-wanpipe-\$kernel\""
        echo "            echo \"Please wait for approx 2 min once apt command execution is completed as dahdi-linux-kmod-\$kernel kmod-wanpipe-\$kernel update in progress\""
        echo "            apt -y upgrade dahdi-linux-kmod-\$kernel kmod-wanpipe-\$kernel > /dev/null 2>&1 | at now +1 minute&"
        echo "        elif [[ \$dahdi_kmod_pres -eq 0 ]]; then"
        # Если отсутствует только dahdi — обновляем только его
        echo "            logger \"Upgrading dahdi-linux-kmod-\$kernel\""
        echo "            echo \"Please wait for approx 2 min once apt command execution is completed as dahdi-linux-kmod-\$kernel update in progress\""
        echo "            apt -y upgrade dahdi-linux-kmod-\$kernel > /dev/null 2>&1 | at now +1 minute&"
        echo "        elif [[ \$wanpipe_kmod_pres -eq 0 ]];then"
        # Если отсутствует только wanpipe — обновляем только его
        echo "            logger \"Upgrading kmod-wanpipe-\$kernel\""
        echo "            echo \"Please wait for approx 2 min once apt command execution is completed as kmod-wanpipe-\$kernel update in progress\""
        echo "            apt -y upgrade kmod-wanpipe-\$kernel > /dev/null 2>&1 | at now +1 minute&"
        echo "        fi"
        echo ""
        echo "        break"
        echo "    done"
        echo "else"
        # Если dahdi/wanpipe не установлены вообще — ничего не делаем
        echo "    logger \"Dahdi / wanpipe is not present therefore, not checking for dahdi / wanpipe kmod upgrade\""
        echo "fi"
        echo ""
        # Удаляем дефолтный index.html веб‑сервера (если есть), чтобы не мешал работе FreePBX
        echo "if [ -e \"/var/www/html/index.html\" ]; then"
        echo "    rm -f /var/www/html/index.html"
        echo "fi"
    } >> /usr/bin/post-apt-run

    # Устанавливаем права на выполнение скрипта (rwxr‑xr‑x)
    chmod 755 /usr/bin/post-apt-run

    # Добавляем хук в APT: запускать /usr/bin/post-apt-run после каждого обновления пакетов
    if [ -e "/etc/apt/apt.conf.d/80postaptcmd" ]; then
        rm -f /etc/apt/apt.conf.d/80postaptcmd
    fi

    echo "DPkg::Post-Invoke {\"/usr/bin/post-apt-run\";};" >> /etc/apt/apt.conf.d/80postaptcmd
    chmod 644 /etc/apt/apt.conf.d/80postaptcmd
}

# -----------------------------------------------------------------------------------
# Функция проверки совместимости версии ядра с модулями dahdi/wanpipe
# -----------------------------------------------------------------------------------
check_kernel_compatibility() {
    # Определяем последнюю поддерживаемую версию модуля dahdi-linux-kmod из репозитория
    local latest_dahdi_supported_version=$(apt-cache search dahdi | grep -E "^dahdi-linux-kmod-[0-9]" | awk '{print $1}' | awk -F'-' '{print $4"-"$5}' | sort -n | tail -1)
    # Определяем последнюю поддерживаемую версию модуля kmod-wanpipe из репозитория
    local latest_wanpipe_supported_version=$(apt-cache search wanpipe | grep -E "^kmod-wanpipe-[0-9]" | awk '{print $1}' | awk -F'-' '{print $3"-"$4}' | sort -n | tail -1)
    # Переданная версия ядра для проверки
    local curr_kernel_version=$1

    # Если версии dahdi и wanpipe совпадают — принимаем эту версию как поддерживаемую,
    # иначе используем жёстко заданную версию ядра (запасной вариант)
    if dpkg --compare-versions "$latest_dahdi_supported_version" "eq" "$latest_wanpipe_supported_version"; then
        local supported_kernel_version=$latest_dahdi_supported_version
    else
        local supported_kernel_version="6.1.0.22"
    fi

    # Если текущая версия ядра новее поддерживаемой — прерываем установку FreePBX,
    # так как модули dahdi могут не работать
    if dpkg --compare-versions "$curr_kernel_version" "gt" "$supported_kernel_version"; then
        message "Aborting freepbx installation as detected kernel version $curr_kernel_version is not supported by freepbx dahdi module $supported_kernel_version"
	exit
    fi

    # Удаляем старый скрипт проверки ядра, если он есть
    if [ -e "/usr/bin/kernel-check" ]; then
        rm -f /usr/bin/kernel-check
    fi

    # В тестовом режиме проверку ядра можно пропустить
    if [ "$testrepo" ]; then
        message "Skipping Kernel Check. As Kernel Check is not required for testing repo....."
        return
    fi

    message "Creating kernel check script to allow proper kernel upgrades"
    {
        echo "#!/bin/bash"
        echo ""
        echo "curr_kernel_version=\"\""
        echo "supported_kernel_version=\"\""
        echo ""

        # Функция определения поддерживаемой версии ядра на основе пакетов dahdi и wanpipe
        echo "set_supported_kernel_version() {"
        echo "    local latest_dahdi_supported_version=\$(apt-cache search dahdi | grep -E \"^dahdi-linux-kmod-[0-9]\" | awk '{print \$1}' | awk -F'-' '{print \$4,-\$5}' | sed 's/[[:space:]]//g' | sort -n | tail -1)"
        echo "    local latest_wanpipe_supported_version=\$(apt-cache search wanpipe | grep -E \"^kmod-wanpipe-[0-9]\" | awk '{print \$1}' | awk -F'-' '{print \$3,-\$4}' | sed 's/[[:space:]]//g' | sort -n | tail -1)"
        echo "    curr_kernel_version=\$(uname -r | cut -d'-' -f1-2)"
        echo ""
        echo "    if dpkg --compare-versions \"\$latest_dahdi_supported_version\" \"eq\" \"\$latest_wanpipe_supported_version\"; then"
        echo "        supported_kernel_version=\$latest_dahdi_supported_version"
        echo "    else"
        echo "        supported_kernel_version=\"6.1.0-21\""
        echo "    fi"
        echo "}"
        echo ""

        # Функция разблокировки (unhold) пакетов ядра, если их версия не превышает поддерживаемую
        echo "check_and_unblock_kernel() {"
        echo "    local kernel_packages=\$(apt-mark showhold | grep -E ^linux-image-[0-9] | awk '{print \$1}')"
        echo ""
        echo "    if [[ \"w\$1\" != \"w\" ]]; then"
        echo "        # Сравниваем переданную версию с поддерживаемой"
        echo "        if dpkg --compare-versions \"\$1\" \"le\" \"\$supported_kernel_version\"; then"
        echo "            local is_on_hold=\$(apt-mark showhold | grep -E ^linux-image-[0-9] | awk '{print \$1}' | grep -w \"\$1\" | wc -l )"
        echo ""
        echo "            if [[ \$is_on_hold -gt 0 ]]; then"
        echo "                logger \"Un-Holding kernel version \$version to allow automatic updates.\""
        echo "                apt-mark unhold \"\$version\" >> /dev/null 2>&1"
        echo "            fi"
        echo "        fi"
        echo "        return"
        echo "    fi"
        echo ""
        # Проходим по всем удерживаемым пакетам ядра и снимаем hold, если версия допустима
        echo "    for package in \$kernel_packages; do"
        echo "        # Извлекаем версию ядра из имени пакета (например, linux-image-6.1.0-21-amd64 → 6.1.0-21)"
        echo "        local version=\$(echo \"\$package\" | awk -F'-' '{print \$3,-\$4}' | sed 's/[[:space:]]//g' | sort -n)"
        echo ""
        echo "        if dpkg --compare-versions \"\$version\" \"le\" \"\$supported_kernel_version\"; then"
        echo "            logger \"Un-Holding kernel version \$version to allow automatic updates.\""
        echo "            apt-mark unhold \"\$version\" >> /dev/null 2>&1"
        echo "        fi"
        echo "    done"
        echo "}"

        echo ""
        # Функция блокировки (hold) пакетов ядра, версии которых превышают поддерживаемую
        echo "check_and_block_kernel() {"
        echo "    if dpkg --compare-versions \"\$curr_kernel_version\" \"gt\" \"\$supported_kernel_version\"; then"
        echo "        logger \"Aborting as detected kernel version is not supported by freepbx dahdi module\""
        echo "    fi"
        echo ""

        echo "    local kernel_packages=\$( apt-cache search linux-image | grep -E \"^linux-image-[0-9]\" | awk '{print \$1}')"
        echo "    for package in \$kernel_packages; do"
        echo "        local version=\$(echo \"\$package\" | awk -F'-' '{print \$3,-\$4}' | sed 's/[[:space:]]//g' | sort -n)"
        echo ""

        echo "        if dpkg --compare-versions \"\$version\" \"gt\" \"\$supported_kernel_version\"; then"
        echo "            logger \"Holding kernel version \$version to prevent automatic updates.\""
        echo "            apt-mark hold \"\$version\" >> /dev/null 2>&1"
        echo "        else"
        echo "            check_and_unblock_kernel \$version"
        echo "        fi"
        echo "    done"
        echo "}"

        echo ""
        # Обработка аргументов командной строки для скрипта kernel-check
        echo "case \$1 in"
        echo "    --hold)"
        echo "        hold=true"
        echo "        ;;"
        echo ""
        echo "    --unhold)"
        echo "        unhold=true"
        echo "        ;;"
        echo ""
        echo "    *)"
        echo "        logger \"Unknown / Invalid option \$1\""
        echo "        exit 1"
        echo "        ;;"
        echo "esac"
        echo ""
        echo "set_supported_kernel_version"
        echo ""
        echo "if [[ \$hold ]]; then"
        echo "    check_and_block_kernel"
        echo "elif [[ \$unhold ]]; then"
        echo "    check_and_unblock_kernel"
        echo "fi"
    } >> /usr/bin/kernel-check

    # Устанавливаем права на выполнение для скрипта проверки ядра
    chmod 755 /usr/bin/kernel-check

# -----------------------------------------------------------------------------------
# Добавляем хук в APT: запускать скрипт kernel-check с флагом --hold после каждого обновления пакетов.
# Это нужно, чтобы автоматически блокировать неподдерживаемые версии ядра и не допустить поломки FreePBX
# -----------------------------------------------------------------------------------
if [ -e "/etc/apt/apt.conf.d/05checkkernel" ]; then
    rm -f /etc/apt/apt.conf.d/05checkkernel
fi
echo "APT::Update::Post-Invoke {\"/usr/bin/kernel-check --hold\"}" >> /etc/apt/apt.conf.d/05checkkernel
chmod 644 /etc/apt/apt.conf.d/05checkkernel
}

# -----------------------------------------------------------------------------------
# Функция обновления подписей модулей FreePBX через fwconsole
# -----------------------------------------------------------------------------------
refresh_signatures() {
  fwconsole ma refreshsignatures >> "$log"
}

# -----------------------------------------------------------------------------------
# Функция проверки статуса важных системных служб (fail2ban, iptables, apache2)
# -----------------------------------------------------------------------------------
check_services() {
    # Список служб, которые нужно проверить
    services=("fail2ban" "iptables")
    for service in "${services[@]}"; do
        # Получаем статус службы через systemctl
        service_status=$(systemctl is-active "$service")
        # Если служба не активна — выводим предупреждение
        if [[ "$service_status" != "active" ]]; then
            message "Service $service is not active. Please ensure it is running."
        fi
    done

    # Проверяем статус Apache2
    apache2_status=$(systemctl is-active apache2)
    if [[ "$apache2_status" == "active" ]]; then
        # Проверяем, действительно ли Apache2 слушает порт 80
        apache_process=$(netstat -anp | awk '$4 ~ /:80$/ {sub(/.*\//,"",$7); print $7}')
        if [ "$apache_process" == "apache2" ]; then
            message "Apache2 service is running on port 80."
        else
            message "Apache2 is not running in port 80."
        fi
    else
        message "The Apache2 service is not active. Please activate the service"
    fi
}

# -----------------------------------------------------------------------------------
# Функция проверки версии PHP на соответствие требованиям FreePBX (должна быть 8.2.x)
# -----------------------------------------------------------------------------------
check_php_version() {
    # Получаем версию PHP из вывода команды php -v
    php_version=$(php -v | grep built: | awk '{print $2}')
    # Сравниваем первые 3 символа версии с «8.2»
    if [[ "${php_version:0:3}" == "8.2" ]]; then
        message "Installed PHP version $php_version is compatible with FreePBX."
    else
        message "Installed PHP version  $php_version is not compatible with FreePBX. Please install PHP version '8.2.x'"
    fi

    # Проверяем версию PHP‑модуля, загруженного в Apache (должен быть php8.2)
    php_module_version=$(a2query -m | grep php | awk '{print $1}')

    if [[ "$php_module_version" == "php8.2" ]]; then
       log "The PHP module version $php_module_version is compatible with FreePBX. Proceeding with the script."
    else
       log "The installed PHP module version $php_module_version is not compatible with FreePBX. Please install PHP version '8.2'."
       exit 1
    fi
}

# -----------------------------------------------------------------------------------
# Функция проверки статуса модулей FreePBX: все ли модули включены
# -----------------------------------------------------------------------------------
verify_module_status() {
    # Получаем список модулей, исключая строки-заголовки и служебные строки
    modules_list=$(fwconsole ma list | grep -Ewv "Enabled|----|Module|No repos")
    if [ -z "$modules_list" ]; then
        message "All Modules are Enabled."
    else
        message "List of modules which are not Enabled:"
        message "$modules_list"
    fi
}

# -----------------------------------------------------------------------------------
# Функция проверки назначенных портов для сервисов FreePBX
# сравнивает ожидаемые порты с реально назначенными в конфигурации
# -----------------------------------------------------------------------------------
inspect_network_ports() {
    # Массив пар «порт — сервис»: чётные элементы — порты, нечётные — названия сервисов
    local ports_services=(
        82 restapps
        83 restapi
        81 ucp
        80 acp
        84 hpro
        "" leport
        "" sslrestapps
        "" sslrestapi
        "" sslucp
        "" sslacp
        "" sslhpro
        "" sslsngphone
    )

    # Проходим по массиву с шагом 2: берём порт и соответствующий сервис
    for (( i=0; i<${#ports_services[@]}; i+=2 )); do
        port="${ports_services[i]}"
        service="${ports_services[i+1]}"
        # Получаем реально назначенный порт для сервиса через fwconsole sa ports
        port_set=$(fwconsole sa ports | grep "$service" | cut -d'|' -f 2 | tr -d '[:space:]')

        # Сравниваем ожидаемый и реальный порт
        if [ "$port_set" == "$port" ]; then
            message "$service module is assigned to its default port."
        else
            message "$service module is expected to have port $port assigned instead of $port_set"
        fi
    done
}

# -----------------------------------------------------------------------------------
# Функция проверки состояния процессов, запущенных через PM2 (есть ли оффлайн‑процессы)
# -----------------------------------------------------------------------------------
inspect_running_processes() {
    processes=$(fwconsole pm2 --list |  grep -Ewv "online|----|Process")
    if [ -z "$processes" ]; then
        message "No Offline Processes found."
    else
        message "List of Offline processes:"
        message "$processes"
    fi
}

# -----------------------------------------------------------------------------------
# Основная функция проверки состояния FreePBX и связанных компонентов
# -----------------------------------------------------------------------------------
check_freepbx() {
     # Проверяем, установлен ли пакет freepbx
    if ! dpkg -l | grep -q 'freepbx'; then
        message "FreePBX is not installed. Please install FreePBX to proceed."
    else
        # Если установлен — проверяем статус модулей
        verify_module_status
	# Если не включён режим «только открытый исходный код», проверяем порты
	if [ ! "$opensourceonly" ] ; then
        	inspect_network_ports
	fi
        # Проверяем состояние процессов PM2
        inspect_running_processes
        # Выводим список заданий FreePBX
        inspect_job_status=$(fwconsole job --list)
        message "Job list : $inspect_job_status"
    fi
}

# -----------------------------------------------------------------------------------
# Функция проверки версии модуля Digium Phones (требуется версия 21.0_3.6.8 или выше)
# -----------------------------------------------------------------------------------
check_digium_phones_version() {
    installed_version=$(asterisk -rx 'digium_phones show version' | awk '/Version/{print $NF}' 2>/dev/null)
    if [[ -n "$installed_version" ]]; then
        required_version="21.0_3.6.8"
        # Заменяем подчёркивания на точки для корректного сравнения версий
        present_version=$(echo "$installed_version" | sed 's/_/./g')
        required_version=$(echo "$required_version" | sed 's/_/./g')
        # Сравниваем версии: если текущая меньше требуемой — сообщаем, что доступна более новая версия
        if dpkg --compare-versions "$present_version" "lt" "$required_version"; then
            message "A newer version of Digium Phones module is available."
        else
            message "Installed Digium Phones module version: ($installed_version)"
        fi
    else
        message "Failed to check Digium Phones module version."
    fi
}

# -----------------------------------------------------------------------------------
# Функция проверки установки и версии Asterisk, а также загрузки модуля res_digium_phone.so
# -----------------------------------------------------------------------------------
check_asterisk() {
    if ! dpkg -l | grep -q 'asterisk'; then
        message "Asterisk is not installed. Please install Asterisk to proceed."
    else
        # Выводим версию Asterisk
        check_asterisk_version=$(asterisk -V)
        message "$check_asterisk_version"
	# Проверяем, загружен ли модуль res_digium_phone.so (модуль Digium Phones)
	if asterisk -rx "module show" | grep -q "res_digium_phone.so"; then
            check_digium_phones_version
        else
            message "Digium Phones module is not loaded. Please make sure it is installed and loaded correctly."
        fi
    fi
}

# -----------------------------------------------------------------------------------
# Функция блокировки (hold) определённых пакетов, чтобы APT не обновлял их автоматически
# -----------------------------------------------------------------------------------
hold_packages() {
    # Список пакетов, которые нужно заблокировать
    local packages=("sangoma-pbx17" "nodejs" "node-*")
    # Если не установлен флаг nofpbx, добавляем freepbx17 в список блокируемых пакетов
    if [ ! "$nofpbx" ] ; then
        packages+=("freepbx17")
    fi

    # Проходим по каждому пакету и ставим его на hold
    for pkg in "${packages[@]}"; do
        apt-mark hold "$pkg" >> "$log"
    done
}

#####################################################################################
#     Начало установки
#####################################################################################

# -----------------------------------------------------------------------------------
# Переменные
# -----------------------------------------------------------------------------------
MIRROR_PRIO=600                           # Приоритет зеркала (используется в логике скрипта)
host=$(hostname)                          # Получаем имя хоста системы
kernel=$(uname -a)                        # Получаем полную строку информации о ядре системы
fqdn="$(hostname -f)" || true             # Получаем полное доменное имя (FQDN). 
                                          # Если команда не сработает — переменная останется пустой (|| true защищает от ошибки)

# -----------------------------------------------------------------------------------
# Устанавливаем утилиту wget, которая нужна для проверки версии скриптов/компонентов
# -----------------------------------------------------------------------------------
pkg_install wget

# -----------------------------------------------------------------------------------
# Проверка необходимости проверки версии скрипта
# -----------------------------------------------------------------------------------
if [[ $skipversion ]]; then
    message "Skipping version check..."
else
    # Если флаг --skipversion не передан, выполняем проверку версии
    message "Performing version check..."
    check_version
fi

# -----------------------------------------------------------------------------------
# Проверяем, запущен ли скрипт внутри контейнера (например, Docker/LXC)
# -----------------------------------------------------------------------------------
if systemd-detect-virt --container &> /dev/null; then
	message "Running in a Container. Skipping Chrony installation."
	# Устанавливаем флаг, чтобы позже не пытаться ставить chrony
	nochrony=true
fi

# -----------------------------------------------------------------------------------
# Определяем архитектуру системы через dpkg
# -----------------------------------------------------------------------------------
ARCH=$(dpkg --print-architecture)
# FreePBX 17 можно устанавливать только на 64‑битные системы (amd64)
if [ "$ARCH" != "amd64" ]; then
    message "FreePBX 17 installation can only be made on a 64-bit (amd64) system!"
    message "Current System's Architecture: $ARCH"
    exit 1
fi

# -----------------------------------------------------------------------------------
# Проверяем, корректно ли задано полное доменное имя (FQDN)
# -----------------------------------------------------------------------------------
if [ -z "$fqdn" ]; then
    echo "Fully qualified domain name (FQDN) is not set correctly."
    echo "Please set the FQDN for this system and re-run the script."
    echo "To set the FQDN, update the /etc/hostname and /etc/hosts files."
    exit 1
fi

# -----------------------------------------------------------------------------------
# Гарантируем, что скрипт не запущен повторно: проверяем наличие PID‑файла
# -----------------------------------------------------------------------------------
pidfile='/var/run/freepbx17_installer.pid'

if [ -f "$pidfile" ]; then
	old_pid=$(cat "$pidfile")
	# Проверяем, существует ли процесс с этим PID
	if ps -p "$old_pid" > /dev/null; then
		message "FreePBX 17 installation process is already going on (PID=$old_pid), hence not starting new process"
		exit 1
	else
		# Если процесс уже завершился, а файл остался (зависший PID‑файл) — удаляем его
		log "Removing stale PID file"
		rm -f "${pidfile}"
	fi
fi
# Записываем текущий PID процесса в PID‑файл
echo "$$" > "$pidfile"

# -----------------------------------------------------------------------------------
# Шаг 1 - начало установки. 
# Устанавливаем шаг для вывода в лог и прогресс‑бар.
# Настраиваем обработку ошибок
# -----------------------------------------------------------------------------------
setCurrentStep "Starting installation."

# Настраиваем обработку ошибок: при любой ошибке вызываем errorHandler с номером строки, кодом ошибки и командой
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
# При выходе из скрипта (нормально или с ошибкой) вызываем terminate для корректной очистки
trap "terminate" EXIT

# -----------------------------------------------------------------------------------
# Фиксируем время начала установки
# -----------------------------------------------------------------------------------
start=$(date +%s)
message "  Starting FreePBX 17 installation process for $host $kernel"
message "  Please refer to the $log to know the process..."
log "  Executing script v$SCRIPTVER ..."

# -----------------------------------------------------------------------------------
# Шаг 2 - Проверка правильности установки (Зависимости и репозитории). 
# -----------------------------------------------------------------------------------
setCurrentStep "Making sure installation is sane"

# Исправляем возможные проблемы с зависимостями в системе
apt-get -y --fix-broken install >> "$log"
# Удаляем неиспользуемые зависимости
apt-get autoremove -y >> "$log"

# Проверяем, есть ли в sources.list строка с CD‑ROM репозиторием
if grep -q "^deb cdrom" /etc/apt/sources.list; then
  # Если есть — комментируем эту строку, чтобы APT не пытался читать с CD
  sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list
  message "Commented out CD-ROM repository in sources.list"
fi

# Обновляем списки пакетов из репозиториев
apt-get update >> "$log"

# -----------------------------------------------------------------------------------
# Шаг 3 - Настройка конфигурации по-умолчанию (Iptables, Postfix, Gnupg)
# Устанавливаем значения по-умолчанию для интерактивных вопросов пакетов,
# чтобы установка шла в автоматическом режиме без запросов пользователю
# -----------------------------------------------------------------------------------
setCurrentStep "Setting up default configuration"

debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF

# Указываем mailname для postfix как FQDN системы
echo "postfix postfix/mailname string ${fqdn}" | debconf-set-selections
# Указываем тип почтовой конфигурации как «Internet Site»
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

# Устанавливаем gnupg — нужен для работы с GPG‑ключами репозиториев
pkg_install gnupg

# -----------------------------------------------------------------------------------
# Шаг 4 - Настройка репозиториев.
# Настраиваем репозитории для установки FreePBX и зависимостей
# -----------------------------------------------------------------------------------
setCurrentStep "Setting up repositories"

setup_repositories

# Определяем последнюю поддерживаемую версию ядра для DAHDI из доступных пакетов в репозитории
lat_dahdi_supp_ver=$(apt-cache search dahdi | grep -E "^dahdi-linux-kmod-[0-9]" | awk '{print $1}' | awk -F'-' '{print $4"-"$5}' | sort -n | tail -1)
# Получаем текущую версию ядра системы (только основную часть, без суффикса сборки)
kernel_version=$(uname -r | cut -d'-' -f1-2)

message " You are installing FreePBX 17 on kernel $kernel_version."
message " Please note that if you have plan to use DAHDI then:"
message " Ensure that you either choose DAHDI option so script will configure DAHDI"
message "                                  OR"
message " Ensure you are running a DAHDI supported Kernel. Current latest supported kernel version is $lat_dahdi_supp_ver."

# Если пользователь явно выбрал установку DAHDI — проверяем совместимость ядра
if [ "$dahdi" ]; then
    setCurrentStep "Making sure we allow only proper kernel upgrade and version installation"
    check_kernel_compatibility "$kernel_version"
fi

# Ещё раз обновляем списки пакетов после добавления новых репозиториев
setCurrentStep "Updating repository"
apt-get update >> "$log"

# Сохраняем вывод apt-cache policy в лог — это полезно для диагностики проблем с репозиториями
apt-cache policy  >> "$log"

# Блокируем автоматический запуск служб tftp и chrony, потому что сначала нужно настроить их конфиги
systemctl mask tftpd-hpa.service
if [ "$nochrony" != true ]; then
	systemctl mask chrony.service
fi

# -----------------------------------------------------------------------------------
# Шаг 5 - Установка необходимых зависимых пакетов для FreePBX 17
# -----------------------------------------------------------------------------------
setCurrentStep "Installing required packages"

# -----------------------------------------------------------------------------------
# Список пакетов для продуктовой (production) установки — базовые и прикладные компоненты
# -----------------------------------------------------------------------------------
DEPPRODPKGS=(
	"redis-server"                  # Redis — база данных для кэширования и очередей
	"ghostscript"                   # Ghostscript — для работы с PDF и печатью
	"libtiff-tools"                 # Утилиты для работы с TIFF‑изображениями
	"iptables-persistent"           # Сохранение правил iptables после перезагрузки
	"net-tools"                     # Классические сетевые утилиты (ifconfig, netstat и др.)
	"rsyslog"                       # Системный логгер (сбор и маршрутизация логов)
	"libavahi-client3"              # Клиент Avahi для обнаружения сервисов в локальной сети (mDNS)
	"nmap"                          # Сканер сети (диагностика и аудит)
	"apache2"                       # Веб‑сервер для FreePBX и модулей
	"zip"                           # Утилита для работы с ZIP‑архивами
	"incron"                        # Аналог cron, но реагирует на события файловой системы
	"wget"                          # Утилита для скачивания файлов по HTTP/FTP
	"vim"                           # Текстовый редактор
	"openssh-server"                # SSH‑сервер для удалённого доступа
	"rsync"                         # Утилита синхронизации файлов
	"mariadb-server"                # СУБД MariaDB (база данных FreePBX)
	"mariadb-client"                # Клиент для работы с MariaDB
	"bison"                         # Генератор парсеров (нужен для сборки некоторых модулей)
	"flex"                          # Генератор лексических анализаторов
	"flite"                         # Синтезатор речи (TTS)
	"php${PHPVERSION}"              # Основной PHP нужной версии
	"php${PHPVERSION}-curl"         # PHP‑модуль для работы с HTTP‑запросами
	"php${PHPVERSION}-zip"          # PHP‑модуль для ZIP
	"php${PHPVERSION}-redis"       # PHP‑модуль для Redis
	"php${PHPVERSION}-cli"          # CLI‑версия PHP
	"php${PHPVERSION}-common"       # Общие файлы PHP
	"php${PHPVERSION}-mysql"        # PHP‑модуль для MySQL/MariaDB
	"php${PHPVERSION}-gd"           # PHP‑модуль для работы с графикой
	"php${PHPVERSION}-mbstring"     # PHP‑модуль для работы с многобайтовыми строками
	"php${PHPVERSION}-intl"         # PHP‑модуль для интернационализации
	"php${PHPVERSION}-xml"          # PHP‑модуль для XML
	"php${PHPVERSION}-bz2"          # PHP‑модуль для BZip2
	"php${PHPVERSION}-ldap"         # PHP‑модуль для LDAP
	"php${PHPVERSION}-sqlite3"      # PHP‑модуль для SQLite
	"php${PHPVERSION}-bcmath"       # PHP‑модуль для произвольной точности вычислений
	"php${PHPVERSION}-soap"         # PHP‑модуль для SOAP
	"php${PHPVERSION}-ssh2"         # PHP‑модуль для SSH2
	"php-pear"                      # PEAR — менеджер пакетов для PHP
	"curl"                          # CLI‑утилита для HTTP‑запросов
	"sox"                           # Утилита для обработки аудио
	"mpg123"                        # Плеер/конвертер MP3
	"sqlite3"                       # CLI‑интерфейс к SQLite
	"git"                           # Система контроля версий
	"uuid"                          # Утилиты для генерации UUID
	"odbc-mariadb"                  # ODBC‑драйвер для MariaDB
	"sudo"                          # Выполнение команд от имени root
	"subversion"                    # Система контроля версий SVN
	"unixodbc"                      # Базовая библиотека ODBC
	"nodejs"                        # Среда выполнения Node.js
	"npm"                           # Менеджер пакетов для Node.js
	"ipset"                         # Работа с наборами IP‑адресов (для iptables)
	"iptables"                      # Межсетевой экран
	"fail2ban"                      # Защита от брутфорс‑атак
	"htop"                          # Продвинутый просмотрщик процессов
	"postfix"                       # Почтовый сервер
	"tcpdump"                       # Сниффер сетевого трафика
	"sngrep"                        # Утилита для анализа SIP‑трафика
	"tftpd-hpa"                     # TFTP‑сервер (часто нужен для загрузки прошивок телефонов)
	"xinetd"                        # Суперсервер для управления сетевыми демонами
	"lame"                          # Кодировщик MP3
	"haproxy"                       # Балансировщик нагрузки и прокси
	"screen"                        # Мультиплексор терминала (для длительных сеансов)
	"easy-rsa"                      # Утилиты для создания PKI (SSL‑сертификаты)
	"openvpn"                       # VPN‑сервер/клиент
	"sysstat"                       # Набор утилит для мониторинга системы (iostat, sar и т.д.)
	"apt-transport-https"           # Поддержка HTTPS в APT
	"lsb-release"                   # Утилита для определения версии дистрибутива
	"ca-certificates"                # Корневые сертификаты для HTTPS
 	"cron"                          # Планировщик задач
 	"python3-mysqldb"               # Python‑модуль для доступа к MySQL
 	"at"                            # Планировщик одноразовых задач
 	"avahi-daemon"                  # Демон Avahi (обнаружение сервисов)
 	"avahi-utils"                   # Утилиты Avahi
	"libnss-mdns"                   # Поддержка разрешения имён через mDNS
	"mailutils"                     # Утилиты для работы с почтой
	# Asterisk package
	"liburiparser1"                 # Библиотека для парсинга URI (нужна Asterisk)
	# ffmpeg package
	"libavdevice59"                 # Библиотека FFmpeg для захвата устройств
	# System Admin module
	"python3-mysqldb"               # Дублирование: Python‑модуль для MySQL (для модуля администрирования)
	"python-is-python3"             # Симлинк python → python3 (для совместимости)
	# User Control Panel module
	"pkgconf"                       # Утилита pkg-config (поиск библиотек и их флагов)
	"libicu-dev"                    # Библиотека ICU (Unicode и глобализация)
	"libsrtp2-1"                    # Библиотека SRTP (шифрование RTP)
	"libspandsp2"                   # Библиотека DSP‑функций (тональные сигналы, эхоподавление и т.п.)
	"libncurses5"                    # Библиотека для текстовых интерфейсов
	"autoconf"                      # Генератор скриптов конфигурации для сборки ПО
	"libical3"                      # Библиотека для работы с календарём (iCalendar)
	"libneon27"                     # Библиотека для WebDAV/HTTP
	"libsnmp40"                     # Библиотека SNMP
	"libtonezone"                   # Модуль генерации тональных сигналов (Asterisk)
	"libbluetooth3"                 # Библиотека Bluetooth
	"libunbound8"                   # Рекурсивный DNS‑резолвер Unbound
	"libsybdb5"                     # Клиент Sybase
	"libspeexdsp1"                  # Библиотека Speex DSP (кодек и обработка речи)
	"libiksemel3"                   # Библиотека для XMPP
	"libresample1"                   # Библиотека ресемплинга аудио
	"libgmime-3.0-0"                # Библиотека для MIME‑сообщений
	"libc-client2007e"              # Библиотека C‑Client (IMAP/POP3)
	"imagemagick"                   # Утилиты для обработки изображений
)

# -----------------------------------------------------------------------------------
# Список пакетов для разработки (dev) — заголовочные файлы и инструменты сборки
# -----------------------------------------------------------------------------------
DEPDEVPKGS=(
	"libsnmp-dev"                   # Заголовочные файлы SNMP
	"libtonezone-dev"               # Заголовочные файлы tonezone
	"libpq-dev"                     # Заголовочные файлы PostgreSQL (если используется)
	"liblua5.2-dev"                  # Заголовочные файлы Lua
	"libpri-dev"                     # Заголовочные файлы PRI (ISDN)
	"libbluetooth-dev"              # Заголовочные файлы Bluetooth
	"libunbound-dev"                # Заголовочные файлы Unbound
	"libspeexdsp-dev"               # Заголовочные файлы Speex DSP
	"libiksemel-dev"                # Заголовочные файлы Iksemel (XMPP)
	"libresample1-dev"              # Заголовочные файлы resample
	"libgmime-3.0-dev"              # Заголовочные файлы GMime
	"libc-client2007e-dev"          # Заголовочные файлы C‑Client
	"libncurses-dev"                # Заголовочные файлы ncurses
	"libssl-dev"                    # Заголовочные файлы OpenSSL
	"libxml2-dev"                   # Заголовочные файлы XML2
	"libnewt-dev"                   # Заголовочные файлы Newt (текстовые UI)
	"libsqlite3-dev"                # Заголовочные файлы SQLite
	"unixodbc-dev"                  # Заголовочные файлы ODBC
	"uuid-dev"                      # Заголовочные файлы UUID
	"libasound2-dev"                # Заголовочные файлы ALSA (звук)
	"libogg-dev"                    # Заголовочные файлы Ogg
	"libvorbis-dev"                 # Заголовочные файлы Vorbis
	"libcurl4-openssl-dev"          # Заголовочные файлы cURL с OpenSSL
	"libical-dev"                   # Заголовочные файлы iCalendar
	"libneon27-dev"                 # Заголовочные файлы Neon (WebDAV/HTTP)
	"libsrtp2-dev"                  # Заголовочные файлы SRTP
	"libspandsp-dev"                # Заголовочные файлы SpanDSP
	"libjansson-dev"                # Заголовочные файлы JSON (Jansson)
	"liburiparser-dev"              # Заголовочные файлы uriparser
	"libavdevice-dev"               # Заголовочные файлы FFmpeg (устройства)
	"python-dev-is-python3"         # Заголовочные файлы Python (с симлинком на python3)
	"default-libmysqlclient-dev"    # Заголовочные файлы MySQL‑клиента
	"dpkg-dev"                      # Инструменты для сборки .deb‑пакетов
	"build-essential"               # Базовый набор инструментов для компиляции (gcc, make и т.д.)
	"automake"                      # Генератор Makefile
	"autoconf"                      # Повторно: генератор скриптов конфигурации
	"libtool-bin"                   # Утилиты libtool
	"bison"                         # Повторно: генератор парсеров
	"flex"                          # Повторно: генератор лексических анализаторов
)

# Если флаг $dev установлен — подключаем пакеты для разработки, иначе только продуктовые
if [ $dev ]; then
	DEPPKGS=("${DEPPRODPKGS[@]}" "${DEPDEVPKGS[@]}")
else
	DEPPKGS=("${DEPPRODPKGS[@]}")
fi

# Если не работаем в контейнере (nochrony не установлен), добавляем chrony для синхронизации времени
if [ "$nochrony" != true ]; then
	DEPPKGS+=("chrony")
fi

# Последовательно устанавливаем все пакеты из массива DEPPKGS
for i in "${!DEPPKGS[@]}"; do
	pkg_install "${DEPPKGS[$i]}"
done

# -----------------------------------------------------------------------------------
# Настройка Postfix: 
# ограничиваем прослушивание только localhost (127.0.0.1),
# это снижает риск раскрытия почтового сервера в публичной сети
# -----------------------------------------------------------------------------------
if  dpkg -l | grep -q 'postfix'; then
    warning_message="# WARNING: Changing the inet_interfaces to an IP other than 127.0.0.1 may expose Postfix to external network connections.\n# Only modify this setting if you understand the implications and have specific network requirements."

    # Если предупреждение ещё не добавлено в main.cf — добавляем его перед строкой inet_interfaces
    if ! grep -q "WARNING: Changing the inet_interfaces" /etc/postfix/main.cf; then
        sed -i "/^inet_interfaces\s*=/i $warning_message" /etc/postfix/main.cf
    fi

    # Принудительно устанавливаем inet_interfaces = 127.0.0.1
    sed -i "s/^inet_interfaces\s*=.*/inet_interfaces = 127.0.0.1/" /etc/postfix/main.cf

    # Перезапускаем Postfix, чтобы применить изменения
    systemctl restart postfix
fi

# -----------------------------------------------------------------------------------
# Подготовка директории для EasyRSA (PKI для OpenVPN)
# -----------------------------------------------------------------------------------
# Если папка /etc/openvpn/easyrsa3 ещё не создана — создаём её через утилиту make-cadir
if [ ! -d "/etc/openvpn/easyrsa3" ]; then
	make-cadir /etc/openvpn/easyrsa3
fi

# Удаляем файлы vars и /pki/vars — они будут заново сгенерированы модулем sysadmin позже
rm -f /etc/openvpn/easyrsa3/pki/vars || true
rm -f /etc/openvpn/easyrsa3/vars

# -----------------------------------------------------------------------------------
# Установка поддержки карт DAHDI, если при запуске скрипта была указана опция --dahdi
# -----------------------------------------------------------------------------------
if [ "$dahdi" ]; then
    message "Installing DAHDI card support..."
    # Список пакетов, необходимых для работы DAHDI и связанных технологий (PRI, Wanpipe)
    DAHDIPKGS=("asterisk${ASTVERSION}-dahdi"
           "dahdi-firmware"                # Прошивки для DAHDI‑карт
           "dahdi-linux"                  # Ядро DAHDI (основные модули)
           "dahdi-linux-devel"             # Заголовочные файлы для сборки модулей DAHDI
           "dahdi-tools"                   # Утилиты для настройки и диагностики DAHDI
           "libpri"                        # Библиотека для работы с PRI (ISDN)
           "libpri-devel"                  # Заголовочные файлы libpri
           "wanpipe"                       # Драйверы и утилиты для карт Sangoma (Wanpipe)
           "wanpipe-devel"                 # Заголовочные файлы Wanpipe
           "dahdi-linux-kmod-${kernel_version}"  # Модуль ядра DAHDI под текущую версию ядра
           "kmod-wanpipe-${kernel_version}"      # Модуль ядра Wanpipe под текущую версию ядра
	)

        # Последовательно устанавливаем все пакеты из списка DAHDIPKGS
        for i in "${!DAHDIPKGS[@]}"; do
                pkg_install "${DAHDIPKGS[$i]}"
        done
fi

# Установка кодека libfdk‑aac2 (высококачественный AAC)
if [ "$noaac" ] ; then
	# Если указана опция --noaac — пропускаем установку
	message "Skipping libfdk-aac2 installation due to noaac option"
else
	# Иначе устанавливаем пакет
	pkg_install libfdk-aac2
fi

# -----------------------------------------------------------------------------------
# Шаг 6 - Удаляем ненужных пакетов, чтобы уменьшить размер системы и избежать конфликтов
# -----------------------------------------------------------------------------------
setCurrentStep "Removing unnecessary packages"
apt-get autoremove -y >> "$log"

# -----------------------------------------------------------------------------------
# Вычисляем время выполнения этапа установки пакетов
# -----------------------------------------------------------------------------------
execution_time="$(($(date +%s) - start))"
message "Execution time to install all the dependent packages : $execution_time s"

# -----------------------------------------------------------------------------------
# Шаг 7 - Подготовка директорий и настройка конфигурации Asterisk
# -----------------------------------------------------------------------------------
setCurrentStep "Setting up folders and asterisk config"

# Проверяем, существует ли группа asterisk
groupExists="$(getent group asterisk || echo '')"
if [ "${groupExists}" = "" ]; then
	# Если нет — создаём системную группу asterisk
	groupadd -r asterisk
fi

# Проверяем, существует ли пользователь asterisk
userExists="$(getent passwd asterisk || echo '')"
if [ "${userExists}" = "" ]; then
	# Если нет — создаём системного пользователя asterisk:
	# - без домашнего каталога по умолчанию (-M), но с явно заданным /home/asterisk
	# - с оболочкой /bin/bash
	# - в группе asterisk
	useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk
fi

# Примечание: строка добавления asterisk в sudoers закомментирована — обычно не требуется
# echo "%asterisk ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Создаём директорию /tftpboot — она нужна для загрузки прошивок телефонов по TFTP
mkdir -p /tftpboot
chown -R asterisk:asterisk /tftpboot

# Меняем путь TFTP‑сервера на /tftpboot в конфигурации tftpd‑hpa
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa

# Если IPv6 недоступен (нет файла /proc/net/if_inet6), добавляем флаги для работы только по IPv4
# Это предотвращает ошибки запуска сервисов в сетях без IPv6
if [ ! -f /proc/net/if_inet6 ]; then
	# Добавляем флаг --ipv4 для tftpd‑hpa
	sed -i -e "s|^TFTP_OPTIONS=\"--secure\"$|TFTP_OPTIONS=\"--secure --ipv4\"|" /etc/default/tftpd-hpa
	# Для chrony добавляем флаг -4 (только IPv4), если chrony не отключён
	if [ "$nochrony" != true ]; then
		sed -i -e "s|^DAEMON_OPTS=\"-F 1\"$|DAEMON_OPTS=\"-F 1 -4\"|" /etc/default/chrony
	fi
fi

# Снимаем маску и запускаем службы tftp и chrony
systemctl unmask tftpd-hpa.service
systemctl start tftpd-hpa.service
if [ "$nochrony" != true ]; then
	systemctl unmask chrony.service
	systemctl start chrony.service
fi

# Создаём директорию для звуковых файлов Asterisk
mkdir -p /var/lib/asterisk/sounds
chown -R asterisk:asterisk /var/lib/asterisk

# Адаптируем конфигурацию OpenSSL для совместимости с Katana (модуль FreePBX)
# Заменяем строку openssl_conf = openssl_init на openssl_conf = default_conf
sed -i -e 's/^openssl_conf = openssl_init$/openssl_conf = default_conf/' /etc/ssl/openssl.cnf

# Проверяем, уже ли добавлены настройки FreePBX 17 в openssl.cnf
isSSLConfigAdapted=$(grep "FreePBX 17 changes" /etc/ssl/openssl.cnf |wc -l)
if [ "0" = "${isSSLConfigAdapted}" ]; then
	# Если нет — добавляем секцию с настройками TLS (минимальный протокол TLSv1.2 и безопасные шифры)
	cat <<EOF >> /etc/ssl/openssl.cnf
# FreePBX 17 changes - begin
[ default_conf ]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1.2
CipherString = DEFAULT:@SECLEVEL=1
# FreePBX 17 changes - end
EOF
fi

# Повышаем приоритет IPv4 над IPv6 в разрешении имён (для стабильной работы сервисов)
# Раскомментируем и устанавливаем правило precedence для IPv4‑mapped адресов
sed -i 's/^#\s*precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Настройка screen: добавляем удобный статус‑бар с информацией о хосте, дате и времени
isScreenRcAdapted=$(grep "FreePBX 17 changes" /root/.screenrc |wc -l)
if [ "0" = "${isScreenRcAdapted}" ]; then
	cat <<EOF >> /root/.screenrc
# FreePBX 17 changes - begin
hardstatus alwayslastline
hardstatus string '%{= kG}[ %{G}%H %{g}][%= %{=kw}%?%-Lw%?%{r}(%{W}%n*%f%t%?(%u)%?%{r})%{w}%?%+Lw%?%?%= %{g}][%{B}%Y-%m-%d %{W}%c %{g}]'
# FreePBX 17 changes - end
EOF
fi

# -----------------------------------------------------------------------------------
# Настройка Vim: включаем поддержку мыши для копирования/вставки (удобно при работе в терминале)
# EOF - запись текста в конфигурационный файл
# -----------------------------------------------------------------------------------
isVimRcAdapted=$(grep "FreePBX 17 changes" /etc/vim/vimrc.local |wc -l)
if [ "0" = "${isVimRcAdapted}" ]; then
	cat <<EOF >> /etc/vim/vimrc.local
" FreePBX 17 changes - begin
" This file loads the default vim options at the beginning and prevents
" that they are being loaded again later. All other options that will be set,
" are added, or overwrite the default settings. Add as many options as you
" whish at the end of this file.

" Load the defaults
source \$VIMRUNTIME/defaults.vim

" Prevent the defaults from being loaded again later, if the user doesn't
" have a local vimrc (~/.vimrc)
let skip_defaults_vim = 1


" Set more options (overwrites settings from /usr/share/vim/vim80/defaults.vim)
" Add as many options as you whish

" Set the mouse mode to 'r'
if has('mouse')
  set mouse=r
endif
" FreePBX 17 changes - end
EOF
fi

# -----------------------------------------------------------------------------------
# Настройка APT: запрещаем перезаписывать существующие конфигурационные файлы при установке/обновлении пакетов
# Используем опции --force-confdef (использовать значение по умолчанию) и --force-confold (оставить старую версию конфига)
# -----------------------------------------------------------------------------------
aptNoOverwrite=$(grep "DPkg::options { \"--force-confdef\"; \"--force-confold\"; }" /etc/apt/apt.conf.d/00freepbx |wc -l)
if [ "0" = "${aptNoOverwrite}" ]; then
        cat <<EOF >> /etc/apt/apt.conf.d/00freepbx
DPkg::options { "--force-confdef"; "--force-confold"; }
EOF
fi

# -----------------------------------------------------------------------------------
# ЗАКОММЕНТИРОВАННАЯ СТРОКА: 
# изменение владельца директории /etc/ssl на пользователя asterisk
# В текущей версии скрипта эта операция не выполняется
# -----------------------------------------------------------------------------------
# chown -R asterisk:asterisk /etc/ssl

# -----------------------------------------------------------------------------------
# Установка Asterisk
# -----------------------------------------------------------------------------------
if [ "$noast" ] ; then
	# Если указана опция --noasterisk — пропускаем установку Asterisk
	message "Skipping Asterisk installation due to noasterisk option"
else
	# TODO: требуется проверить, установлен ли уже Asterisk. Если да — удалить старую версию и установить новую.
	# Устанавливаем пакеты Asterisk нужной версии
	setCurrentStep "Installing Asterisk packages."
	install_asterisk $ASTVERSION
fi

# -----------------------------------------------------------------------------------
# Шаг 8 - Установка пакетов, необходимых для работы FreePBX
# -----------------------------------------------------------------------------------
setCurrentStep "Installing FreePBX packages"

FPBXPKGS=("sysadmin17"          # Модуль администрирования FreePBX
	   "sangoma-pbx17"          # Основной пакет PBX от Sangoma
	   "ffmpeg"                 # Утилита для обработки аудио/видео (нужна для некоторых функций FreePBX)
   )
# Последовательно устанавливаем все пакеты из списка FPBXPKGS
for i in "${!FPBXPKGS[@]}"; do
	pkg_install "${FPBXPKGS[$i]}"
done

# -----------------------------------------------------------------------------------
# Шаг 9 - Активация PHP‑модуля Freepbx (подключает конфигурацию FreePBX к PHP)
# -----------------------------------------------------------------------------------
setCurrentStep "Enabling modules."
phpenmod freepbx
# Создаём директорию для хранения сессий PHP (требуется для корректной работы веб‑интерфейса)
mkdir -p /var/lib/php/session

# -----------------------------------------------------------------------------------
# Создание базовых конфигурационных файлов Asterisk
# -----------------------------------------------------------------------------------
mkdir -p /etc/asterisk
# Создаём пустые файлы, которые будут заполняться или дополняться в процессе работы FreePBX
touch /etc/asterisk/extconfig_custom.conf              # Пользовательские настройки extconfig
touch /etc/asterisk/extensions_override_freepbx.conf    # Переопределения диалплана от FreePBX
touch /etc/asterisk/extensions_additional.conf         # Дополнительные правила диалплана
touch /etc/asterisk/extensions_custom.conf              # Пользовательский диалплан
# Назначаем владельцем всех файлов и папок в /etc/asterisk пользователя и группу asterisk
chown -R asterisk:asterisk /etc/asterisk

# -----------------------------------------------------------------------------------
# Шаг 10 - Перезапуск службы fail2ban для применения возможных новых правил
# -----------------------------------------------------------------------------------
setCurrentStep "Restarting fail2ban"
systemctl restart fail2ban  >> "$log"

# -----------------------------------------------------------------------------------
# (Опция --nofreepbx). Если указана, то пропускаем установку FreePBX 17
# -----------------------------------------------------------------------------------
if [ "$nofpbx" ] ; then
    message "Skipping FreePBX 17 installation due to nofreepbx option"
else
  # -----------------------------------------------------------------------------------
  # Шаг 11 - Установка FreePBX
  # -----------------------------------------------------------------------------------
  setCurrentStep "Installing FreePBX 17"
  # Устанавливаем ioncube‑loader для PHP 8.2 (требуется для работы проприетарных модулей FreePBX)
  pkg_install ioncube-loader-82
  # Устанавливаем основной пакет FreePBX 17
  pkg_install freepbx17

  # -----------------------------------------------------------------------------------
  # (Опция --npmmirror). Если задан NPM_MIRROR — устанавливаем переменную окружения для npm
  # Это полезно, если нужно использовать внутренний или ускоренный репозиторий npm
  # -----------------------------------------------------------------------------------
  if [ -n "$NPM_MIRROR" ] ; then
    setCurrentStep "Setting environment variable npm_config_registry=$NPM_MIRROR"
    export npm_config_registry="$NPM_MIRROR"
  fi

  # -----------------------------------------------------------------------------------
  # (Опция --opensourceonly). Если требуется только открытый исходный код  — удаляем коммерческие модули
  # -----------------------------------------------------------------------------------
  if [ "$opensourceonly" ]; then
    setCurrentStep "Removing commercial modules"
    # Находим все модули с пометкой Commercial и удаляем их
    fwconsole ma list | awk '/Commercial/ {print $2}' | xargs -t -I {} fwconsole ma -f remove {} >> "$log"
    # Удаляем модуль firewall, так как он зависит от коммерческого модуля sysadmin
    fwconsole ma -f remove firewall >> "$log" || true
  fi

  # -----------------------------------------------------------------------------------
  # (Опция --dahdi). Если включена поддержка DAHDI — устанавливаем модуль dahdiconfig 
  # и настраиваем переменные окружения для Wanpipe
  # -----------------------------------------------------------------------------------
  if [ "$dahdi" ]; then
    fwconsole ma downloadinstall dahdiconfig >> "$log"
    # Добавляем путь к Perl‑библиотекам Wanpipe в переменную PERL5LIB
    echo 'export PERL5LIB=$PERL5LIB:/etc/wanpipe/wancfg_zaptel' | sudo tee -a /root/.bashrc
  fi

  # -----------------------------------------------------------------------------------
  # Шаг 12 - Устанавливаем все локально доступные модули FreePBX (из кэша или загруженных ранее)
  # -----------------------------------------------------------------------------------
  setCurrentStep "Installing all local modules"
  fwconsole ma installlocal >> "$log"

  # -----------------------------------------------------------------------------------
  # Шаг 13 - Обновляем все модули FreePBX до последних версий
  # -----------------------------------------------------------------------------------
  setCurrentStep "Upgrading FreePBX 17 modules"
  fwconsole ma upgradeall >> "$log"

  # -----------------------------------------------------------------------------------
  # Шаг 14 - Перезагружаем конфигурацию и перезапускаем сервисы FreePBX
  # -----------------------------------------------------------------------------------
  setCurrentStep "Reloading and restarting FreePBX 17"
  fwconsole reload >> "$log"
  fwconsole restart >> "$log"

  # -----------------------------------------------------------------------------------
  # Если выбран режим «только открытый исходный код (opensourceonly)» 
  # то удаляем вспомогательные пакеты, нужные только для коммерческих модулей
  # -----------------------------------------------------------------------------------
  if [ "$opensourceonly" ]; then
    message "Uninstalling sysadmin17"
    apt-get purge -y sysadmin17 >> "$log"
    message "Uninstalling ioncube-loader-82"
    apt-get purge -y ioncube-loader-82 >> "$log"
  fi
fi

# -----------------------------------------------------------------------------------
# Шаг 15 - Завершение процесса установки: 
# обновляем список юнитов systemd
# -----------------------------------------------------------------------------------
setCurrentStep "Wrapping up the installation process"
systemctl daemon-reload >> "$log"
# Включаем автозапуск FreePBX при загрузке системы (если не была указана опция --nofreepbx)
if [ ! "$nofpbx" ] ; then
  systemctl enable freepbx >> "$log"
fi

# -----------------------------------------------------------------------------------
# Apache - удаляем index.html, включаем SSL, включаем модули, активируем сайты и т.д.
# Дополнительные настройка HTTP
# -----------------------------------------------------------------------------------
# Удаляем стандартный файл index.html из веб‑директории Apache — он не нужен для FreePBX
rm -f /var/www/html/index.html

# Включаем модуль SSL в Apache (нужен для HTTPS)
a2enmod ssl  >> "$log"

# Включаем модуль expires в Apache (для кэширования статических файлов)
a2enmod expires  >> "$log"

# Включаем модуль rewrite в Apache (требуется для маршрутизации URL в FreePBX)
a2enmod rewrite >> "$log"

# Активируем конфигурационные файлы сайта FreePBX и SSL в Apache
if [ ! "$nofpbx" ] ; then 
  a2ensite freepbx.conf >> "$log"
  a2ensite default-ssl >> "$log"
fi

# Устанавливаем максимальный размер почтового сообщения в Postfix равным 100 МБ (в байтах: 102400000)
postconf -e message_size_limit=102400000

# Отключаем вывод информации о версии PHP в HTTP‑заголовках (снижает риск раскрытия версии для злоумышленников)
sed -i 's/$^expose_php = $.*/\1Off/' /etc/php/${PHPVERSION}/apache2/php.ini

# Увеличиваем лимит переменных во входных данных (POST/GET) до 2000 (по умолчанию часто 1000, чего может не хватать для сложных форм FreePBX)
sed -i 's/;max_input_vars = 1000/max_input_vars = 2000/' /etc/php/${PHPVERSION}/apache2/php.ini

# Отключаем раскрытие информации о сервере в HTTP‑ответах (ServerTokens и ServerSignature) — это повышает безопасность
sed -i 's/$^ServerTokens $.*/\1Prod/' /etc/apache2/conf-available/security.conf
sed -i 's/$^ServerSignature $.*/\1Off/' /etc/apache2/conf-available/security.conf

# Отключаем JIT‑компиляцию в PCRE (иногда требуется для стабильности или совместимости)
sed -i 's/;pcre.jit=1/pcre.jit=0/' /etc/php/${PHPVERSION}/apache2/php.ini

# Перезапускаем Apache, чтобы применить все изменения конфигурации
systemctl restart apache2 >> "$log"

# -----------------------------------------------------------------------------------
# Шаг 16 - Блокируем обновление ключевых пакетов, чтобы избежать поломок системы при будущих обновлениях
# -----------------------------------------------------------------------------------
setCurrentStep "Holding Packages"
hold_packages

# Настраиваем logrotate: включаем добавление даты к именам файлов логов (dateext)
# Это упрощает хранение и поиск старых логов
if grep -q '^#dateext' /etc/logrotate.conf; then
   message "Setting up logrotate.conf"
   sed -i 's/^#dateext/dateext/' /etc/logrotate.conf
fi

# Настройка прав доступа: назначаем владельцем всех файлов и поддиректорий в /var/www/html пользователя и группу asterisk
# Это необходимо для корректной работы веб‑интерфейса FreePBX
chown -R asterisk:asterisk /var/www/html/

# Создание скриптов, которые будут выполнены после завершения работы APT (например, для финальной настройки зависимостей)
create_post_apt_script

# -----------------------------------------------------------------------------------
# Шаг 17 - Обновление подписей модулей FreePBX — это нужно для проверки целостности и подлинности модулей
# -----------------------------------------------------------------------------------
setCurrentStep "Refreshing modules signatures."
count=1
if [ ! "$nofpbx" ]; then
  # Пытаемся обновить подписи модулей; если команда завершается с ошибкой — запускаем её в фоне и продолжаем выполнение скрипта
  while [ $count -eq 1 ]; do
    set +e                # Временно отключаем автоматическое завершение скрипта при ошибке команды
    refresh_signatures
    exit_status=$?        # Сохраняем код возврата последней команды
    set -e                # Возвращаем строгий режим: при ошибке скрипт будет останавливаться (если не перехвачено явно)
    if [ $exit_status -eq 0 ]; then
      # Если обновление подписей прошло успешно — выходим из цикла
      break
    else
      # Если команда refresh_signatures завершилась с ошибкой:
      log "Command 'fwconsole ma refreshsignatures' failed to execute with exit status $exit_status, running as a background job"
      refresh_signatures &  # Запускаем обновление подписей в фоновом режиме
      log "Continuing the remaining script execution"
      break                 # Прерываем цикл: дальше скрипт должен идти дальше, не дожидаясь завершения фоновой задачи
    fi
  done
fi

# -----------------------------------------------------------------------------------
# Шаг 18 - Сообщаем, что установка FreePBX 17 успешно завершена
# -----------------------------------------------------------------------------------
setCurrentStep "FreePBX 17 Installation finished successfully."


#####################################################################################
#     Проверка после установки (POST INSTALL VALIDATION)
#####################################################################################
# -----------------------------------------------------------------------------------
# Команды для проверки корректности установки после её завершения
# Отключаем автоматическое прерывание скрипта при получении ненулевого кода возврата от команд
# Это нужно, чтобы скрипт не остановился на первой же ошибке проверки, а выполнил все тесты
# -----------------------------------------------------------------------------------
set +e

# -----------------------------------------------------------------------------------
# Шаг 19 - Проверка после установки
# -----------------------------------------------------------------------------------
setCurrentStep "Post-installation validation"

# Проверяем, что все необходимые службы (FreePBX, Asterisk, Apache и т.д.) запущены и работают корректно
check_services

# Проверяем версию PHP — она должна соответствовать требованиям FreePBX 17
check_php_version

# (Опция --nofreepbx). Если не была указана — выполняем дополнительную проверку самого FreePBX 
# (доступность API, основных модулей и т. п.)
if [ ! "$nofpbx" ] ; then
 check_freepbx
fi

# Проверяем состояние и работоспособность Asterisk (запущен ли, нет ли критических ошибок в логах и т.п.)
check_asterisk

# Вычисляем общее время выполнения всего скрипта установки
execution_time="$(($(date +%s) - start))"
message "Total script Execution Time: $execution_time"
message "Finished FreePBX 17 installation process for $host $kernel"
message "Join us on the FreePBX Community Forum: https://community.freepbx.org/ ";

# (Опция --nofreepbx). Если FreePBX был установлен — 
# выводим приветственное сообщение motd (Message of the Day) через fwconsole
if [ ! "$nofpbx" ] ; then
  fwconsole motd
fi
