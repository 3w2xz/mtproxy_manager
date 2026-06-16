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
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================================
mkdir -p "${LOG_DIR}" "${WORKDIR}"
touch "${CONFIG_FILE}"

# ============================================================
# УСТАНОВКА MTBUDDY (ЕСЛИ НЕТ)
# ============================================================
install_mtbuddy() {
    if [[ -f "${MTBUDDY_BIN}" ]]; then
        echo -e "${GREEN}✓ mtbuddy уже установлен.${NC}"
        return
    fi
    echo -e "${YELLOW}Установка mtbuddy (5–10 минут)...${NC}"
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
# ПРОВЕРКА СТАТУСА СЛУЖБЫ
# ============================================================
service_status() {
    local port="$1"
    local service_name="mtproxy-${port}"
    if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ============================================================
# ПЕРЕИМЕНОВАНИЕ СЛУЖБЫ (после создания mtproto-proxy)
# ============================================================
rename_service() {
    local port="$1"
    local old_service="mtproto-proxy"
    local new_service="mtproxy-${port}"
    local old_service_file="${SYSTEMD_DIR}/${old_service}.service"
    local new_service_file="${SYSTEMD_DIR}/${new_service}.service"

    # Если служба с новым именем уже существует, удаляем её
    if [[ -f "${new_service_file}" ]]; then
        systemctl stop "${new_service}" 2>/dev/null
        systemctl disable "${new_service}" 2>/dev/null
        rm -f "${new_service_file}"
    fi

    # Копируем и переименовываем службу
    if [[ -f "${old_service_file}" ]]; then
        cp "${old_service_file}" "${new_service_file}"
        # Редактируем описание (необязательно)
        sed -i "s/Description=.*/Description=MTProto Proxy ${port}/" "${new_service_file}"
        systemctl daemon-reload
        systemctl enable "${new_service}"
        systemctl start "${new_service}"
        # Останавливаем и удаляем старую службу, чтобы не мешала
        systemctl stop "${old_service}" 2>/dev/null
        systemctl disable "${old_service}" 2>/dev/null
        rm -f "${old_service_file}"
        systemctl daemon-reload
        return 0
    else
        echo -e "${RED}Ошибка: служба ${old_service} не найдена.${NC}"
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

    read -p "Домен (оставьте пустым для IP-адреса сервера): " domain
    if [[ -z "$domain" ]]; then
        domain=$(curl -s ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || hostname -I | awk '{print $1}')
        if [[ -z "$domain" ]]; then
            echo -e "${RED}Не удалось определить IP. Введите домен вручную.${NC}"
            read -p "Домен: " domain
        else
            echo -e "${YELLOW}Используем IP: ${domain}${NC}"
        fi
    fi
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен обязателен.${NC}"
        return
    fi

    read -p "Секрет (оставьте пустым для генерации): " secret
    if [[ -z "$secret" ]]; then
        secret=$(generate_secret)
        echo -e "${YELLOW}Сгенерирован секрет: ${secret}${NC}"
    fi
    if [[ ! "$secret" =~ ^[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}Секрет должен быть в HEX.${NC}"
        return
    fi

    # Проверка домена
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}✓ Используется IP-адрес.${NC}"
    else
        if dig +short "$domain" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo -e "${GREEN}✓ Домен резолвится.${NC}"
        else
            echo -e "${YELLOW}⚠ Домен не резолвится! Прокси может не работать.${NC}"
            read -p "Продолжить? (y/N): " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
        fi
    fi

    # Проверяем, не занят ли порт
    if netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
        echo -e "${RED}Порт ${port} уже занят!${NC}"
        return
    fi

    # Запускаем установку
    echo -e "${YELLOW}Установка прокси на порту ${port}...${NC}"
    ${MTBUDDY_BIN} install --port "$port" --domain "$domain" --secret "$secret"

    # Проверяем, создалась ли служба
    if systemctl list-unit-files | grep -q mtproto-proxy.service; then
        # Переименовываем службу
        if rename_service "$port"; then
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
            echo -e "${YELLOW}📋 Логи: journalctl -u mtproxy-${port} -f${NC}"
            echo -e "${YELLOW}🛑 Остановка: systemctl stop mtproxy-${port}${NC}"
            echo -e "${YELLOW}🔄 Перезапуск: systemctl restart mtproxy-${port}${NC}"
        else
            echo -e "${RED}Ошибка переименования службы.${NC}"
        fi
    else
        echo -e "${RED}Ошибка: служба не создалась.${NC}"
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
        if service_status "$port"; then
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
    echo -e "${CYAN}--- Логи порта ${port} (последние 30 строк) ---${NC}"
    journalctl -u "mtproxy-${port}" -n 30 --no-pager
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
    local service="mtproxy-${port}"
    echo -e "${YELLOW}Остановка и удаление ${service}...${NC}"
    systemctl stop "${service}" 2>/dev/null
    systemctl disable "${service}" 2>/dev/null
    rm -f "${SYSTEMD_DIR}/${service}.service"
    systemctl daemon-reload
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
install_mtbuddy
while true; do
    show_menu
done
