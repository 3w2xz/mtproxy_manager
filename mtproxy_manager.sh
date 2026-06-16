#!/bin/bash

# ============================================================
# ЦВЕТА
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# ПРОВЕРКА ROOT
# ============================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Ошибка:${NC} Запускайте с sudo."
    exit 1
fi

# ============================================================
# ПЕРЕМЕННЫЕ
# ============================================================
WORKDIR="/opt/mtproto"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="/etc/mtproxy_instances.conf"
MTBUDDY_BIN="${BIN_DIR}/mtbuddy"
LOG_DIR="/var/log/mtproxy"
PID_DIR="/var/run/mtproxy"

# ============================================================
# СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================================
create_dirs() {
    mkdir -p "${LOG_DIR}"
    mkdir -p "${PID_DIR}"
    touch "${CONFIG_FILE}"
    echo -e "${GREEN}✓ Директории созданы:${NC}"
    echo -e "  Логи: ${LOG_DIR}"
    echo -e "  PID:  ${PID_DIR}"
    echo -e "  Конфиг: ${CONFIG_FILE}"
}

# ============================================================
# УСТАНОВКА MTBUDDY
# ============================================================
install_mtbuddy() {
    if [[ -f "${MTBUDDY_BIN}" ]]; then
        echo -e "${GREEN}✓ mtbuddy уже установлен.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Установка mtbuddy (5-10 минут)...${NC}"
    
    # Зависимости
    apt-get update -qq
    apt-get install -y -qq curl git build-essential xz-utils net-tools dnsutils
    
    # Zig
    cd /tmp
    curl -# -L -O "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz"
    tar -xf zig-linux-x86_64-0.13.0.tar.xz
    mv zig-linux-x86_64-0.13.0 /opt/zig
    ln -sf /opt/zig/zig /usr/local/bin/zig
    
    # Сборка mtbuddy
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
    
    echo -e "${GREEN}✓ mtbuddy установлен.${NC}"
}

# ============================================================
# ГЕНЕРАЦИЯ СЕКРЕТА
# ============================================================
generate_secret() {
    head -c 16 /dev/urandom | xxd -ps
}

# ============================================================
# ПРОВЕРКА, РАБОТАЕТ ЛИ ПРОКСИ
# ============================================================
is_running() {
    local port="$1"
    if [[ -f "${PID_DIR}/proxy_${port}.pid" ]]; then
        local pid=$(cat "${PID_DIR}/proxy_${port}.pid")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ============================================================
# ЗАПУСК ПРОКСИ
# ============================================================
start_proxy() {
    local port="$1"
    local domain="$2"
    local secret="$3"
    local log_file="${LOG_DIR}/proxy_${port}.log"
    local pid_file="${PID_DIR}/proxy_${port}.pid"
    
    # Создаём директории на всякий случай
    mkdir -p "${LOG_DIR}" "${PID_DIR}"
    
    # Останавливаем старый, если есть
    if is_running "$port"; then
        kill $(cat "$pid_file") 2>/dev/null
        rm -f "$pid_file"
    fi
    
    # Запускаем в фоне с перезапуском
    (
        while true; do
            ${MTBUDDY_BIN} install --port "$port" --domain "$domain" --secret "$secret"
            echo "$(date): Прокси упал, перезапуск через 5 секунд..." >> "$log_file"
            sleep 5
        done
    ) >> "$log_file" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$pid_file"
    
    sleep 3
    
    if is_running "$port"; then
        echo -e "${GREEN}✓ Прокси запущен (PID: $pid)${NC}"
        return 0
    else
        echo -e "${RED}✗ Не удалось запустить прокси${NC}"
        if [[ -f "$log_file" ]]; then
            echo -e "${YELLOW}Последние строки лога:${NC}"
            tail -10 "$log_file"
        fi
        return 1
    fi
}

# ============================================================
# СОЗДАНИЕ ПРОКСИ
# ============================================================
create_proxy() {
    clear
    echo -e "${BLUE}${BOLD}--- Создание прокси ---${NC}"
    echo ""
    
    read -p "Порт (например, 443): " port
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Неверный порт.${NC}"
        return
    fi
    
    read -p "Домен (например, example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен обязателен.${NC}"
        return
    fi
    
    read -p "Секрет (оставьте пустым для генерации): " secret
    if [[ -z "$secret" ]]; then
        secret=$(generate_secret)
        echo -e "${YELLOW}Сгенерирован секрет: ${secret}${NC}"
    fi
    
    # Проверка секрета (должен быть hex)
    if [[ ! "$secret" =~ ^[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}Секрет должен быть в HEX (0-9, A-F).${NC}"
        return
    fi
    
    # Проверяем домен
    if dig +short "$domain" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${GREEN}✓ Домен резолвится в IP.${NC}"
    else
        echo -e "${YELLOW}⚠ Домен не резолвится! Прокси может не работать.${NC}"
        read -p "Продолжить? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi
    
    # Проверяем порт
    if netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
        echo -e "${RED}Порт ${port} уже занят!${NC}"
        return
    fi
    
    # Запускаем
    if start_proxy "$port" "$domain" "$secret"; then
        # Сохраняем в конфиг
        echo "${port}:${domain}:${secret}" >> "${CONFIG_FILE}"
        
        echo ""
        echo -e "${GREEN}${BOLD}✅ Прокси создан и работает!${NC}"
        echo ""
        echo -e "${CYAN}📱 Ссылка для Telegram:${NC}"
        echo -e "tg://proxy?server=${domain}&port=${port}&secret=${secret}"
        echo ""
        echo -e "${CYAN}🌐 Альтернативная ссылка:${NC}"
        echo -e "https://t.me/proxy?server=${domain}&port=${port}&secret=${secret}"
        echo ""
        echo -e "${YELLOW}📋 Логи: tail -f ${LOG_DIR}/proxy_${port}.log${NC}"
        echo -e "${YELLOW}🛑 Остановка: kill \$(cat ${PID_DIR}/proxy_${port}.pid)${NC}"
        echo -e "${YELLOW}🔄 Перезапуск: systemctl restart mtproxy-${port} 2>/dev/null || ${MTBUDDY_BIN} install --port ${port} --domain ${domain} --secret ${secret}${NC}"
    fi
}

# ============================================================
# СПИСОК ПРОКСИ
# ============================================================
list_proxies() {
    clear
    echo -e "${BLUE}${BOLD}--- Список прокси ---${NC}"
    echo ""
    
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        echo -e "${YELLOW}Нет созданных прокси.${NC}"
        return
    fi
    
    local i=1
    while IFS=: read -r port domain secret; do
        local status
        if is_running "$port"; then
            status="${GREEN}✅ Работает${NC}"
        else
            status="${RED}❌ Остановлен${NC}"
        fi
        
        echo -e "${GREEN}[$i]${NC} Порт: ${BOLD}${port}${NC} | ${domain}"
        echo -e "    Секрет: ${secret}"
        echo -e "    Статус: ${status}"
        echo -e "    Ссылка: tg://proxy?server=${domain}&port=${port}&secret=${secret}"
        echo ""
        ((i++))
    done < "${CONFIG_FILE}"
}

# ============================================================
# ЛОГИ
# ============================================================
show_logs() {
    list_proxies
    if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -s "${CONFIG_FILE}" ]]; then
        return
    fi
    
    read -p "Введите номер прокси: " num
    local line=$(sed -n "${num}p" "${CONFIG_FILE}")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Неверный номер.${NC}"
        return
    fi
    
    local port=$(echo "$line" | cut -d: -f1)
    local log_file="${LOG_DIR}/proxy_${port}.log"
    
    if [[ -f "$log_file" ]]; then
        echo -e "${CYAN}--- Логи порта ${port} (последние 30 строк) ---${NC}"
        tail -30 "$log_file"
    else
        echo -e "${YELLOW}Лог-файл не найден: ${log_file}${NC}"
    fi
}

# ============================================================
# УДАЛЕНИЕ
# ============================================================
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
    local pid_file="${PID_DIR}/proxy_${port}.pid"
    local log_file="${LOG_DIR}/proxy_${port}.log"
    
    echo -e "${YELLOW}Остановка прокси на порту ${port}...${NC}"
    
    if [[ -f "$pid_file" ]]; then
        kill $(cat "$pid_file") 2>/dev/null
        rm -f "$pid_file"
    fi
    
    rm -f "$log_file"
    sed -i "${num}d" "${CONFIG_FILE}"
    
    echo -e "${GREEN}✓ Прокси удалён.${NC}"
}

# ============================================================
# МЕНЮ
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
# ЗАПУСК
# ============================================================

# Создаём все необходимые директории
create_dirs

# Установка mtbuddy
install_mtbuddy

# Главное меню
while true; do
    show_menu
done
