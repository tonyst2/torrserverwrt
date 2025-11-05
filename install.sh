#!/bin/sh
# TorrServer OpenWrt/FriendlyWrt installer (auto deps + non-root service)

username="torrserver"
dirInstall="/opt/torrserver"
serviceName="torrserver"
scriptname=$(basename "$0")
architecture="arm64"      # set "auto" to detect from uname -m (aarch64->arm64, x86_64->x64, armv7l->arm, etc.)

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
colorize() { case "$1" in red) c=$RED;; green) c=$GREEN;; yellow) c=$YELLOW;; *) c="";; esac; shift; echo -e "${c}$*${NC}"; }

isRoot() { [ "$(id -u)" -eq 0 ]; }

# -------- arch / bin name ----------
detect_arch() {
    [ "$architecture" != "auto" ] && { echo "$architecture"; return; }
    m=$(uname -m)
    case "$m" in
        aarch64) echo "arm64" ;;
        armv7*|armv6*|armhf) echo "arm" ;;
        x86_64) echo "x64" ;;
        mipsel*) echo "mipsel" ;;
        mips*) echo "mips" ;;
        *) echo "arm64" ;;  # sane default
    esac
}
binName() { echo "TorrServer-linux-$(detect_arch)"; }

# -------- internet / IP ----------
need_curl() { command -v curl >/dev/null 2>&1 || { echo " Требуется curl. Установка: opkg update && opkg install curl"; exit 1; }; }
checkInternet() {
    echo " Проверяем соединение с Интернетом..."
    if ! curl -sSf https://api.github.com/ >/dev/null 2>&1; then
        echo " - Нет доступа к api.github.com (DNS/интернет?)."; exit 1
    fi
    echo " - ОК"
}
getIP() {
    if ip -4 addr show br-lan >/dev/null 2>&1; then
        ip -4 addr show br-lan | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
        return
    fi
    def_if=$(ip route | awk '/default/{print $5; exit}')
    [ -z "$def_if" ] && { echo "127.0.0.1"; return; }
    ip -4 addr show dev "$def_if" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

# -------- releases ----------
getLatestRelease() {
    curl -s https://api.github.com/repos/YouROK/TorrServer/releases/latest \
      | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}
getLatestUrl() {
    tag="$(getLatestRelease)"; [ -z "$tag" ] && tag="MatriX.136"
    echo "https://github.com/YouROK/TorrServer/releases/download/${tag}/$(binName)"
}

# -------- users / groups ----------
ensureNogroup() {
    if ! grep -q "^nogroup:" /etc/group; then
        if command -v groupadd >/dev/null 2>&1; then
            groupadd -g 65534 nogroup 2>/dev/null || groupadd nogroup 2>/dev/null
        else
            echo "nogroup:x:65534:" >> /etc/group
        fi
    fi
}
ensureUserTools() {
    if command -v useradd >/dev/null 2>&1 || command -v adduser >/dev/null 2>&1; then return 0; fi
    if command -v opkg >/dev/null 2>&1; then
        echo " Не найдены useradd/adduser. Установить shadow-utils? (shadow-useradd shadow-groupadd shadow-usermod)"
        read -p " Установить через opkg? (Y/n) " ans </dev/tty
        case "$ans" in [Nn]*) ;; *)
            opkg update && opkg install shadow-useradd shadow-groupadd shadow-usermod || \
              echo " - Не удалось установить shadow-utils; продолжим без них"
        esac
    fi
}
addUser() {
    ! isRoot && return 1
    [ "$username" = "root" ] && return 0
    [ -d "$dirInstall" ] || mkdir -p "$dirInstall"
    ensureNogroup; ensureUserTools

    if id "$username" >/dev/null 2>&1; then
        chown -R "$username:nogroup" "$dirInstall"; chmod 755 "$dirInstall"
        echo " - Пользователь $username уже существует; права обновлены"; return 0
    fi

    echo " - Добавляем пользователя $username..."
    if command -v useradd >/dev/null 2>&1; then
        useradd -r -M -d "$dirInstall" -s /bin/false -g nogroup "$username" || { echo " - useradd: ошибка"; return 1; }
    elif command -v adduser >/dev/null 2>&1; then
        adduser -D -H -h "$dirInstall" -s /bin/false -G nogroup "$username" || { echo " - adduser: ошибка"; return 1; }
    else
        next_uid=$(awk -F: 'BEGIN{max=999} {if($3>max) max=$3} END{print (max<1000?1000:max+1)}' /etc/passwd)
        echo "$username:x:${next_uid}:65534:$username:$dirInstall:/bin/false" >> /etc/passwd
        grep -q "^$username:" /etc/shadow 2>/dev/null || echo "$username:!*:0:0:99999:7:::" >> /etc/shadow
    fi
    chown -R "$username:nogroup" "$dirInstall"; chmod 755 "$dirInstall"
    echo " - Пользователь $username создан и назначен владельцем $dirInstall"
}

delUser() {
    ! isRoot && return 1
    [ "$username" = "root" ] && return 0
    if id "$username" >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then userdel "$username" 2>/dev/null || echo " - userdel: не удалён"
        elif command -v deluser >/dev/null 2>&1; then deluser "$username" 2>/dev/null || echo " - deluser: не удалён"
        else sed -i "\|^$username:|d" /etc/passwd; [ -f /etc/shadow ] && sed -i "\|^$username:|d" /etc/shadow
        fi
        echo " - Пользователь $username удалён"
    else
        echo " - Пользователь $username не найден"; return 1
    fi
}

# -------- install / update / service ----------
checkInstalled() {
    if [ -f "$dirInstall/$(binName)" ]; then echo " - TorrServer найден в $dirInstall"; return 0; fi
    echo " - TorrServer не найден"; return 1
}
writeInit() {
cat << EOF > /etc/init.d/$serviceName
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG="$dirInstall/$(binName)"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG $authOptions
    procd_set_param user "$username"
    procd_set_param group "nogroup"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
stop_service() { killall $(binName) 2>/dev/null; }
reload_service() { stop; start; }
EOF
chmod +x /etc/init.d/$serviceName
}

installTorrServer() {
    echo " Устанавливаем и настраиваем TorrServer..."
    [ -d "$dirInstall" ] || mkdir -p "$dirInstall"

    if [ -f "$dirInstall/$(binName)" ]; then
        read -p " TorrServer уже установлен. Обновить? (Y/n) " a </dev/tty
        case "$a" in [Nn]*) ;; *) UpdateVersion; return ;; esac
    fi

    url="$(getLatestUrl)"
    echo " Скачиваем: $url"
    curl -fL -o "$dirInstall/$(binName)" "$url" || { echo " - Скачивание не удалось"; exit 1; }
    chmod +x "$dirInstall/$(binName)"

    addUser || { echo " - Не удалось создать пользователя"; exit 1; }

    # порт
    read -p " Изменить порт (по умолчанию 8090)? (Y/n) " cp </dev/tty
    if [ "$cp" = "Y" ] || [ "$cp" = "y" ] || [ "$cp" = "" ]; then
        read -p " Введите порт (1..65535): " p </dev/tty
        if echo "$p" | grep -Eq '^[0-9]+$' && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then servicePort="$p"; else servicePort="8090"; fi
    else servicePort="8090"; fi

    # авторизация
    read -p " Включить авторизацию? (Y/n) " aa </dev/tty
    if [ "$aa" = "Y" ] || [ "$aa" = "y" ] || [ "$aa" = "" ]; then
        read -p " Пользователь: " isAuthUser </dev/tty
        read -p " Пароль: " isAuthPass </dev/tty
        umask 077; printf '{\n  "%s": "%s"\n}\n' "$isAuthUser" "$isAuthPass" > "$dirInstall/accs.db"
        authOptions="--port $servicePort --path $dirInstall --httpauth"
    else
        isAuthUser=""; isAuthPass=""; authOptions="--port $servicePort --path $dirInstall"
    fi

    writeInit
    /etc/init.d/$serviceName enable
    /etc/init.d/$serviceName restart

    ipaddr=$(getIP)
    echo ""
    echo " TorrServer установлен в $dirInstall"
    echo " Открой: http://$ipaddr:$servicePort"
    [ -n "$isAuthUser" ] && echo " Логин: $isAuthUser  Пароль: $isAuthPass"
    echo " Примечание: 'ffprobe not found' — не критично. Можно: opkg install ffmpeg"
}

UpdateVersion() {
    /etc/init.d/$serviceName stop 2>/dev/null
    url="$(getLatestUrl)"
    echo " Обновляем TorrServer..."
    curl -fL -o "$dirInstall/$(binName)" "$url" || { echo " - Скачивание не удалось"; exit 1; }
    chmod +x "$dirInstall/$(binName)"
    /etc/init.d/$serviceName start 2>/dev/null || /etc/init.d/$serviceName restart 2>/dev/null
    echo " - Обновлён"
}

cleanup() {
    /etc/init.d/$serviceName stop 2>/dev/null
    /etc/init.d/$serviceName disable 2>/dev/null
    rm -f "/etc/init.d/$serviceName"
    rm -rf "$dirInstall"
    delUser
}
uninstall() {
    checkInstalled
    echo ""; echo " Директория: $dirInstall"
    echo " ВНИМАНИЕ: база и настройки будут удалены!"
    read -p " Удалить? (Y/n) " d </dev/tty
    case "$d" in [Nn]*) echo " Отменено";; *) cleanup; echo " - Удалён";; esac
}
helpUsage() {
    echo "$scriptname"
    echo "  -i | --install | install   - установка последней версии"
    echo "  -u | --update  | update    - обновление до последней версии"
    echo "  -r | --remove  | remove    - удаление TorrServer"
    echo "  -h | --help    | help      - эта справка"
}

# -------- main ----------
initialCheck() { ! isRoot && { echo " Нужен root"; exit 1; }; need_curl; checkInternet; }
initialCheckFull() { initialCheck; ensureUserTools || true; }

case "$1" in
  -i|--install|install) initialCheckFull; installTorrServer; exit ;;
  -u|--update|update)   initialCheckFull; if checkInstalled; then UpdateVersion; fi; exit ;;
  -r|--remove|remove)   uninstall; exit ;;
  -h|--help|help)       helpUsage; exit ;;
  *)
    echo ""; echo "============================================================="
    echo " Скрипт установки TorrServer для OpenWrt/FriendlyWrt"
    echo "============================================================="
    echo ""; echo " Введите $scriptname -h для справки"
  ;;
esac

while true; do
  echo ""
  read -p " Установить/настроить TorrServer? (Y/n) Для удаления: D " ydn </dev/tty
  case "$ydn" in
    [Yy]*|"") initialCheckFull; installTorrServer; break ;;
    [DdUu]* ) uninstall; break ;;
    [Nn]* ) break ;;
    * ) echo " Введите Y/n или D" ;;
  esac
done

echo " Готово."
