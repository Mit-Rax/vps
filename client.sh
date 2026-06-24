#!/usr/bin/env bash
set -euo pipefail

# Automates installing and running frp (frpc) on Kali Linux
# Steps covered:
#  - apt update/upgrade
#  - install frp binaries under /opt/frp
#  - prompt for VPS server IP
#  - write /opt/frp/frpc.ini
#  - show how to run manually

FRP_VERSION="0.61.2"
ARCHIVE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"
BASE_DIR="/opt"
FRP_DIR="${BASE_DIR}/frp"

# Default ports (matching server config)
SERVER_PORT=7000

# Ports to forward from Kali to VPS
FORWARD_PORTS=(
    80
    8080
    4444
    1432
    3333
    22533
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "[frp-client] $*"; }
log_ok() { echo -e "${GREEN}[frp-client] ✅ $*${NC}"; }
log_warn() { echo -e "${YELLOW}[frp-client] ⚠️  $*${NC}"; }
log_err() { echo -e "${RED}[frp-client] ❌ $*${NC}"; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "Please run as root (e.g., sudo ./client-setup.sh)"
        exit 1
    fi
}

get_server_ip() {
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Enter your VPS server IP address:"
    read -p "> " SERVER_IP
    
    if [[ -z "${SERVER_IP}" ]]; then
        log_err "IP address cannot be empty"
        exit 1
    fi
    
    # Simple IP validation
    if ! [[ "${SERVER_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warn "IP format doesn't look like IPv4. Are you sure? (continuing anyway)"
        read -p "Continue with ${SERVER_IP}? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log_ok "Using VPS IP: ${SERVER_IP}"
}

install_frp() {
    log "Installing frp ${FRP_VERSION}..."
    mkdir -p "${BASE_DIR}"
    cd "${BASE_DIR}"

    if [[ ! -f "${ARCHIVE}" ]]; then
        log "Downloading ${DOWNLOAD_URL}"
        if ! wget -q --timeout=30 --show-progress "${DOWNLOAD_URL}"; then
            log_err "Failed to download frp. Check internet connection."
            exit 1
        fi
    else
        log "Archive already exists: ${BASE_DIR}/${ARCHIVE}"
    fi

    rm -rf "${FRP_DIR}"
    tar -xzf "${ARCHIVE}"
    
    local extracted_dir="${BASE_DIR}/frp_${FRP_VERSION}_linux_amd64"
    if [[ ! -d "${extracted_dir}" ]]; then
        log_err "Extracted directory not found: ${extracted_dir}"
        exit 1
    fi

    mv "${extracted_dir}" "${FRP_DIR}"

    if [[ ! -x "${FRP_DIR}/frpc" ]]; then
        log_err "frpc binary not found or not executable in ${FRP_DIR}"
        exit 1
    fi

    log_ok "frp installed to ${FRP_DIR}"
}

write_frpc_config() {
    log "Writing frpc.ini..."
    
    local port_sections=""
    for p in "${FORWARD_PORTS[@]}"; do
        port_sections="${port_sections}
[port-${p}]
type = tcp
local_ip = 127.0.0.1
local_port = ${p}
remote_port = ${p}
"
    done

    cat > "${FRP_DIR}/frpc.ini" <<EOF
[common]
server_addr = ${SERVER_IP}
server_port = ${SERVER_PORT}
${port_sections}
EOF
    
    log_ok "Config written to ${FRP_DIR}/frpc.ini"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Config preview:"
    cat "${FRP_DIR}/frpc.ini"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

test_connection() {
    log "Testing connection to VPS..."
    
    if ping -c 1 -W 2 "${SERVER_IP}" >/dev/null 2>&1; then
        log_ok "Ping to ${SERVER_IP} successful"
    else
        log_warn "Ping failed (ICMP may be blocked) - continuing anyway"
    fi
    
    if command -v nc >/dev/null 2>&1; then
        if nc -zv -w 3 "${SERVER_IP}" "${SERVER_PORT}" 2>&1 | grep -q succeeded; then
            log_ok "Port ${SERVER_PORT} is open on ${SERVER_IP}"
        else
            log_warn "Port ${SERVER_PORT} appears closed on ${SERVER_IP}"
            log_warn "Check: VPS firewall, cloud security group, and frps is running"
            read -p "Continue anyway? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        log_warn "nc (netcat) not installed - skipping port test"
    fi
}

show_usage() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "📋 HOW TO RUN frpc:"
    log ""
    log "  Option 1: Run in foreground (see output)"
    log "    cd ${FRP_DIR} && ./frpc -c frpc.ini"
    log ""
    log "  Option 2: Run in background with nohup"
    log "    cd ${FRP_DIR} && nohup ./frpc -c frpc.ini > frp.log 2>&1 &"
    log ""
    log "  Option 3: Run with screen (detachable)"
    log "    screen -S frp"
    log "    cd ${FRP_DIR} && ./frpc -c frpc.ini"
    log "    Press Ctrl+A then D to detach"
    log "    Reattach with: screen -r frp"
    log ""
    log "  Option 4: Run with tmux"
    log "    tmux new -s frp"
    log "    cd ${FRP_DIR} && ./frpc -c frpc.ini"
    log "    Press Ctrl+B then D to detach"
    log "    Reattach with: tmux attach -t frp"
    log ""
    log "📋 VIEW LOGS:"
    log "    tail -f ${FRP_DIR}/frp.log  (if using nohup)"
    log ""
    log "📋 STOP frpc:"
    log "    pkill frpc"
    log "    or: kill \$(ps aux | grep frpc | grep -v grep | awk '{print \$2}')"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

quick_start() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🚀 QUICK START (recommended):"
    log ""
    log "  cd ${FRP_DIR} && screen -S frp && ./frpc -c frpc.ini"
    log ""
    log "  Then press Ctrl+A then D to detach"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    need_root
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "    frp Client Setup for Kali Linux"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    log "Updating system packages..."
    apt update -y
    apt upgrade -y

    log "Installing dependencies..."
    apt-get install -y wget tar netcat-openbsd screen

    get_server_ip
    install_frp
    write_frpc_config
    test_connection
    
    log ""
    log_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_ok "✅ Setup Complete!"
    log_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    show_usage
    quick_start
    
    log ""
    log "📋 Port Forwarding Summary:"
    for p in "${FORWARD_PORTS[@]}"; do
        log "   Kali:${p} ↔ VPS:${p}"
    done
    log ""
    log "🌐 Access from anywhere:"
    log "   curl http://${SERVER_IP}:80"
    log "   curl http://${SERVER_IP}:8080"
    log "   nc ${SERVER_IP} 4444"
    log ""
    log "🔧 Test your setup:"
    log "   # On Kali, start a test web server:"
    log "   python3 -m http.server 80"
    log "   # Then from any machine:"
    log "   curl http://${SERVER_IP}:80"
}

main "$@"
