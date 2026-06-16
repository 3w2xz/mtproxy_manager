#!/bin/bash
set -e

# ============================================================
#   ЦВЕТА
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
#   ПРОВЕРКА ROOT
# ============================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Ошибка:${NC} Запускайте с sudo."
    exit 1
fi

# ============================================================
#   ПЕРЕМЕННЫЕ
# ============================================================
WORKDIR="/opt/mtproto"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="/etc/mtproxy_instances.conf"
SYSTEMD_DIR="/etc/systemd/system"
MTBUDDY_BIN="${BIN_DIR}/mtbuddy"
LOG_FILE="/var/log/mtproxy_manager.log"
ZIG_VERSION="0.13.0"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"

# ============================================================
#   ЛОГГИРОВАНИЕ
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ============================================================
#   УСТАНОВКА ЗАВИСИМОСТЕЙ
# ============================================================
install_deps() {
    log "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq curl git build-essential xz-utils dnsutils net-tools
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
    log "Установка Zig ${ZIG_VERSION}..."
    cd /tmp
    curl -# -L -O "${ZIG_URL}"
    tar -xf "zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    mv "zig-linux-x86_64-${ZIG_VERSION}" /opt/zig
    ln -sf /opt/zig/zig /usr/local/bin/zig
    log "Zig установлен."
}

# ============================================================
#   СБОРКА MTBUDDY
# ============================================================
build_mtbuddy() {
    if [[ -f "${MTBUDDY_BIN}" ]]; then
        log "mtbuddy уже собран."
        return
    fi
    log "Сборка mtbuddy (3-5 минут)..."
    mkdir -p "${WORKDIR}"
    cd "${WORKDIR}"
    if [[ -d "mtproto.zig" ]]; then
        cd mtproto.zig && git pull
    else
        git clone --depth 1 https://github.com/sleep3r/mtproto.zig.git
        cd mtproto.zig
    fi
    zig build -Drelease-safe
    cp zig-out/bin/mtbuddy "${MTBUDDY_BIN}"
    chmod +x "${MTBUDDY_BIN}"
    log "mtbuddy собран."
}

# ============================================================
#   ГЕНЕРАЦИЯ СЕКРЕТА (HEX)
# ============================================================
generate_secret() {
    head -c 16 /dev/urandom | xxd -ps | tr -d '\n'
}

# ============================================================
#   ПРОВЕРКА, РАБОТАЕТ ЛИ ПРОКСИ
# ============================================================
check_proxy() {
    local port="$1"
    local domain="$2"
    local secret="$3"
    
    echo -e "${YELLOW}Проверка прокси на порту ${port}...${NC}"
    
    # Проверяем, слушает ли порт
    if netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
        echo -e "${GREEN}✓ Порт ${port} слушает.${NC}"
    else
        echo -e "${RED}✗ Порт ${port} НЕ слушает.${NC}"
        return 1
    fi
    
    # Проверяем через mtbuddy (если есть такая команда)
    if command -v curl &>/dev/null; then
        echo -e "${YELLOW}Проверка соединения...${NC}"
        curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://${domain}:${port}/" 2>/dev/null || echo "Ошибка соединения"
    fi
    
    return 0
}

# ============================================================
#   СОЗДАНИЕ SYSTEMD СЕРВИСА (ИСПРАВЛЕННЫЙ)
# ============================================================
create_systemd_service() {
    local port="$1"
    local domain="$2"
    local secret="$3"
    local service_name="mtproxy-${port}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"

    cat > "$service_file" <<EOF
[Unit]
Description=MTProto Proxy ${port}
After=network.target

[Service]
Type=simple
ExecStart=${MTBUDDY_BIN} install --port ${port} --domain ${domain} --secret ${secret}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}"
    systemctl start "${service_name}"
    
    sleep 2
    
    if systemctl is-active --quiet "${service_name}"; then
        log "Сервис ${service_name} запущен."
        return 0
    else
        log "ОШИБКА: Сервис ${service_name} не запустился!"
        journalctl -u "${service_name}" -n 20 --no-pager
        return 1
    fi
}

# ============================================================
#   ГЕНЕРАЦИЯ ССЫЛОК
# ============================================================
generate_links() {
    local domain="$1"
    local port="$2"
    local secret="$3"
    
    # Секрет уже должен быть в hex
    local link1="tg://proxy?server=${domain}&port=${port}&secret=${secret}"
    local link2="https://t.me/proxy?server=${domain}&port=${port}&secret=${secret}"
    
    echo -e "${CYAN}📱 tg://:${NC} $link1"
    echo -e "${CYAN}🌐 https:${NC} $link2"
}

# ============================================================
#   СОЗДАНИЕ ПРОКСИ
# ============================================================
create_proxy() {
    echo -e "${BLUE}${BOLD}--- Создание прокси ---${NC}"
    
    read -p "Порт (443, 8443 и т.д.): " port
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Неверный порт.${NC}"
        return
    fi
    
    read -p "Домен (ваш.домен.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен обязателен.${NC}"
        return
    fi
    
    read -p "Секрет (оставьте пустым для генерации): " secret
    if [[ -z "$secret" ]]; then
        secret=$(generate_secret)
        echo -e "${YELLOW}Сгенерирован секрет: ${secret}${NC}"
    fi
    
    # Проверяем, что секрет в hex
    if [[ ! "$secret" =~ ^[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}Секрет должен быть в HEX (только 0-9, A-F).${NC}"
        return
    fi
    
    # Проверка длины секрета (должен быть 32 символа для 16 байт)
    if [[ ${#secret} -ne 32 ]]; then
        echo -e "${YELLOW}Предупреждение: секрет длиной ${#secret} символов (обычно 32).${NC}"
    fi
    
    # Проверяем домен
    if dig +short "$domain" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${GREEN}✓ Домен резолвится.${NC}"
    else
        echo -e "${RED}✗ Домен НЕ резолвится! Прокси не будет работать.${NC}"
        read -p "Продолжить? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi
    
    # Проверяем порт
    if netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
        echo -e "${RED}Порт ${port} уже занят!${NC}"
        return
    fi
    
    # Создаём сервис
    if create_systemd_service "$port" "$domain" "$secret"; then
        echo "${port}:${domain}:${secret}" >> "${CONFIG_FILE}"
        
        echo -e "\n${GREEN}${BOLD}✅ Прокси создан и работает!${NC}"
        generate_links "$domain" "$port" "$secret"
        
        # Проверка
        check_proxy "$port" "$domain" "$secret"
        
        log "Создан прокси: ${port} ${domain}"
    else
        echo -e "${RED}❌ Не удалось запустить прокси.${NC}"
        echo -e "${YELLOW}Проверьте логи: journalctl -u mtproxy-${port} -n 50${NC}"
    fi
}

# ============================================================
#   СПИСОК ПРОКСИ
# ============================================================
list_proxies() {
    echo -e "${BLUE}${BOLD}--- Список прокси ---${NC}"
    
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        echo -e "${YELLOW}Нет прокси.${NC}"
        return
    fi
    
    local i=1
    while IFS=: read -r port domain secret; do
        local service="mtproxy-${port}"
        local status
        
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            status="${GREEN}✅ Работает${NC}"
        else
            status="${RED}❌ Остановлен${NC}"
        fi
        
        echo -e "${GREEN}[$i]${NC} Порт: ${BOLD}${port}${NC} | ${domain}"
        echo -e "    Секрет: ${secret}"
        echo -e "    Статус: ${status}"
        
        if netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
            echo -e "    ${GREEN}Порт слушает${NC}"
        else
            echo -e "    ${RED}Порт НЕ слушает${NC}"
        fi
        
        generate_links "$domain" "$port" "$secret" | sed 's/^/    /'
        echo ""
        ((i++))
    done < "${CONFIG_FILE}"
}

# ============================================================
#   ЛОГИ
# ============================================================
show_logs() {
    list_proxies
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        return
    fi
    
    read -p "Номер прокси для логов: " num
    local line=$(sed -n "${num}p" "${CONFIG_FILE}")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Неверный номер.${NC}"
        return
    fi
    
    local port=$(echo "$line" | cut -d: -f1)
    echo -e "${CYAN}--- Логи порта ${port} ---${NC}"
    journalctl -u "mtproxy-${port}" -n 50 --no-pager
}

# ============================================================
#   УДАЛЕНИЕ
# ============================================================
remove_proxy() {
    list_proxies
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        return
    fi
    
    read -p "Номер прокси для удаления: " num
    local line=$(sed -n "${num}p" "${CONFIG_FILE}")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Неверный номер.${NC}"
        return
    fi
    
    local port=$(echo "$line" | cut -d: -f1)
    local service="mtproxy-${port}"
    
    echo -e "${YELLOW}Удаление ${service}...${NC}"
    systemctl stop "${service}" 2>/dev/null || true
    systemctl disable "${service}" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${service}.service"
    systemctl daemon-reload
    sed -i "${num}d" "${CONFIG_FILE}"
    
    echo -e "${GREEN}✅ Прокси удалён.${NC}"
    log "Удалён прокси ${port}"
}

# ============================================================
#   МЕНЮ
# ============================================================
show_menu() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}${BOLD}       MTProto Proxy Manager${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo -e "  ${GREEN}1${NC}  Создать прокси"
    echo -e "  ${GREEN}2${NC}  Список прокси"
    echo -e "  ${GREEN}3${NC}  Логи прокси"
    echo -e "  ${GREEN}4${NC}  Удалить прокси"
    echo -e "  ${GREEN}5${NC}  Выход"
    echo -e "${BLUE}================================================${NC}"
    read -p "Выберите: " choice
    
    case $choice in
        1) create_proxy ;;
        2) list_proxies ;;
        3) show_logs ;;
        4) remove_proxy ;;
        5) echo -e "${GREEN}До свидания!${NC}"; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
    read -p "Нажмите Enter..."
}

# ============================================================
#   УСТАНОВКА
# ============================================================
initial_setup() {
    log "Первичная установка..."
    install_deps
    install_zig
    build_mtbuddy
    touch "${CONFIG_FILE}"
    log "Установка завершена."
}

# ============================================================
#   ЗАПУСК
# ============================================================
if [[ ! -f "${MTBUDDY_BIN}" ]]; then
    echo -e "${YELLOW}Первичная установка (5-10 минут)...${NC}"
    initial_setup
else
    log "Используем существующий mtbuddy."
fi

while true; do
    show_menu
done
