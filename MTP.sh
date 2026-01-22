#!/bin/bash

# 全局配置
WORKDIR="/opt/mtproxy"
CONFIG_DIR="$WORKDIR/config"
LOG_DIR="$WORKDIR/logs"
BIN_DIR="$WORKDIR/bin"

# 获取脚本绝对路径
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# 系统检测
OS=""
PACKAGE_MANAGER=""
INIT_SYSTEM=""

check_sys() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    fi

    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        PACKAGE_MANAGER="apk"
        INIT_SYSTEM="openrc"
    elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        PACKAGE_MANAGER="apt"
        INIT_SYSTEM="systemd"
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        PACKAGE_MANAGER="yum"
        INIT_SYSTEM="systemd"
    else
        echo -e "${RED}不支持的系统: $OS${PLAIN}"
        exit 1
    fi
}

install_base_deps() {
    echo -e "${BLUE}正在安装基础依赖...${PLAIN}"
    if [[ "$PACKAGE_MANAGER" == "apk" ]]; then
        apk update
        apk add curl wget tar ca-certificates openssl bash
    elif [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        apt-get update
        apt-get install -y curl wget tar
    elif [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        yum install -y curl wget tar
    fi
}

get_public_ip() {
    curl -s4 --max-time 5 https://api.ip.sb/ip -A Mozilla || curl -s4 --max-time 5 https://ipinfo.io/ip -A Mozilla
}

get_public_ipv6() {
    curl -s6 --max-time 5 https://api.ip.sb/ip -A Mozilla || curl -s6 --max-time 5 https://ifconfig.co/ip -A Mozilla
}

prefetch_ips() {
    echo -e "${BLUE}正在检测服务器 IP...${PLAIN}"
    PUBLIC_IPV4=$(get_public_ip)
    PUBLIC_IPV6=$(get_public_ipv6)
}

# --- 修改点：Secret 改为交互式输入 ---
generate_secret() {
    read -p "请输入 Secret (16字节/32位16进制，默认 3e5b010925a504e0748c3bc05b7fbd74): " USER_SECRET
    if [ -z "$USER_SECRET" ]; then
        echo "3e5b010925a504e0748c3bc05b7fbd74"
    else
        echo "$USER_SECRET"
    fi
}

select_ip_mode() {
    echo -e "请选择监听模式:\n1. IPv4 仅 (默认)\n2. IPv6 仅\n3. 双栈模式" >&2
    read -p "选择 [1-3]: " mode
    case $mode in
        2) echo "v6" ;;
        3) echo "dual" ;;
        *) echo "v4" ;;
    esac
}

# --- Python 版安装逻辑 ---
install_mtp_python() {
    prefetch_ips
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) P_ARCH="amd64" ;;
        aarch64) P_ARCH="arm64" ;;
        *) P_ARCH="amd64" ;;
    esac
    
    TARGET_OS="debian"
    [[ "$OS" == "alpine" ]] && TARGET_OS="alpine"
    TARGET_BIN="mtp-python-${TARGET_OS}-${P_ARCH}"
    mkdir -p "$BIN_DIR"

    if [ ! -f "$BIN_DIR/mtp-python" ]; then
        echo -e "${BLUE}正在下载二进制文件...${PLAIN}"
        wget -O "$BIN_DIR/mtp-python" "https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-go.mtp-python/${TARGET_BIN}"
        chmod +x "$BIN_DIR/mtp-python"
    fi

    # 默认域名修改为 azure.microsoft.com
    read -p "请输入伪装域名 (默认 azure.microsoft.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="azure.microsoft.com"
    
    SECRET=$(generate_secret)
    
    IP_MODE=$(select_ip_mode)
    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.py" <<EOF
PORT = $PORT
USERS = {"tg": "$SECRET"}
MODES = {"classic": False, "secure": False, "tls": True}
TLS_DOMAIN = "$DOMAIN"
LISTEN_ADDR_IPV4 = "0.0.0.0"
LISTEN_ADDR_IPV6 = None
EOF

    create_service_python
    show_info_python "$PORT" "$SECRET" "$DOMAIN"
}

create_service_python() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mtp-python.service <<EOF
[Unit]
Description=MTProto Proxy (Python)
After=network.target
[Service]
Type=simple
ExecStart=$BIN_DIR/mtp-python $CONFIG_DIR/config.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable mtp-python && systemctl restart mtp-python
    fi
}

# --- Go 版安装逻辑 ---
install_mtg() {
    prefetch_ips
    mkdir -p "$BIN_DIR"
    ARCH=$(uname -m)
    MTG_ARCH="amd64"; [[ "$ARCH" == "aarch64" ]] && MTG_ARCH="arm64"
    
    if [ ! -f "$BIN_DIR/mtg-go" ]; then
        wget -O "$BIN_DIR/mtg-go" "https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-go.mtp-python/mtg-go-${MTG_ARCH}"
        chmod +x "$BIN_DIR/mtg-go"
    fi

    read -p "请输入伪装域名 (默认 azure.microsoft.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="azure.microsoft.com"
    
    SECRET=$(generate_secret)
    IP_MODE=$(select_ip_mode)
    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443

    create_service_mtg "$PORT" "$SECRET" "$DOMAIN" "$IP_MODE"
    show_info_mtg "$PORT" "$SECRET" "$DOMAIN"
}

create_service_mtg() {
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee$2$HEX_DOMAIN"
    CMD="$BIN_DIR/mtg-go simple-run -i only-ipv4 0.0.0.0:$1 $FULL_SECRET"
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProto Proxy (Go)
After=network.target
[Service]
Type=simple
ExecStart=$CMD
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable mtg && systemctl restart mtg
    fi
}

show_info_python() {
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    echo -e "${GREEN}连接信息：tg://proxy?server=${PUBLIC_IPV4}&port=$1&secret=ee$2$HEX_DOMAIN${PLAIN}"
}

show_info_mtg() {
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    echo -e "${GREEN}连接信息：tg://proxy?server=${PUBLIC_IPV4}&port=$1&secret=ee$2$HEX_DOMAIN${PLAIN}"
}

menu() {
    check_sys
    clear
    echo -e "1. 安装 Go 版\n2. 安装 Python 版\n0. 退出"
    read -p "请选择: " choice
    case $choice in
        1) install_base_deps; install_mtg ;;
        2) install_base_deps; install_mtp_python ;;
        *) exit 0 ;;
    esac
}

menu
