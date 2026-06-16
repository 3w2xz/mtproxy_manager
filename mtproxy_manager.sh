#!/bin/bash
set -e

# ============================================================
#   ЦВЕТА И СТИЛИ
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================
#   ПРОВЕРКА ПРАВ
# ============================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Ошибка:${NC} Скрипт должен запускаться от root (sudo)."
    exit 1
fi

# ============================================================
#   ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# ============================================================
WORKDIR="/opt/mtproto"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="/etc/mtproxy_instances.conf"
LOG_FILE="/var/log/mtproxy_manager.log"
SYSTEMD_DIR="/etc/systemd/system"
MTBUDDY_BIN="${BIN_DIR}/mtbuddy"
ZIG_VERSION="0.13.0"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"

# ============================================================
#   ЛОГГИРОВАНИЕ
# ============================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ============================================================
#   ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ
# ============================================================
install_deps() {
    log "Установка системных зависимостей..."
    apt-get update -qq
    apt-get install -y -qq curl git build-essential xz-utils dnsutils systemd
    log "Зависимости установлены."
}

# ============================================================
#   УСТАНОВКА ZIG
# ============================================================
install_zig() {
    if command -v zig &>/dev/null; then
        log "Zig уже установлен."
        return
    fi
    log "Скачивание Zig ${ZIG_VERSION}..."
    cd /tmp
    curl -# -L -O "${ZIG_URL}"
    tar -xf "zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    mv "zig-linux-x86_64-${ZIG_VERSION}" /opt/zig
    ln -sf /opt/zig/zig /usr/local/bin/zig
    log "Zig установлен в /opt/zig."
}

# ============================================================
#   СБОРКА MTBUDDY
# ============================================================
build_mtbuddy() {
    if [[ -f "${MTBUDDY_BIN}" ]]; then
        log "mtbuddy уже собран."
        return
    fi
    log "Клонирование репозитория mtproto.zig..."
    mkdir -p "${WORKDIR}"
    cd "${WORKDIR}"
    if [[ -d "mtproto.zig" ]]; then
        cd mtproto.zig && git pull
    else
        git clone --depth 1 https://github.com/sleep3r/mtproto.zig.git
        cd mtproto.zig
    fi
    log "Компиляция mtbuddy (это займёт несколько минут)..."
    zig build -Drelease-safe
    cp zig-out/bin/mtbuddy "${MTBUDDY_BIN}"
    log "mtbuddy установлен в ${MTBUDDY_BIN}."
}

# ============================================================
#   ПРОВЕРКА ДОМЕНА (DNS)
# ============================================================
check_domain() {
    local domain="$1"
    if ! dig +short "$domain" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${YELLOW}Предупреждение: Домен '$domain' не резолвится в IP-адрес.${NC}"
        echo -e "${YELLOW}Убедитесь, что DNS-запись настроена правильно.${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Домен '$domain' резолвится.${NC}"
        return 0
    fi
}

# ============================================================
#   СОЗДАНИЕ SYSTEMD-СЕРВИСА ДЛЯ ПРОКСИ
# ============================================================
create_systemd_service() {
    local port="$1"
    local domain="$2"
    local secret="$3"
    local service_name="mtproxy-${port}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"

    cat > "$service_file" <<EOF
[Unit]
Description=MTProto Proxy on port ${port}
After=network.target

[Service]
Type=simple
ExecStart=${MTBUDDY_BIN} install --port ${port} --domain ${domain} --secret ${secret} --yes
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}"
    systemctl start "${service_name}"
    log "systemd-сервис ${service_name} создан и запущен."
}

# ============================================================
#   ГЕНЕРАЦИЯ ССЫЛОК
# ============================================================
generate_links() {
    local domain="$1"
    local port="$2"
    local secret="$3"
    # Формируем секрет в hex (если уже hex, то оставляем)
    # Преобразуем secret в hex, если он ещё не hex (если содержит не hex-символы)
    if [[ ! "$secret" =~ ^[0-9a-fA-F]+$ ]]; then
        secret=$(echo -n "$secret" | xxd -ps | tr -d '\n')
    fi
    local link1="tg://proxy?server=${domain}&port=${port}&secret=${secret}"
    local link2="https://t.me/proxy?server=${domain}&port=${port}&secret=${secret}"
    echo -e "${CYAN}Ссылка tg://:${NC} $link1"
    echo -e "${CYAN}Ссылка https:${NC} $link2"
}

# ============================================================
#   ФУНКЦИИ УПРАВЛЕНИЯ ПРОКСИ
# ============================================================

create_proxy() {
    echo -e "${BLUE}${BOLD}--- Создание нового прокси ---${NC}"
    read -p "Введите порт (например, 443): " port
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Неверный порт.${NC}"
        return
    fi
    read -p "Введите домен (например, example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен не может быть пустым.${NC}"
        return
    fi
    read -p "Введите секрет (или оставьте пустым для генерации): " secret
    if [[ -z "$secret" ]]; then
        secret=$(head -c 16 /dev/urandom | xxd -ps | tr -d '\n')
        echo -e "${YELLOW}Сгенерирован секрет: ${secret}${NC}"
    fi

    # Проверка домена
    check_domain "$domain" || {
        read -p "Продолжить, несмотря на предупреждение? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    }

    # Проверка, не занят ли порт
    if systemctl is-active --quiet "mtproxy-${port}" 2>/dev/null; then
        echo -e "${RED}Прокси на порту ${port} уже запущен.${NC}"
        return
    fi

    # Создание systemd-сервиса
    create_systemd_service "$port" "$domain" "$secret"

    # Сохранение в конфиг
    echo "${port}:${domain}:${secret}" >> "${CONFIG_FILE}"

    # Генерация ссылок
    echo -e "\n${GREEN}${BOLD}Прокси создан!${NC}"
    generate_links "$domain" "$port" "$secret"

    log "Создан прокси: порт ${port}, домен ${domain}"
}

list_proxies() {
    echo -e "${BLUE}${BOLD}--- Список прокси ---${NC}"
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        echo -e "${YELLOW}Нет сохранённых прокси.${NC}"
        return
    fi
    local i=1
    while IFS=: read -r port domain secret; do
        local service="mtproxy-${port}"
        local status
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            status="${GREEN}Активен${NC}"
        else
            status="${RED}Остановлен${NC}"
        fi
        echo -e "${GREEN}[$i]${NC} Порт: ${BOLD}$port${NC} | Домен: $domain | Секрет: $secret"
        echo -e "    Статус: $status"
        # Показать ссылки
        generate_links "$domain" "$port" "$secret" | sed 's/^/    /'
        ((i++))
    done < "${CONFIG_FILE}"
}

show_logs() {
    list_proxies
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        return
    fi
    read -p "Введите номер прокси для просмотра логов: " num
    local line=$(sed -n "${num}p" "${CONFIG_FILE}")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Неверный номер.${NC}"
        return
    fi
    local port=$(echo "$line" | cut -d: -f1)
    echo -e "${CYAN}Последние 30 строк лога для порта ${port}:${NC}"
    journalctl -u "mtproxy-${port}" -n 30 --no-pager
}

remove_proxy() {
    list_proxies
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        return
    fi
    read -p "Введите номер прокси для удаления: " num
    local line=$(sed -n "${num}p" "${CONFIG_FILE}")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Неверный номер.${NC}"
        return
    fi
    local port=$(echo "$line" | cut -d: -f1)
    local service="mtproxy-${port}"

    echo -e "${YELLOW}Остановка и удаление прокси на порту ${port}...${NC}"
    systemctl stop "${service}" 2>/dev/null || true
    systemctl disable "${service}" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${service}.service"
    systemctl daemon-reload
    sed -i "${num}d" "${CONFIG_FILE}"
    log "Прокси на порту ${port} удалён."
    echo -e "${GREEN}✓ Прокси удалён.${NC}"
}

# ============================================================
#   МЕНЮ
# ============================================================
show_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}${BOLD}      Управление MTProto прокси (коммерческая версия)${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1${NC}  Создать новый прокси"
    echo -e "  ${GREEN}2${NC}  Показать все прокси"
    echo -e "  ${GREEN}3${NC}  Показать логи прокси"
    echo -e "  ${GREEN}4${NC}  Удалить прокси"
    echo -e "  ${GREEN}5${NC}  Выход"
    echo -e "${BLUE}==================================================${NC}"
    read -p "Выберите действие: " choice
    case $choice in
        1) create_proxy ;;
        2) list_proxies ;;
        3) show_logs ;;
        4) remove_proxy ;;
        5) echo -e "${GREEN}До свидания!${NC}"; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
    read -p "Нажмите Enter для продолжения..."
}

# ============================================================
#   ОСНОВНАЯ УСТАНОВКА (ВЫПОЛНЯЕТСЯ ОДИН РАЗ)
# ============================================================
initial_setup() {
    log "Запуск первичной настройки..."
    install_deps
    install_zig
    build_mtbuddy
    touch "${CONFIG_FILE}"
    log "Первичная настройка завершена."
}

# ============================================================
#   ЗАПУСК СКРИПТА
# ============================================================

# Проверяем, есть ли уже установленный mtbuddy, если нет - выполняем установку
if [[ ! -f "${MTBUDDY_BIN}" ]]; then
    echo -e "${YELLOW}Выполняется первичная установка...${NC}"
    initial_setup
else
    log "Используется существующая установка mtbuddy."
fi

# Бесконечный цикл меню
while true; do
    show_menu
done