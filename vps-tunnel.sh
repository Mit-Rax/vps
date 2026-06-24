#!/usr/bin/env bash
set -euo pipefail

# Automates installing and running frp (frps) on a VPS
# Steps covered:
#  - apt update/upgrade
#  - install frp binaries under /opt/frp
#  - write /opt/frp/frps.ini
#  - configure UFW firewall (allows SSH first)
#  - create and start systemd service

FRP_VERSION="0.61.2"
ARCHIVE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"
BASE_DIR="/opt"
FRP_DIR="${BASE_DIR}/frp"

# Ports per user instructions
FRPS_BIND_PORT=7000
SSH_PORT=22

# Ports to forward (client-side)
FORWARD_PORTS=(
    80
    8080
    4444
    1432
    3333
    22533
)

log() { echo "[frp-setup] $*"; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log "Please run as root (e.g., sudo ./vps.sh)"
        exit 1
    fi
}

install_frp() {
    log "Installing frp ${FRP_VERSION}..."
    mkdir -p "${BASE_DIR}"
    cd "${BASE_DIR}"

    if [[ ! -f "${ARCHIVE}" ]]; then
        log "Downloading ${DOWNLOAD_URL}"
        if ! wget -q --timeout=30 "${DOWNLOAD_URL}"; then
            log "❌ Failed to download frp. Check internet connection."
            exit 1
        fi
    else
        log "Archive already exists: ${BASE_DIR}/${ARCHIVE}"
    fi

    # Remove old frp directory
    rm -rf "${FRP_DIR}"
    
    # Extract
    tar -xzf "${ARCHIVE}"
    
    # Verify extracted directory
    local extracted_dir="${BASE_DIR}/frp_${FRP_VERSION}_linux_amd64"
    if [[ ! -d "${extracted_dir}" ]]; then
        log "❌ Extracted directory not found: ${extracted_dir}"
        exit 1
    fi

    mv "${extracted_dir}" "${FRP_DIR}"

    if [[ ! -x "${FRP_DIR}/frps" ]]; then
        log "❌ frps binary not found or not executable in ${FRP_DIR}"
        exit 1
    fi

    log "✅ frp installed to ${FRP_DIR}"
}

write_frps_config() {
    log "Writing frps.ini..."
    cat > "${FRP_DIR}/frps.ini" <<EOF
[common]
bind_port = ${FRPS_BIND_PORT}
bind_addr = 0.0.0.0
EOF
    log "✅ Config written"
}

systemd_service() {
    log "Creating systemd service..."
    cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=${FRP_DIR}/frps -c ${FRP_DIR}/frps.ini
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps
    systemctl restart frps
    
    sleep 2
    if systemctl is-active --quiet frps; then
        log "✅ frps service started successfully"
    else
        log "❌ frps service failed to start. Check: journalctl -u frps"
    fi
}

ufw_config() {
    # Install ufw if missing
    if ! command -v ufw >/dev/null 2>&1; then
        log "Installing ufw..."
        apt-get update -y
        apt-get install -y ufw
    fi

    log "UFW status: $(ufw status | head -n1 || true)"

    # Set default policies
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true

    # Allow SSH FIRST to avoid locking out
    log "Allowing SSH (${SSH_PORT}/tcp)"
    ufw allow "${SSH_PORT}/tcp" >/dev/null

    # Allow frp control port
    log "Allowing frp control port ${FRPS_BIND_PORT}/tcp"
    ufw allow "${FRPS_BIND_PORT}/tcp" >/dev/null

    # Allow forwarding ports
    log "Allowing forwarding ports..."
    for p in "${FORWARD_PORTS[@]}"; do
        log "  - ${p}/tcp"
        ufw allow "${p}/tcp" >/dev/null
    done

    # Enable UFW if not active
    if [[ "$(ufw status | awk '{print $2}' | head -n1 || true)" != "active" ]]; then
        log "Enabling UFW"
        ufw --force enable >/dev/null
    fi

    log "✅ Firewall configured"
    ufw status verbose
}

main() {
    need_root
    
    log "=== Starting frp VPS Setup ==="
    
    log "Updating system packages..."
    apt update -y
    apt upgrade -y

    log "Installing dependencies..."
    apt-get install -y wget tar

    install_frp
    write_frps_config
    ufw_config
    systemd_service

    log "=== Setup Complete ==="
    log ""
    log "📋 Summary:"
    log "   - frp control port: ${FRPS_BIND_PORT}"
    log "   - Forwarding ports: ${FORWARD_PORTS[*]}"
    log "   - Service: systemctl status frps"
    log "   - Logs: journalctl -u frps -f"
    log ""
    log "⚠️  IMPORTANT: If using cloud provider (AWS/DO/Vultr/etc.),"
    log "   open these ports in your security group/firewall:"
    log "   ${FRPS_BIND_PORT}, ${FORWARD_PORTS[*]}"
    log ""
    log "📝 Next steps on your Kali/Windows machine:"
    log "   1. Download frp client: ${DOWNLOAD_URL}"
    log "   2. Create frpc.ini with server_addr = your-vps-ip"
    log "   3. server_port = ${FRPS_BIND_PORT}"
    log "   4. Start client: ./frpc -c frpc.ini"
}

main "$@"
