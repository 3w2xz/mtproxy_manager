#!/usr/bin/env bash
# mtmanager — TUI for managing multiple MTProto proxies (mtbuddy instances)
# Save as /usr/local/bin/mtmanager and chmod +x

set -euo pipefail

# --- Настройки ---
INSTANCE_DIR="/etc/mtbuddy/instances"       # каталог с конфигами (порт-нейминг)
SERVICE_PREFIX="mtproto"                    # префикс systemd-сервисов (mtproto-<port>.service)
MTBUDDY="/usr/local/bin/mtbuddy"            # основной бинарник mtbuddy
DIALOG_CMD="dialog"                         # диалоговая утилита (нужно установить)

# Убедимся что запуск от root
[ "$(id -u)" -eq 0 ] || { echo "Требуются права root. Используйте sudo."; exit 1; }

# Проверим наличие обязательных утилит и при необходимости установим
install_dependencies() {
    local missing=()
    for cmd in dialog systemctl journalctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Установка зависимостей: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y --no-install-recommends "${missing[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}"
        else
            echo "Не удалось установить зависимости. Установите их вручную: ${missing[*]}"
            exit 1
        fi
    fi

    # Дополнительно: для графиков можно поставить ifstat и ttyplot (опционально)
    if ! command -v ttyplot >/dev/null 2>&1; then
        echo "ttyplot не найден. Графики будут недоступны."
        echo "Установите: curl -sS https://github.com/tenox7/ttyplot/releases/... | sudo tar xzf - -C /usr/local/bin/"
    fi
}

# --- Управление экземплярами ---

# Список портов всех активных экземпляров (читаем из systemd юнитов)
list_instance_ports() {
    systemctl list-units --all --no-legend "$SERVICE_PREFIX-*" 2>/dev/null | \
        awk '{print $1}' | sed "s/${SERVICE_PREFIX}-//;s/\.service$//" | sort -n
}

# Проверка, запущен ли экземпляр с портом
is_running() {
    systemctl is-active --quiet "${SERVICE_PREFIX}-${1}" 2>/dev/null
}

# Получить статус (Running/Stopped/Not Found)
get_status() {
    if systemctl is-active --quiet "${SERVICE_PREFIX}-${1}" 2>/dev/null; then
        echo "Running"
    elif systemctl is-enabled --quiet "${SERVICE_PREFIX}-${1}" 2>/dev/null; then
        echo "Stopped"
    else
        echo "Not installed"
    fi
}

# Добавить новый экземпляр
add_instance() {
    local port domain secret fake_tls answer
    exec 3>&1
    values=$(dialog --form "Новый MTProto прокси" 15 50 0 \
        "Порт:" 1 1 "$port" 1 15 10 0 \
        "Домен-секрет:" 2 1 "$domain" 2 15 50 0 \
        "Секрет (необязательно):" 3 1 "$secret" 3 25 50 0 \
        "Fake TLS (yes/no):" 4 1 "yes" 4 20 5 0 \
        2>&1 1>&3)
    exit_code=$?
    exec 3>&-
    [ $exit_code -eq 0 ] || return

    IFS=$'\n' read -d '' -r port domain secret fake_tls <<< "$values"
    if [ -z "$port" ] || [ -z "$domain" ]; then
        dialog --msgbox "Порт и домен обязательны!" 6 40
        return 1
    fi

    # Вызов mtbuddy для установки
    local mtbuddy_args=(install --port "$port" --domain "$domain" --yes)
    [ -n "$secret" ] && mtbuddy_args+=(--secret "$secret")
    if [ "${fake_tls,,}" = "yes" ]; then
        mtbuddy_args+=(--fake-tls)
    fi

    dialog --infobox "Установка прокси на порту $port, подождите..." 5 40
    if $MTBUDDY "${mtbuddy_args[@]}" 2>&1 | dialog --progressbox 20 60; then
        dialog --msgbox "Прокси на порту $port успешно установлен и запущен." 6 50
    else
        dialog --msgbox "Ошибка при установке! Проверьте вывод mtbuddy." 6 50
    fi
}

# Удалить экземпляр
remove_instance() {
    local port=$(select_instance "Выберите экземпляр для удаления:")
    [ -z "$port" ] && return
    dialog --yesno "Удалить прокси на порту $port? Это остановит и удалит сервис." 7 50
    if [ $? -eq 0 ]; then
        systemctl stop "${SERVICE_PREFIX}-${port}" 2>/dev/null || true
        systemctl disable "${SERVICE_PREFIX}-${port}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_PREFIX}-${port}.service"
        systemctl daemon-reload
        # Удалим возможный конфиг mtbuddy, если он хранился отдельно
        rm -f "${INSTANCE_DIR}/${port}.conf"
        dialog --msgbox "Экземпляр $port удалён." 5 40
    fi
}

# Запустить/остановить/перезапустить
control_instance() {
    local action="$1"
    local port=$(select_instance "Выберите экземпляр для $action:")
    [ -z "$port" ] && return
    case "$action" in
        start|stop|restart)
            systemctl "$action" "${SERVICE_PREFIX}-${port}"
            dialog --msgbox "Действие '$action' выполнено для порта $port." 5 50
            ;;
    esac
}

# Показать логи реального времени
show_logs() {
    local port=$(select_instance "Выберите экземпляр для просмотра логов:")
    [ -z "$port" ] && return
    dialog --title "Логи mtproto-$port" --tailbox <(journalctl -u "${SERVICE_PREFIX}-${port}" -f) 20 70
}

# Показать график входящего/исходящего трафика (общий серверный)
show_traffic_graph() {
    if ! command -v ttyplot >/dev/null 2>&1; then
        dialog --msgbox "Графики недоступны: ttyplot не установлен.\nУстановите его с https://github.com/tenox7/ttyplot" 8 60
        return
    fi
    if ! command -v ifstat >/dev/null 2>&1; then
        dialog --msgbox "Графики недоступны: ifstat не установлен.\nВыполните: sudo apt install ifstat" 8 60
        return
    fi

    # Определим основной сетевой интерфейс (первый НЕ loopback)
    local iface=$(ip -o link show | awk -F': ' '!/lo/ {print $2; exit}')
    [ -z "$iface" ] && { dialog --msgbox "Не найден сетевой интерфейс."; return; }

    dialog --title "Трафик на интерфейсе $iface" --msgbox "График обновляется каждые 2 секунды. Для выхода нажмите Ctrl+C." 6 60
    # Запустим ifstat + ttyplot в терминале диалога (используем --no-shadow)
    clear
    ifstat -i "$iface" -t 1 2>/dev/null | \
        ttyplot -t "RX (KB/s)" -u "KB/s" -c "#00ff00" -s 80 -f 2>/dev/null &
    PID1=$!
    sleep 1
    ifstat -i "$iface" -t 1 2>/dev/null | \
        ttyplot -t "TX (KB/s)" -u "KB/s" -c "#ff0000" -s 80 -f 2>/dev/null &
    PID2=$!
    wait $PID1 $PID2 2>/dev/null
    clear
    dialog --msgbox "График остановлен." 5 30
}

# Общий список экземпляров с выбором (выводит порт)
select_instance() {
    local ports=()
    while IFS= read -r p; do
        ports+=("$p" "Порт $p ($(get_status "$p"))")
    done < <(list_instance_ports)

    if [ ${#ports[@]} -eq 0 ]; then
        dialog --msgbox "Нет зарегистрированных прокси-экземпляров." 6 40
        return 1
    fi

    local choice
    choice=$(dialog --clear --title "$1" --menu "Доступные экземпляры" 15 50 10 "${ports[@]}" 2>&1 >/dev/tty)
    [ -n "$choice" ] && echo "$choice"
}

# --- Главное меню TUI ---
main_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "MTProxy Manager" \
            --title "Главное меню" \
            --menu "Выберите действие:" 15 60 8 \
            1 "Список всех экземпляров" \
            2 "Добавить новый" \
            3 "Удалить" \
            4 "Запустить" \
            5 "Остановить" \
            6 "Перезапустить" \
            7 "Логи (реального времени)" \
            8 "График трафика" \
            9 "Выход" \
            2>&1 >/dev/tty)

        case "$choice" in
            1) dialog --msgbox "$(systemctl list-units --all "${SERVICE_PREFIX}-*" --no-legend | awk '{printf "%-20s %s\n", $1, $4}')" 20 60 ;;
            2) add_instance ;;
            3) remove_instance ;;
            4) control_instance start ;;
            5) control_instance stop ;;
            6) control_instance restart ;;
            7) show_logs ;;
            8) show_traffic_graph ;;
            9) clear; exit 0 ;;
        esac
    done
}

# Точка входа
install_dependencies
main_menu
