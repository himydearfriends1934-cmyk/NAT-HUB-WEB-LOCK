#!/usr/bin/env bash
# Restrict the Master Web listener to a local Docker bridge or loopback.
# This script does not install or configure Nginx Proxy Manager.

set -Eeuo pipefail

SERVICE="nat-master.service"
UNIT_FILE="/etc/systemd/system/${SERVICE}"
STATE_DIR="/etc/nat-hub"
STATE_FILE="${STATE_DIR}/web-lock.state"
WEB_PORT=""
BIND_HOST="${NAT_HUB_WEB_BIND:-}"
MODE="lock"
LOOPBACK=0

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

usage() {
    cat <<'EOF'
Usage:
  lock-master-web.sh [--bind IPv4] [--port PORT]
  lock-master-web.sh --loopback [--port PORT]
  lock-master-web.sh --status
  lock-master-web.sh --restore

Examples:
  lock-master-web.sh --bind 172.17.0.1
  lock-master-web.sh --loopback
EOF
}

die() {
    red "ERROR: $*"
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || die "run this script as root"
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

private_ipv4() {
    local a b c d
    IFS=. read -r a b c d <<EOF
$1
EOF
    case "$a.$b.$c.$d" in
        *[!0-9.]*|*.*.*.*.*|.*|*.) return 1 ;;
    esac
    [ "$a" -ge 0 ] 2>/dev/null && [ "$a" -le 255 ] 2>/dev/null || return 1
    [ "$b" -ge 0 ] 2>/dev/null && [ "$b" -le 255 ] 2>/dev/null || return 1
    [ "$c" -ge 0 ] 2>/dev/null && [ "$c" -le 255 ] 2>/dev/null || return 1
    [ "$d" -ge 0 ] 2>/dev/null && [ "$d" -le 255 ] 2>/dev/null || return 1
    [ "$a" = "10" ] ||
        { [ "$a" = "172" ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
        { [ "$a" = "192" ] && [ "$b" = "168" ]; } ||
        { [ "$a" = "100" ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } ||
        [ "$a" = "127" ] ||
        { [ "$a" = "169" ] && [ "$b" = 254 ]; }
}

unit_port() {
    [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} was not found"
    sed -nE 's/^[[:space:]]*ExecStart=.*-port=([0-9]+)([[:space:]]|$).*/\1/p' "$UNIT_FILE" | head -n 1
}

ip_for_interface() {
    local interface="$1"
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 -o addr show dev "$interface" 2>/dev/null |
        awk '{split($4, parts, "/"); print parts[1]; exit}'
}

interface_for_ip() {
    local address="$1"
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 -o addr show 2>/dev/null |
        awk -v target="$address" '{split($4, parts, "/"); if (parts[1] == target) { print $2; exit }}'
}

docker_bridge_ip() {
    local candidate=""

    if command -v docker >/dev/null 2>&1; then
        candidate="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
        if [ -n "$candidate" ] && [ -n "$(interface_for_ip "$candidate")" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi

    candidate="$(ip_for_interface docker0)"
    if [ -n "$candidate" ]; then
        printf '%s' "$candidate"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show 2>/dev/null |
            awk '$2 ~ /^br-/ {split($4, parts, "/"); print parts[1]; exit}'
    fi
}

detect_bind_host() {
    if [ "$LOOPBACK" = "1" ]; then
        BIND_HOST="127.0.0.1"
    elif [ -z "$BIND_HOST" ]; then
        BIND_HOST="$(docker_bridge_ip)"
    fi
    [ -n "$BIND_HOST" ] || die "Docker bridge was not found; pass --bind 172.17.0.1 or use --loopback"
    private_ipv4 "$BIND_HOST" ||
        die "${BIND_HOST} is not a private or loopback address; refusing to re-expose the public Web port"
    [ -n "$(interface_for_ip "$BIND_HOST")" ] ||
        die "${BIND_HOST} is not assigned to this host; pass an address shown by 'ip -4 -o addr show'"
}

iptables_delete_accept_rule() {
    local interface="$1"
    local port="$2"
    command -v iptables >/dev/null 2>&1 || return 0
    while iptables -C INPUT -i "$interface" -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$interface" -p tcp --dport "$port" -j ACCEPT || break
    done
}

iptables_delete_drop_rule() {
    local interface="$1"
    local port="$2"
    command -v iptables >/dev/null 2>&1 || return 0
    while iptables -C INPUT ! -i "$interface" -p tcp --dport "$port" -j DROP 2>/dev/null; do
        iptables -D INPUT ! -i "$interface" -p tcp --dport "$port" -j DROP || break
    done
}

iptables_add_rule() {
    local interface="$1"
    local port="$2"
    command -v iptables >/dev/null 2>&1 || {
        yellow "WARNING: iptables is not installed; listener binding still blocks the public IP."
        return 0
    }

    if ! iptables -C INPUT -i "$interface" -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -i "$interface" -p tcp --dport "$port" -j ACCEPT 2>/dev/null ||
            yellow "WARNING: could not add the Docker bridge allow rule"
    fi
    if ! iptables -C INPUT ! -i "$interface" -p tcp --dport "$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 1 ! -i "$interface" -p tcp --dport "$port" -j DROP 2>/dev/null ||
            yellow "WARNING: could not add the public Web port deny rule"
    fi
}

write_unit_with_bind() {
    local temporary
    temporary="${UNIT_FILE}.tmp.$$"
    sed -E "s#(-bind=)[^[:space:]]+#\\1${BIND_HOST}#" "$UNIT_FILE" > "$temporary"
    if ! grep -Eq -- "-bind=${BIND_HOST}([[:space:]]|$)" "$temporary"; then
        rm -f "$temporary"
        die "could not update the Web bind address in ${UNIT_FILE}"
    fi
    chmod 644 "$temporary"
    mv -f "$temporary" "$UNIT_FILE"
}

lock_web() {
    require_root
    [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} was not found"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

    local configured_port
    configured_port="$(unit_port)"
    [ -n "$configured_port" ] || die "could not read the Web port from ${UNIT_FILE}"
    if [ -n "$WEB_PORT" ]; then
        valid_port "$WEB_PORT" || die "invalid Web port: ${WEB_PORT}"
        [ "$WEB_PORT" = "$configured_port" ] ||
            die "service Web port is ${configured_port}; do not pass --port ${WEB_PORT}"
    else
        WEB_PORT="$configured_port"
    fi

    detect_bind_host
    local interface backup
    interface="$(interface_for_ip "$BIND_HOST")"
    [ -n "$interface" ] || die "could not find the interface for ${BIND_HOST}"

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    backup="${STATE_DIR}/nat-master.service.before-web-lock.$(date +%Y%m%d%H%M%S)"
    cp -p "$UNIT_FILE" "$backup"
    umask 077
    printf 'BACKUP=%s\nBIND_HOST=%s\nINTERFACE=%s\nWEB_PORT=%s\n' \
        "$backup" "$BIND_HOST" "$interface" "$WEB_PORT" > "$STATE_FILE"

    if ! write_unit_with_bind; then
        cp -p "$backup" "$UNIT_FILE"
        rm -f "$STATE_FILE"
        exit 1
    fi

    systemctl daemon-reload
    if ! systemctl restart "$SERVICE"; then
        cp -p "$backup" "$UNIT_FILE"
        systemctl daemon-reload
        systemctl restart "$SERVICE" || true
        rm -f "$STATE_FILE"
        die "Master restart failed; the original service file was restored"
    fi
    if ! systemctl is-active --quiet "$SERVICE"; then
        cp -p "$backup" "$UNIT_FILE"
        systemctl daemon-reload
        systemctl restart "$SERVICE" || true
        rm -f "$STATE_FILE"
        die "Master is not active after the change; the original service file was restored"
    fi

    iptables_add_rule "$interface" "$WEB_PORT"
    green "Master Web is now bound to ${BIND_HOST}:${WEB_PORT} (interface ${interface})."
    green "NPM can proxy to http://${BIND_HOST}:${WEB_PORT}; the public IP should refuse ${WEB_PORT}."
    yellow "Node signaling remains unchanged. Check it with: ss -ltnp | grep ':${WEB_PORT}\\|:31177'"
    yellow "To restore the previous Master Web binding: $0 --restore"
}

restore_web() {
    require_root
    [ -f "$STATE_FILE" ] || die "no ${STATE_FILE} was found"
    # This file is created mode 600 by this script and contains only local paths and values.
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ -f "${BACKUP:-}" ] || die "the saved service backup was not found"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

    cp -p "$BACKUP" "$UNIT_FILE"
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    if command -v iptables >/dev/null 2>&1; then
        iptables_delete_accept_rule "$INTERFACE" "$WEB_PORT"
        iptables_delete_drop_rule "$INTERFACE" "$WEB_PORT"
    fi
    rm -f "$STATE_FILE"
    green "The previous Master Web binding was restored."
}

show_status() {
    require_root
    systemctl --no-pager --full status "$SERVICE" || true
    printf '\nExecStart:\n'
    systemctl show "$SERVICE" --property=ExecStart --value 2>/dev/null || true
    printf '\nListening sockets:\n'
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep -E ':(31177|31178)([^0-9]|$)' || true
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bind)
            [ "$#" -ge 2 ] || die "--bind needs an IPv4 address"
            BIND_HOST="$2"
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || die "--port needs a number"
            WEB_PORT="$2"
            shift 2
            ;;
        --loopback)
            LOOPBACK=1
            shift
            ;;
        --restore)
            MODE="restore"
            shift
            ;;
        --status)
            MODE="status"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

case "$MODE" in
    lock) lock_web ;;
    restore) restore_web ;;
    status) show_status ;;
esac
