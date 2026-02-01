#!/bin/bash
#
# ╔═════════════════════════════════════════════════════════╗
# ║      🧅 TORWARE v1.0                                    ║
# ║                                                         ║
# ║  One-click setup for Tor Bridge/Relay nodes              ║
# ║                                                         ║
# ║  • Installs Docker (if needed)                           ║
# ║  • Runs Tor Bridge/Relay in Docker with live stats       ║
# ║  • Snowflake WebRTC proxy support                        ║
# ║  • Auto-start on boot via systemd/OpenRC/SysVinit       ║
# ║  • Easy management via CLI or interactive menu           ║
# ║                                                         ║
# ║  Tor Project: https://www.torproject.org/                ║
# ╚═════════════════════════════════════════════════════════╝
#
# Usage:
# curl -sL https://raw.githubusercontent.com/SamNet-dev/torware/main/torware.sh | sudo bash
#
# Tor relay types:
#   Bridge (obfs4) - Hidden entry point, helps censored users (DEFAULT)
#   Middle Relay   - Routes traffic within Tor network
#   Exit Relay     - Final hop, higher risk (advanced users only)
#

set -eo pipefail

# Ensure consistent numeric formatting across locales
export LC_NUMERIC=C

# Require bash 4+ (for associative arrays)
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "Error: This script requires bash 4+ (found $BASH_VERSION). Please upgrade bash."
    exit 1
fi

# Global temp file tracking for cleanup
_TMP_FILES=()
_cleanup_tmp() {
    for f in "${_TMP_FILES[@]}"; do
        rm -rf "$f" 2>/dev/null || true
    done
    # Clean caches and CPU state for THIS process
    rm -f "${TMPDIR:-/tmp}"/torware_cpu_state_$$ 2>/dev/null || true
    rm -f "${TMPDIR:-/tmp}"/.tg_curl.* 2>/dev/null || true
    rm -f "${TMPDIR:-/tmp}"/.tor_fp_cache_* 2>/dev/null || true
    rm -f "${TMPDIR:-/tmp}"/.tor_cookie_cache_* 2>/dev/null || true
}
trap '_cleanup_tmp' EXIT

VERSION="1.0"
# Docker image tags — using :latest for auto-updates. Pin to a specific tag for reproducibility.
BRIDGE_IMAGE="thetorproject/obfs4-bridge:latest"
RELAY_IMAGE="osminogin/tor-simple:latest"
SNOWFLAKE_IMAGE="thetorproject/snowflake-proxy:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/torware}"

# Validate INSTALL_DIR is absolute
case "$INSTALL_DIR" in
    /*) ;; # OK
    *) echo "Error: INSTALL_DIR must be an absolute path"; exit 1 ;;
esac

BACKUP_DIR="$INSTALL_DIR/backups"
STATS_DIR="$INSTALL_DIR/relay_stats"
CONTAINERS_DIR="$INSTALL_DIR/containers"
FORCE_REINSTALL=false

# Defaults
RELAY_TYPE="bridge"
NICKNAME=""
CONTACT_INFO=""
BANDWIDTH=5           # Mbps
CONTAINER_COUNT=1
ORPORT_BASE=9001
CONTROLPORT_BASE=9051
PT_PORT_BASE=9100
DATA_CAP_GB=0

# Snowflake proxy settings
SNOWFLAKE_ENABLED="false"
SNOWFLAKE_CONTAINER="snowflake-proxy"
SNOWFLAKE_VOLUME="snowflake-data"
SNOWFLAKE_METRICS_PORT=9999
SNOWFLAKE_PORT_RANGE="30000:60000"
SNOWFLAKE_CPUS="1.5"
SNOWFLAKE_MEMORY="512m"

# Colors — disable when stdout is not a terminal
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    local W=57
    local bar="═════════════════════════════════════════════════════════"
    echo -e "${CYAN}"
    echo "╔${bar}╗"
    # 🧅 emoji = 2 display cols but 1 char; "  🧅 " = 5 display cols, printf sees 4 → use W-5+1=53
    printf "║  🧅 %-52s║\n" "TORWARE v${VERSION}"
    echo "╠${bar}╣"
    # — is 1 display col, 1 char; normal printf works. Content: 2+53+2=57
    printf "║  %-57s║\n" "Tor Bridge/Relay nodes — easy setup & management"
    echo "╚${bar}╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

format_bytes() {
    local bytes=$1
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -lt 1024 ] 2>/dev/null; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}') KB"
    elif [ "$bytes" -lt 1073741824 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}') MB"
    else
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}') GB"
    fi
}

format_number() {
    local num=$1
    if [ -z "$num" ] || [ "$num" = "0" ]; then
        echo "0"
        return
    fi
    if [ "$num" -ge 1000000 ] 2>/dev/null; then
        echo "$(awk -v n="$num" 'BEGIN {printf "%.1f", n/1000000}')M"
    elif [ "$num" -ge 1000 ] 2>/dev/null; then
        echo "$(awk -v n="$num" 'BEGIN {printf "%.1f", n/1000}')K"
    else
        echo "$num"
    fi
}

format_duration() {
    local secs=$1
    [[ "$secs" =~ ^-?[0-9]+$ ]] || secs=0
    if [ "$secs" -lt 1 ]; then
        echo "0s"
        return
    fi
    local days=$((secs / 86400))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    local remaining=$((secs % 60))
    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${mins}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${mins}m"
    elif [ "$mins" -gt 0 ]; then
        echo "${mins}m"
    else
        echo "${remaining}s"
    fi
}

escape_md() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

# Convert 2-letter country code to human-readable name
country_code_to_name() {
    local cc="$1"
    case "$cc" in
        # Americas (18)
        us) echo "United States" ;; ca) echo "Canada" ;; mx) echo "Mexico" ;;
        br) echo "Brazil" ;; ar) echo "Argentina" ;; co) echo "Colombia" ;;
        cl) echo "Chile" ;; pe) echo "Peru" ;; ve) echo "Venezuela" ;;
        ec) echo "Ecuador" ;; bo) echo "Bolivia" ;; py) echo "Paraguay" ;;
        uy) echo "Uruguay" ;; cu) echo "Cuba" ;; cr) echo "Costa Rica" ;;
        pa) echo "Panama" ;; do) echo "Dominican Rep." ;; gt) echo "Guatemala" ;;
        # Europe West (16)
        gb|uk) echo "United Kingdom" ;; de) echo "Germany" ;; fr) echo "France" ;;
        nl) echo "Netherlands" ;; be) echo "Belgium" ;; at) echo "Austria" ;;
        ch) echo "Switzerland" ;; ie) echo "Ireland" ;; lu) echo "Luxembourg" ;;
        es) echo "Spain" ;; pt) echo "Portugal" ;; it) echo "Italy" ;;
        gr) echo "Greece" ;; mt) echo "Malta" ;; cy) echo "Cyprus" ;;
        is) echo "Iceland" ;;
        # Europe North (7)
        se) echo "Sweden" ;; no) echo "Norway" ;; fi) echo "Finland" ;;
        dk) echo "Denmark" ;; ee) echo "Estonia" ;; lv) echo "Latvia" ;;
        lt) echo "Lithuania" ;;
        # Europe East (16)
        pl) echo "Poland" ;; cz) echo "Czech Rep." ;; sk) echo "Slovakia" ;;
        hu) echo "Hungary" ;; ro) echo "Romania" ;; bg) echo "Bulgaria" ;;
        hr) echo "Croatia" ;; rs) echo "Serbia" ;; si) echo "Slovenia" ;;
        ba) echo "Bosnia" ;; mk) echo "N. Macedonia" ;; al) echo "Albania" ;;
        me) echo "Montenegro" ;; ua) echo "Ukraine" ;; md) echo "Moldova" ;;
        by) echo "Belarus" ;;
        # Russia & Central Asia (6)
        ru) echo "Russia" ;; kz) echo "Kazakhstan" ;; uz) echo "Uzbekistan" ;;
        tm) echo "Turkmenistan" ;; kg) echo "Kyrgyzstan" ;; tj) echo "Tajikistan" ;;
        # Middle East (10)
        tr) echo "Turkey" ;; il) echo "Israel" ;; sa) echo "Saudi Arabia" ;;
        ae) echo "UAE" ;; ir) echo "Iran" ;; iq) echo "Iraq" ;;
        sy) echo "Syria" ;; jo) echo "Jordan" ;; lb) echo "Lebanon" ;;
        qa) echo "Qatar" ;;
        # Africa (12)
        za) echo "South Africa" ;; ng) echo "Nigeria" ;; ke) echo "Kenya" ;;
        eg) echo "Egypt" ;; ma) echo "Morocco" ;; tn) echo "Tunisia" ;;
        gh) echo "Ghana" ;; et) echo "Ethiopia" ;; tz) echo "Tanzania" ;;
        ug) echo "Uganda" ;; dz) echo "Algeria" ;; ly) echo "Libya" ;;
        # Asia East (8)
        cn) echo "China" ;; jp) echo "Japan" ;; kr) echo "South Korea" ;;
        tw) echo "Taiwan" ;; hk) echo "Hong Kong" ;; mn) echo "Mongolia" ;;
        kp) echo "North Korea" ;; mo) echo "Macau" ;;
        # Asia South & Southeast (14)
        in) echo "India" ;; pk) echo "Pakistan" ;; bd) echo "Bangladesh" ;;
        np) echo "Nepal" ;; lk) echo "Sri Lanka" ;; mm) echo "Myanmar" ;;
        th) echo "Thailand" ;; vn) echo "Vietnam" ;; ph) echo "Philippines" ;;
        id) echo "Indonesia" ;; my) echo "Malaysia" ;; sg) echo "Singapore" ;;
        kh) echo "Cambodia" ;; la) echo "Laos" ;;
        # Oceania & Caucasus (6)
        au) echo "Australia" ;; nz) echo "New Zealand" ;; ge) echo "Georgia" ;;
        am) echo "Armenia" ;; az) echo "Azerbaijan" ;; bh) echo "Bahrain" ;;
        mu) echo "Mauritius" ;; zm) echo "Zambia" ;; sd) echo "Sudan" ;;
        zw) echo "Zimbabwe" ;; mz) echo "Mozambique" ;; cm) echo "Cameroon" ;;
        ci) echo "Ivory Coast" ;; sn) echo "Senegal" ;; cd) echo "DR Congo" ;;
        ao) echo "Angola" ;; om) echo "Oman" ;; kw) echo "Kuwait" ;;
        '??') echo "Unknown" ;;
        *) echo "$cc" | tr '[:lower:]' '[:upper:]' ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# OS Detection & Package Management
#═══════════════════════════════════════════════════════════════════════

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"

    if [ -f /etc/os-release ] && [ -r /etc/os-release ]; then
        # Read only the specific vars we need (avoid executing arbitrary content)
        OS=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)
        OS_VERSION=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -1)
        OS="${OS:-unknown}"
        OS_VERSION="${OS_VERSION:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"

    if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Podman detected. This script is optimized for Docker."
        log_warn "If installation fails, consider installing 'docker-ce' manually."
    fi
}

install_package() {
    local package="$1"
    log_info "Installing $package..."

    case "$PKG_MANAGER" in
        apt)
            apt-get update -q || log_warn "apt-get update failed, attempting install anyway..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -S --noconfirm --needed "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi

    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi

    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk || log_warn "Could not install gawk" ;;
            apk) install_package gawk || log_warn "Could not install gawk" ;;
            *) install_package awk || log_warn "Could not install awk" ;;
        esac
    fi

    if ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps || log_warn "Could not install procps" ;;
            pacman) install_package procps-ng || log_warn "Could not install procps" ;;
            zypper) install_package procps || log_warn "Could not install procps" ;;
            apk) install_package procps || log_warn "Could not install procps" ;;
        esac
    fi

    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    # netcat for ControlPort communication
    if ! command -v nc &>/dev/null && ! command -v ncat &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package netcat-openbsd || log_warn "Could not install netcat" ;;
            dnf|yum) install_package nmap-ncat || log_warn "Could not install ncat" ;;
            pacman) install_package openbsd-netcat || log_warn "Could not install netcat" ;;
            zypper) install_package netcat-openbsd || log_warn "Could not install netcat" ;;
            apk) install_package netcat-openbsd || log_warn "Could not install netcat" ;;
        esac
    fi

    # GeoIP (for country stats on middle/exit relays — bridges use Tor's built-in CLIENTS_SEEN)
    # Only needed if user runs non-bridge relay types
    if ! command -v geoiplookup &>/dev/null && ! command -v mmdblookup &>/dev/null; then
        log_info "GeoIP tools not found (optional — needed for middle/exit relay country stats)"
        log_info "Bridges use Tor's built-in country data and don't need GeoIP."
        case "$PKG_MANAGER" in
            apt)
                install_package geoip-bin 2>/dev/null || true
                install_package geoip-database 2>/dev/null || true
                ;;
            dnf|yum)
                install_package GeoIP 2>/dev/null || true
                ;;
            pacman) install_package geoip 2>/dev/null || true ;;
            zypper) install_package GeoIP 2>/dev/null || true ;;
            apk) install_package geoip 2>/dev/null || true ;;
            *) true ;;
        esac
    fi

    # qrencode is optional — only useful for bridge line QR codes
    if ! command -v qrencode &>/dev/null; then
        install_package qrencode 2>/dev/null || log_info "qrencode not installed (optional — for bridge line QR codes)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# System Resource Detection
#═══════════════════════════════════════════════════════════════════════

get_ram_mb() {
    local ram=""
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    if [ -z "$ram" ] || [ "$ram" -lt 1 ] 2>/dev/null; then
        echo 1  # Fallback: 1MB (prevents division-by-zero in callers)
    else
        echo "$ram"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

get_net_speed() {
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [ -z "$iface" ]; then
        echo "0.00 0.00"
        return
    fi

    local rx1 tx1 rx2 tx2
    rx1=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
    sleep 0.5
    rx2=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)

    local rx_speed tx_speed
    rx_speed=$(awk -v r1="$rx1" -v r2="$rx2" 'BEGIN {printf "%.2f", (r2 - r1) * 2 * 8 / 1000000}')
    tx_speed=$(awk -v t1="$tx1" -v t2="$tx2" 'BEGIN {printf "%.2f", (t2 - t1) * 2 * 8 / 1000000}')

    echo "$rx_speed $tx_speed"
}

#═══════════════════════════════════════════════════════════════════════
# Docker Installation
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi

    log_info "Installing Docker..."

    if [ "$OS_FAMILY" = "rhel" ]; then
        log_info "Adding Docker repo for RHEL..."
        if command -v dnf &>/dev/null; then
            dnf install -y -q dnf-plugins-core 2>/dev/null || true
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        else
            yum install -y -q yum-utils 2>/dev/null || true
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        fi
    fi

    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! apk add --no-cache docker docker-cli-compose 2>/dev/null; then
            log_error "Failed to install Docker on Alpine"
            return 1
        fi
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        # Download Docker install script first, then execute (safer than piping curl|sh)
        local docker_script
        docker_script=$(mktemp) || { log_error "Failed to create temp file"; return 1; }
        if ! curl -fsSL https://get.docker.com -o "$docker_script"; then
            rm -f "$docker_script"
            log_error "Failed to download Docker installation script."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        if ! sh "$docker_script"; then
            rm -f "$docker_script"
            log_error "Official Docker installation script failed."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        rm -f "$docker_script"

        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            if command -v update-rc.d &>/dev/null; then
                update-rc.d docker defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig docker on 2>/dev/null || true
            elif command -v rc-update &>/dev/null; then
                rc-update add docker default 2>/dev/null || true
            fi
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi

    sleep 3
    local retries=27
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done

    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Container Naming & Configuration Helpers
#═══════════════════════════════════════════════════════════════════════

get_container_name() {
    local idx=$1
    if [ "$idx" -le 1 ] 2>/dev/null; then
        echo "torware"
    else
        echo "torware-${idx}"
    fi
}

get_volume_name() {
    local idx=$1
    echo "relay-data-${idx}"
}

get_container_orport() {
    local idx=$1
    local var="ORPORT_${idx}"
    local val="${!var}"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo $((ORPORT_BASE + idx - 1))
    fi
}

get_container_controlport() {
    local idx=$1
    echo $((CONTROLPORT_BASE + idx - 1))
}

get_container_ptport() {
    local idx=$1
    local var="PT_PORT_${idx}"
    local val="${!var}"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo $((PT_PORT_BASE + idx - 1))
    fi
}

get_container_bandwidth() {
    local idx=$1
    local var="BANDWIDTH_${idx}"
    local val="${!var}"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$BANDWIDTH"
    fi
}

get_container_cpus() {
    local idx=$1
    local var="CPUS_${idx}"
    echo "${!var}"
}

get_container_memory() {
    local idx=$1
    local var="MEMORY_${idx}"
    echo "${!var}"
}

get_container_relay_type() {
    local idx=$1
    local var="RELAY_TYPE_${idx}"
    local val="${!var}"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$RELAY_TYPE"
    fi
}

get_container_nickname() {
    local idx=$1
    if [ "$idx" -le 1 ] 2>/dev/null; then
        echo "$NICKNAME"
    else
        echo "${NICKNAME}${idx}"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Torrc Generation
#═══════════════════════════════════════════════════════════════════════

generate_torrc() {
    local idx=$1
    local orport=$(get_container_orport $idx)
    local controlport=$(get_container_controlport $idx)
    local ptport=$(get_container_ptport $idx)
    local bw=$(get_container_bandwidth $idx)
    local nick=$(get_container_nickname $idx)
    local torrc_dir="$CONTAINERS_DIR/relay-${idx}"

    mkdir -p "$torrc_dir"

    # Sanitize contact info for torrc (strip quotes that could break the directive)
    local safe_contact
    safe_contact=$(printf '%s' "$CONTACT_INFO" | tr -d '\042\134')

    # Convert bandwidth from Mbps to bytes/sec for torrc
    local bw_bytes=""
    local bw_burst=""
    if [ "$bw" != "-1" ] && [ -n "$bw" ]; then
        # BandwidthRate in bytes per second (Mbps * 125000 = bytes/sec)
        bw_bytes=$(awk -v b="$bw" 'BEGIN {printf "%.0f", b * 125000}')
        # Burst = 2x rate
        bw_burst=$(awk -v b="$bw" 'BEGIN {printf "%.0f", b * 250000}')
    fi

    local torrc_file="$torrc_dir/torrc"

    cat > "$torrc_file" << EOF
# Torware Configuration - Generated by torware.sh v${VERSION}
# Container: $(get_container_name $idx)
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

# Identity
Nickname ${nick}
ContactInfo "${safe_contact}"

# Network Ports
ORPort ${orport}
ControlPort 127.0.0.1:${controlport}

# Authentication
CookieAuthentication 1

# Data directory
DataDirectory /var/lib/tor
EOF

    # Relay-type specific configuration
    local rtype=$(get_container_relay_type $idx)
    case "$rtype" in
        bridge)
            cat >> "$torrc_file" << EOF

# Bridge Configuration (obfs4)
BridgeRelay 1
ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:${ptport}
ExtORPort auto
PublishServerDescriptor bridge
EOF
            ;;
        middle)
            cat >> "$torrc_file" << EOF

# Middle Relay Configuration
ExitRelay 0
ExitPolicy reject *:*
ExitPolicy reject6 *:*
PublishServerDescriptor v3
EOF
            ;;
        exit)
            cat >> "$torrc_file" << EOF

# Exit Relay Configuration
$(generate_exit_policy)
PublishServerDescriptor v3
EOF
            ;;
    esac

    # Bandwidth limits
    if [ -n "$bw_bytes" ]; then
        cat >> "$torrc_file" << EOF

# Bandwidth Limits
BandwidthRate ${bw_bytes}
BandwidthBurst ${bw_burst}
RelayBandwidthRate ${bw_bytes}
RelayBandwidthBurst ${bw_burst}
EOF
    fi

    # Data cap / accounting
    if [ "${DATA_CAP_GB}" -gt 0 ] 2>/dev/null; then
        cat >> "$torrc_file" << EOF

# Traffic Accounting
AccountingMax ${DATA_CAP_GB} GB
AccountingStart month 1 00:00
EOF
    fi

    # Logging
    cat >> "$torrc_file" << EOF

# Logging
Log notice stdout
EOF

    chmod 644 "$torrc_file"
}

generate_exit_policy() {
    case "${EXIT_POLICY:-reduced}" in
        reduced)
            cat << 'EOF'
# Reduced Exit Policy (web traffic only)
ExitPolicy accept *:80
ExitPolicy accept *:443
ExitPolicy reject *:*
ExitPolicy reject6 *:*
EOF
            ;;
        default)
            cat << 'EOF'
# Default Exit Policy (common ports)
ExitPolicy accept *:20-23
ExitPolicy accept *:43
ExitPolicy accept *:53
ExitPolicy accept *:79-81
ExitPolicy accept *:88
ExitPolicy accept *:110
ExitPolicy accept *:143
ExitPolicy accept *:194
ExitPolicy accept *:220
ExitPolicy accept *:389
ExitPolicy accept *:443
ExitPolicy accept *:465
ExitPolicy accept *:531
ExitPolicy accept *:543-544
ExitPolicy accept *:554
ExitPolicy accept *:563
ExitPolicy accept *:587
ExitPolicy accept *:636
ExitPolicy accept *:706
ExitPolicy accept *:749
ExitPolicy accept *:873
ExitPolicy accept *:902-904
ExitPolicy accept *:981
ExitPolicy accept *:989-995
ExitPolicy accept *:1194
ExitPolicy accept *:1220
ExitPolicy accept *:1293
ExitPolicy accept *:1500
ExitPolicy accept *:1533
ExitPolicy accept *:1677
ExitPolicy accept *:1723
ExitPolicy accept *:1755
ExitPolicy accept *:1863
ExitPolicy accept *:2082-2083
ExitPolicy accept *:2086-2087
ExitPolicy accept *:2095-2096
ExitPolicy accept *:2102-2104
ExitPolicy accept *:3128
ExitPolicy accept *:3389
ExitPolicy accept *:3690
ExitPolicy accept *:4321
ExitPolicy accept *:4643
ExitPolicy accept *:5050
ExitPolicy accept *:5190
ExitPolicy accept *:5222-5223
ExitPolicy accept *:5228
ExitPolicy accept *:5900
ExitPolicy accept *:6660-6669
ExitPolicy accept *:6679
ExitPolicy accept *:6697
ExitPolicy accept *:8000
ExitPolicy accept *:8008
ExitPolicy accept *:8074
ExitPolicy accept *:8080
ExitPolicy accept *:8082
ExitPolicy accept *:8087-8088
ExitPolicy accept *:8232-8233
ExitPolicy accept *:8332-8333
ExitPolicy accept *:8443
ExitPolicy accept *:8888
ExitPolicy accept *:9418
ExitPolicy accept *:11371
ExitPolicy accept *:19294
ExitPolicy accept *:19638
ExitPolicy accept *:50002
ExitPolicy accept *:64738
ExitPolicy reject *:*
ExitPolicy reject6 *:*
EOF
            ;;
        full)
            cat << 'EOF'
# Full Exit Policy (all ports - HIGHEST RISK)
ExitPolicy accept *:*
ExitPolicy accept6 *:*
EOF
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# ControlPort Communication
#═══════════════════════════════════════════════════════════════════════

# Get the netcat command available on this system
get_nc_cmd() {
    if command -v ncat &>/dev/null; then
        echo "ncat"
    elif command -v nc &>/dev/null; then
        echo "nc"
    else
        echo ""
    fi
}

# Read cookie from Docker volume and convert to hex (cached for 60s)
get_control_cookie() {
    local idx=$1
    local vol=$(get_volume_name $idx)
    local cache_file="${TMPDIR:-/tmp}/.tor_cookie_cache_${idx}"

    # Symlink protection
    [ -L "$cache_file" ] && rm -f "$cache_file"

    # Use cache if fresh (avoid spawning Docker container every call)
    if [ -f "$cache_file" ]; then
        local mtime
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt 60 ] && [ "$age" -ge 0 ]; then
            cat "$cache_file"
            return
        fi
    fi

    local cookie
    cookie=$(docker run --rm -v "${vol}:/data:ro" alpine \
        sh -c 'od -A n -t x1 /data/control_auth_cookie 2>/dev/null | tr -d " \n"' 2>/dev/null)

    if [ -n "$cookie" ]; then
        ( umask 077; echo "$cookie" > "$cache_file" )
    fi
    echo "$cookie"
}

# Query ControlPort with authentication
controlport_query() {
    local port=$1
    shift
    local nc_cmd=$(get_nc_cmd)

    if [ -z "$nc_cmd" ]; then
        return 1
    fi

    # Build the query: authenticate, run commands, quit
    local idx=$((port - CONTROLPORT_BASE + 1))
    local cookie=$(get_control_cookie $idx)

    if [ -z "$cookie" ]; then
        return 1
    fi

    {
        printf 'AUTHENTICATE %s\r\n' "$cookie"
        for cmd in "$@"; do
            printf "%s\r\n" "$cmd"
        done
        printf "QUIT\r\n"
    } | timeout 5 "$nc_cmd" 127.0.0.1 "$port" 2>/dev/null | tr -d '\r'
}

# Get traffic bytes (read, written) from a container
get_tor_traffic() {
    local idx=$1
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" "GETINFO traffic/read" "GETINFO traffic/written" 2>/dev/null)

    local read_bytes write_bytes
    read_bytes=$(echo "$result" | sed -n 's/.*traffic\/read=\([0-9]*\).*/\1/p' | head -1 2>/dev/null || echo "0")
    write_bytes=$(echo "$result" | sed -n 's/.*traffic\/written=\([0-9]*\).*/\1/p' | head -1 2>/dev/null || echo "0")

    echo "$read_bytes $write_bytes"
}

# Get circuit count from a container
get_tor_circuits() {
    local idx=$1
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" "GETINFO circuit-status" 2>/dev/null)

    # Count lines that start with a circuit ID (number)
    local count
    count=$(echo "$result" | grep -cE '^[0-9]+ (BUILT|EXTENDED|LAUNCHED)' 2>/dev/null || echo "0")
    count=${count//[^0-9]/}
    echo "${count:-0}"
}

# Get OR connection count
get_tor_connections() {
    local idx=$1
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" "GETINFO orconn-status" 2>/dev/null)

    local count
    count=$(echo "$result" | grep -c '\$' 2>/dev/null || echo "0")
    count=${count//[^0-9]/}
    echo "${count:-0}"
}

# Get accounting info (data cap usage)
get_tor_accounting() {
    local idx=$1
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" \
        "GETINFO accounting/enabled" \
        "GETINFO accounting/bytes" \
        "GETINFO accounting/bytes-left" \
        "GETINFO accounting/interval-end" 2>/dev/null)
    echo "$result"
}

# Get relay fingerprint (cached for 300s to avoid spawning Docker container every call)
get_tor_fingerprint() {
    local idx=$1
    local cache_file="${TMPDIR:-/tmp}/.tor_fp_cache_${idx}"
    [ -L "$cache_file" ] && rm -f "$cache_file"
    if [ -f "$cache_file" ]; then
        local mtime
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt 300 ] && [ "$age" -ge 0 ]; then
            cat "$cache_file"
            return
        fi
    fi
    local vol=$(get_volume_name $idx)
    local fp
    fp=$(docker run --rm -v "${vol}:/data:ro" alpine \
        cat /data/fingerprint 2>/dev/null | awk '{print $2}')
    if [ -n "$fp" ]; then
        ( umask 077; echo "$fp" > "$cache_file" )
    fi
    echo "$fp"
}

# Cached external IP (avoids repeated curl calls)
_CACHED_EXTERNAL_IP=""
_get_external_ip() {
    if [ -z "$_CACHED_EXTERNAL_IP" ]; then
        _CACHED_EXTERNAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    fi
    echo "$_CACHED_EXTERNAL_IP"
}

# Get bridge line (for obfs4 bridges)
get_bridge_line() {
    local idx=$1
    local cname=$(get_container_name $idx)
    local raw
    raw=$(docker exec "$cname" cat /var/lib/tor/pt_state/obfs4_bridgeline.txt 2>/dev/null | grep -v '^#' | head -1)
    if [ -n "$raw" ]; then
        # Replace placeholders with real IP and port
        local ip
        ip=$(_get_external_ip)
        local orport=$(get_container_orport "$idx")
        if [ -n "$ip" ]; then
            raw="${raw/<IP ADDRESS>/$ip}"
            raw="${raw/<PORT>/$orport}"
        fi
        echo "$raw"
    fi
}

# Get bridge client country stats (bridges only — uses Tor's built-in CLIENTS_SEEN)
# Returns lines like: ir=50 cn=120 us=30
get_tor_clients_seen() {
    local idx=$1
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" "GETINFO status/clients-seen" 2>/dev/null)
    # Extract the CountrySummary field: cc=num,cc=num,...
    local countries
    countries=$(echo "$result" | sed -n 's/.*CountrySummary=\([^ \r]*\).*/\1/p' | head -1 2>/dev/null)
    echo "$countries"
}

# Resolve IP to country via Tor ControlPort
tor_geo_lookup() {
    local ip=$1
    # Validate IP format (IPv4 only)
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "??"
        return
    fi
    local idx=${2:-1}
    local port=$(get_container_controlport $idx)
    local result
    result=$(controlport_query "$port" "GETINFO ip-to-country/$ip" 2>/dev/null)
    local sed_safe_ip=$(printf '%s' "$ip" | sed 's/[.]/\\./g; s/[/]/\\//g')
    echo "$result" | sed -n "s/.*ip-to-country\/${sed_safe_ip}=\([^\r]*\)/\1/p" | head -1 || echo "??"
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup Wizard
#═══════════════════════════════════════════════════════════════════════

prompt_relay_settings() {
  while true; do
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                   TORWARE CONFIGURATION                     ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info:${NC}"
    echo -e "    CPU Cores: ${GREEN}${cpu_cores}${NC}"
    if [ "$ram_mb" -ge 1000 ]; then
        local ram_gb=$(awk -v m="$ram_mb" 'BEGIN {printf "%.1f", m/1024}')
        echo -e "    RAM: ${GREEN}${ram_gb} GB${NC}"
    else
        echo -e "    RAM: ${GREEN}${ram_mb} MB${NC}"
    fi
    echo ""

    # ── Suggested Setup Modes ──
    echo -e "  ${BOLD}Choose a Setup Mode:${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}  1. Single Bridge${NC} (${BOLD}RECOMMENDED${NC})"
    echo -e "       1 obfs4 bridge container — ideal for most users"
    echo -e "       Helps censored users connect to Tor"
    echo -e "       Your IP stays PRIVATE (not publicly listed)"
    echo -e "       Zero legal risk, zero abuse complaints"
    echo ""
    echo -e "  ${GREEN}  2. Multi-Bridge${NC}"
    echo -e "       2-5 bridge containers on the same IP"
    echo -e "       Each bridge gets its own identity and ORPort"
    echo -e "       All bridges stay private — safe to run together"
    echo -e "       Best for servers with spare CPU/RAM"
    echo ""
    echo -e "  ${YELLOW}  3. Middle Relay${NC}"
    echo -e "       1 middle relay container — routes Tor traffic"
    echo -e "       Your IP WILL be publicly listed in the Tor consensus"
    echo -e "       No exit traffic, so lower risk than an exit relay"
    echo -e "       Helps increase Tor network capacity"
    echo ""
    echo -e "  ${DIM}  4. Custom${NC}"
    echo -e "       Choose relay type and container count manually"
    echo -e "       Includes exit relay option (advanced, legal risks)"
    echo ""

    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Choose setup mode [1-4] (default: 1)"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  mode: " input_mode < /dev/tty || true

    case "${input_mode:-1}" in
        1|"")
            RELAY_TYPE="bridge"
            CONTAINER_COUNT=1
            echo -e "  Selected: ${GREEN}Single Bridge (obfs4)${NC}"
            ;;
        2)
            RELAY_TYPE="bridge"
            # Recommend container count based on resources
            local rec_multi=2
            if [ "$cpu_cores" -ge 4 ] && [ "$ram_mb" -ge 4096 ]; then
                rec_multi=3
            fi
            echo ""
            echo -e "  How many bridge containers? (2-5, default: ${rec_multi})"
            echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb}MB RAM${NC}"
            read -p "  bridges: " input_multi < /dev/tty || true
            if [ -z "$input_multi" ]; then
                CONTAINER_COUNT=$rec_multi
            elif [[ "$input_multi" =~ ^[2-5]$ ]]; then
                CONTAINER_COUNT=$input_multi
            else
                log_warn "Invalid input. Using default: ${rec_multi}"
                CONTAINER_COUNT=$rec_multi
            fi
            echo -e "  Selected: ${GREEN}${CONTAINER_COUNT}x Bridge (obfs4)${NC}"
            ;;
        3)
            RELAY_TYPE="middle"
            CONTAINER_COUNT=1
            echo -e "  Selected: ${YELLOW}Middle Relay${NC}"
            echo ""
            echo -e "  ${DIM}Note: Your IP will be publicly listed in the Tor consensus.${NC}"
            echo -e "  ${DIM}This is normal for middle relays and poses low risk.${NC}"
            ;;
        4)
            local _custom_needs_count=true
            # ── Custom: Relay Type ──
            echo ""
            echo -e "  ${BOLD}Relay Type:${NC}"
            echo -e "    ${GREEN}1. Bridge (obfs4)${NC} — IP stays private, helps censored users"
            echo -e "    ${YELLOW}2. Middle Relay${NC}   — IP is public, routes Tor traffic"
            echo -e "    ${RED}3. Exit Relay${NC}     — ADVANCED: IP is public, receives abuse complaints"
            echo ""
            read -p "  relay type [1-3] (default: 1): " input_type < /dev/tty || true

            case "${input_type:-1}" in
                1|"")
                    RELAY_TYPE="bridge"
                    echo -e "  Selected: ${GREEN}Bridge (obfs4)${NC}"
                    ;;
                2)
                    RELAY_TYPE="middle"
                    echo -e "  Selected: ${YELLOW}Middle Relay${NC}"
                    ;;
                3)
                    echo ""
                    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
                    echo -e "${RED}║  EXIT RELAY — LEGAL WARNING                                      ║${NC}"
                    echo -e "${RED}╠═══════════════════════════════════════════════════════════════════╣${NC}"
                    echo -e "${RED}║                                                                   ║${NC}"
                    echo -e "${RED}║  Running an exit relay means:                                     ║${NC}"
                    echo -e "${RED}║                                                                   ║${NC}"
                    echo -e "${RED}║  • Your IP will be publicly listed as a Tor exit                  ║${NC}"
                    echo -e "${RED}║  • Abuse complaints may be sent to your ISP                       ║${NC}"
                    echo -e "${RED}║  • Some services may block your IP                                ║${NC}"
                    echo -e "${RED}║  • You may receive DMCA notices or legal requests                 ║${NC}"
                    echo -e "${RED}║                                                                   ║${NC}"
                    echo -e "${RED}║  Learn more:                                                      ║${NC}"
                    echo -e "${RED}║  https://community.torproject.org/relay/community-resources/      ║${NC}"
                    echo -e "${RED}║                                                                   ║${NC}"
                    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
                    echo ""
                    read -p "  Type 'I UNDERSTAND' to continue, or press Enter for Bridge: " confirm_exit < /dev/tty || true
                    if [ "$confirm_exit" = "I UNDERSTAND" ]; then
                        RELAY_TYPE="exit"
                        echo -e "  Selected: ${RED}Exit Relay${NC}"
                        echo ""
                        echo -e "  ${BOLD}Exit Policy:${NC}"
                        echo -e "    ${GREEN}a. Reduced${NC} (ports 80, 443 only) - ${BOLD}RECOMMENDED${NC}"
                        echo -e "    ${YELLOW}b. Default${NC} (common ports)"
                        echo -e "    ${RED}c. Full${NC} (all ports) - HIGHEST RISK"
                        echo ""
                        read -p "  Exit policy [a/b/c] (default: a): " ep_choice < /dev/tty || true
                        case "${ep_choice:-a}" in
                            b) EXIT_POLICY="default" ;;
                            c) EXIT_POLICY="full" ;;
                            *) EXIT_POLICY="reduced" ;;
                        esac
                    else
                        RELAY_TYPE="bridge"
                        echo -e "  Defaulting to: ${GREEN}Bridge (obfs4)${NC}"
                    fi
                    ;;
                *)
                    RELAY_TYPE="bridge"
                    echo -e "  Invalid input. Defaulting to: ${GREEN}Bridge (obfs4)${NC}"
                    ;;
            esac
            # Custom mode: skip to container count below (handled after this case)
            ;;
        *)
            RELAY_TYPE="bridge"
            CONTAINER_COUNT=1
            echo -e "  Invalid input. Defaulting to: ${GREEN}Single Bridge (obfs4)${NC}"
            ;;
    esac

    # ── Container Count (custom mode only — modes 1-3 already set CONTAINER_COUNT) ──
    if [ "${input_mode:-1}" = "4" ] && [ "${_custom_needs_count:-false}" = "true" ]; then
        CONTAINER_COUNT=""  # will be set below
        local rec_containers=1
        if [ "$cpu_cores" -ge 4 ] && [ "$ram_mb" -ge 4096 ]; then
            rec_containers=2
        fi

        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  How many containers to run? (1-5)"
        echo -e "  Each gets a unique ORPort and identity"
        echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb}MB RAM${NC}"
        echo -e "  Press Enter for default: ${GREEN}${rec_containers}${NC}"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  containers: " input_containers < /dev/tty || true

        if [ -z "$input_containers" ]; then
            CONTAINER_COUNT=$rec_containers
        elif [[ "$input_containers" =~ ^[1-5]$ ]]; then
            CONTAINER_COUNT=$input_containers
        else
            log_warn "Invalid input. Using default: ${rec_containers}"
            CONTAINER_COUNT=$rec_containers
        fi
    fi

    # ── Per-Container Relay Type (custom mode, multiple containers) ──
    if [ "${input_mode:-1}" = "4" ] && [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Use the same relay type (${GREEN}${RELAY_TYPE}${NC}) for all containers?"
        echo -e "  Selecting 'n' lets you assign different types per container"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  Same type for all? [Y/n] " same_type < /dev/tty || true

        if [[ "$same_type" =~ ^[Nn]$ ]]; then
            echo ""
            for ci in $(seq 1 $CONTAINER_COUNT); do
                echo -e "  ${BOLD}Container $ci:${NC} [1=Bridge, 2=Middle, 3=Exit] (default: 1)"
                read -p "    type: " ct_choice < /dev/tty || true
                case "${ct_choice:-1}" in
                    2)
                        printf -v "RELAY_TYPE_${ci}" '%s' "middle"
                        echo -e "    -> ${YELLOW}Middle Relay${NC}"
                        ;;
                    3)
                        printf -v "RELAY_TYPE_${ci}" '%s' "exit"
                        echo -e "    -> ${RED}Exit Relay${NC}"
                        ;;
                    *)
                        printf -v "RELAY_TYPE_${ci}" '%s' "bridge"
                        echo -e "    -> ${GREEN}Bridge${NC}"
                        ;;
                esac
            done

            # Check for mixed bridge + relay on same host (unsafe per Tor Project guidance)
            local _has_bridge=false _has_relay=false
            for ci in $(seq 1 $CONTAINER_COUNT); do
                local _crt=$(get_container_relay_type $ci)
                [ "$_crt" = "bridge" ] && _has_bridge=true || _has_relay=true
            done
            if [ "$_has_bridge" = "true" ] && [ "$_has_relay" = "true" ]; then
                echo ""
                echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
                echo -e "  ${RED}║  WARNING: Bridge + Relay on same IP is NOT recommended   ║${NC}"
                echo -e "  ${RED}╠══════════════════════════════════════════════════════════╣${NC}"
                echo -e "  ${RED}║${NC}  Bridges are UNLISTED — their IPs are kept private.      ${RED}║${NC}"
                echo -e "  ${RED}║${NC}  Middle relays are PUBLICLY LISTED in the Tor consensus. ${RED}║${NC}"
                echo -e "  ${RED}║${NC}                                                          ${RED}║${NC}"
                echo -e "  ${RED}║${NC}  Running both on the same IP exposes your bridge's IP    ${RED}║${NC}"
                echo -e "  ${RED}║${NC}  through the public relay listing, defeating the purpose  ${RED}║${NC}"
                echo -e "  ${RED}║${NC}  of running a bridge.                                    ${RED}║${NC}"
                echo -e "  ${RED}║${NC}                                                          ${RED}║${NC}"
                echo -e "  ${RED}║${NC}  Safe combos: all bridges OR all middle relays.           ${RED}║${NC}"
                echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
                echo ""
                read -p "  Continue anyway? [y/N] " _mix_confirm < /dev/tty || true
                if [[ ! "$_mix_confirm" =~ ^[Yy]$ ]]; then
                    echo -e "  Resetting all containers to ${GREEN}${RELAY_TYPE}${NC}"
                    for ci in $(seq 1 $CONTAINER_COUNT); do
                        printf -v "RELAY_TYPE_${ci}" '%s' "$RELAY_TYPE"
                    done
                fi
            fi
        fi
    fi

    echo ""

    # ── Nickname ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter a nickname for your relay (1-19 chars, alphanumeric)"
    echo -e "  Press Enter for default: ${GREEN}Torware${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  nickname: " input_nick < /dev/tty || true

    if [ -z "$input_nick" ]; then
        NICKNAME="Torware"
    elif [[ "$input_nick" =~ ^[A-Za-z0-9]{1,19}$ ]]; then
        NICKNAME="$input_nick"
    else
        log_warn "Invalid nickname (must be 1-19 alphanumeric chars). Using default."
        NICKNAME="Torware"
    fi

    echo ""

    # ── Contact Info ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter contact email (shown to Tor Project, not public)"
    echo -e "  Press Enter to skip"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  email: " input_email < /dev/tty || true
    CONTACT_INFO="${input_email:-nobody@example.com}"

    echo ""

    # ── Bandwidth ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth?"
    echo -e "  ${YELLOW}Note: For relays, Tor recommends at least 2 Mbps.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy]$ ]]; then
        BANDWIDTH="-1"
        echo -e "  Selected: ${GREEN}Unlimited${NC}"
    else
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Enter bandwidth in Mbps (1-100)"
        echo -e "  Press Enter for default: ${GREEN}5${NC} Mbps"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  bandwidth: " input_bandwidth < /dev/tty || true

        if [ -z "$input_bandwidth" ]; then
            BANDWIDTH=5
        elif [[ "$input_bandwidth" =~ ^[0-9]+$ ]] && [ "$input_bandwidth" -ge 1 ] && [ "$input_bandwidth" -le 100 ]; then
            BANDWIDTH=$input_bandwidth
        elif [[ "$input_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$input_bandwidth" 'BEGIN { print (val >= 1 && val <= 100) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$input_bandwidth
            else
                log_warn "Invalid input. Using default: 5 Mbps"
                BANDWIDTH=5
            fi
        else
            log_warn "Invalid input. Using default: 5 Mbps"
            BANDWIDTH=5
        fi
    fi

    echo ""

    # ── Data Cap ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Set a monthly data cap? (in GB, 0 = unlimited)"
    echo -e "  Tor will automatically hibernate when cap is reached."
    echo -e "  Press Enter for default: ${GREEN}0${NC} (unlimited)"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  data cap (GB): " input_cap < /dev/tty || true

    if [ -z "$input_cap" ] || [ "$input_cap" = "0" ]; then
        DATA_CAP_GB=0
    elif [[ "$input_cap" =~ ^[0-9]+$ ]] && [ "$input_cap" -ge 1 ]; then
        DATA_CAP_GB=$input_cap
    else
        log_warn "Invalid input. Using unlimited."
        DATA_CAP_GB=0
    fi

    echo ""

    # ── Snowflake Proxy ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Snowflake Proxy${NC} (${GREEN}RECOMMENDED${NC})"
    echo -e "  Runs a lightweight WebRTC proxy alongside your relay."
    echo -e "  Helps censored users connect to Tor (looks like a video call)."
    echo -e "  Uses ~10-30MB RAM, negligible CPU. No extra config needed."
    echo -e "  ${DIM}Learn more: https://snowflake.torproject.org/${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Enable Snowflake proxy? [Y/n] " input_sf < /dev/tty || true
    if [[ "$input_sf" =~ ^[Nn]$ ]]; then
        SNOWFLAKE_ENABLED="false"
        echo -e "  Snowflake: ${DIM}Disabled${NC}"
    else
        SNOWFLAKE_ENABLED="true"
        echo -e "  Snowflake: ${GREEN}Enabled${NC}"
    fi

    echo ""

    # ── Summary ──
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    # Show per-container types if mixed
    local has_mixed=false
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        for _ci in $(seq 1 $CONTAINER_COUNT); do
            local _rt=$(get_container_relay_type $_ci)
            [ "$_rt" != "$RELAY_TYPE" ] && has_mixed=true
        done
    fi
    if [ "$has_mixed" = "true" ]; then
        echo -e "    Relay Types:"
        for _ci in $(seq 1 $CONTAINER_COUNT); do
            echo -e "      Container $_ci: ${GREEN}$(get_container_relay_type $_ci)${NC}"
        done
    else
        echo -e "    Relay Type:  ${GREEN}${RELAY_TYPE}${NC}"
    fi
    echo -e "    Nickname:    ${GREEN}${NICKNAME}${NC}"
    echo -e "    Contact:     ${GREEN}${CONTACT_INFO}${NC}"
    if [ "$BANDWIDTH" = "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "    Containers:  ${GREEN}${CONTAINER_COUNT}${NC}"
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        echo -e "    Data Cap:    ${GREEN}${DATA_CAP_GB} GB/month${NC}"
    else
        echo -e "    Data Cap:    ${GREEN}Unlimited${NC}"
    fi
    echo -e "    ORPorts:     ${GREEN}${ORPORT_BASE}-$((ORPORT_BASE + CONTAINER_COUNT - 1))${NC}"
    # Show obfs4 ports only for bridge containers
    local _has_bridge=false
    for _ci in $(seq 1 $CONTAINER_COUNT); do
        [ "$(get_container_relay_type $_ci)" = "bridge" ] && _has_bridge=true
    done
    if [ "$_has_bridge" = "true" ]; then
        # Show only bridge container obfs4 ports
        local _bridge_ports=""
        for _ci in $(seq 1 $CONTAINER_COUNT); do
            if [ "$(get_container_relay_type $_ci)" = "bridge" ]; then
                local _pp=$(get_container_ptport $_ci)
                if [ -z "$_bridge_ports" ]; then _bridge_ports="$_pp"; else _bridge_ports="${_bridge_ports}, ${_pp}"; fi
            fi
        done
        echo -e "    obfs4 Ports: ${GREEN}${_bridge_ports}${NC}"
    fi
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo -e "    Snowflake:   ${GREEN}Enabled (WebRTC proxy, 0.5 CPU / 128MB)${NC}"
    fi
    # Show auto-calculated resource limits
    local _sys_cores=$(get_cpu_cores)
    local _sys_ram=$(get_ram_mb)
    local _per_cpu=$(awk -v c="$_sys_cores" -v n="$CONTAINER_COUNT" 'BEGIN {v=(c>1)?(c-1)/n:0.5; if(v<0.5)v=0.5; printf "%.1f",v}')
    local _per_ram=$(awk -v r="$_sys_ram" -v n="$CONTAINER_COUNT" 'BEGIN {v=(r-512)/n; if(v<256)v=256; if(v>2048)v=2048; printf "%.0f",v}')
    echo -e "    Resources:   ${GREEN}${_per_cpu} CPU / ${_per_ram}MB RAM${NC} per relay container"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""

    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        continue
    fi
    break
  done
}

#═══════════════════════════════════════════════════════════════════════
# Settings Management
#═══════════════════════════════════════════════════════════════════════

save_settings() {
    mkdir -p "$INSTALL_DIR"
    local _tmp
    _tmp=$(mktemp "$INSTALL_DIR/settings.conf.XXXXXX") || { log_error "Failed to create temp file"; return 1; }
    _TMP_FILES+=("$_tmp")

    # Preserve existing Telegram settings on reinstall
    # Capture current telegram globals BEFORE load_settings overwrites them
    local _caller_tg_token="${TELEGRAM_BOT_TOKEN:-}"
    local _caller_tg_chat="${TELEGRAM_CHAT_ID:-}"
    local _caller_tg_interval="${TELEGRAM_INTERVAL:-6}"
    local _caller_tg_enabled="${TELEGRAM_ENABLED:-false}"
    local _caller_tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
    local _caller_tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
    local _caller_tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
    local _caller_tg_label="${TELEGRAM_SERVER_LABEL:-}"
    local _caller_tg_start_hour="${TELEGRAM_START_HOUR:-0}"

    local _tg_token="" _tg_chat="" _tg_interval="6" _tg_enabled="false"
    local _tg_alerts="true" _tg_daily="true" _tg_weekly="true" _tg_label="" _tg_start_hour="0"
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        load_settings
        _tg_token="${TELEGRAM_BOT_TOKEN:-}"
        _tg_chat="${TELEGRAM_CHAT_ID:-}"
        _tg_interval="${TELEGRAM_INTERVAL:-6}"
        _tg_enabled="${TELEGRAM_ENABLED:-false}"
        _tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
        _tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
        _tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
        _tg_label="${TELEGRAM_SERVER_LABEL:-}"
        _tg_start_hour="${TELEGRAM_START_HOUR:-0}"
    fi

    # Always use caller's current globals — they reflect the user's latest action
    _tg_token="$_caller_tg_token"
    _tg_chat="$_caller_tg_chat"
    _tg_enabled="$_caller_tg_enabled"
    _tg_interval="$_caller_tg_interval"
    _tg_alerts="$_caller_tg_alerts"
    _tg_daily="$_caller_tg_daily"
    _tg_weekly="$_caller_tg_weekly"
    _tg_label="$_caller_tg_label"
    _tg_start_hour="$_caller_tg_start_hour"

    # Restore ALL telegram globals after load_settings clobbered them
    TELEGRAM_BOT_TOKEN="$_tg_token"
    TELEGRAM_CHAT_ID="$_tg_chat"
    TELEGRAM_ENABLED="$_tg_enabled"
    TELEGRAM_INTERVAL="$_tg_interval"
    TELEGRAM_ALERTS_ENABLED="$_tg_alerts"
    TELEGRAM_DAILY_SUMMARY="$_tg_daily"
    TELEGRAM_WEEKLY_SUMMARY="$_tg_weekly"
    TELEGRAM_SERVER_LABEL="$_tg_label"
    TELEGRAM_START_HOUR="$_tg_start_hour"

    # Sanitize values — strip characters that could break shell sourcing
    local _safe_contact
    _safe_contact=$(printf '%s' "$CONTACT_INFO" | tr -d '\047\042\140\044\134')
    local _safe_nickname
    _safe_nickname=$(printf '%s' "$NICKNAME" | tr -cd 'A-Za-z0-9')
    local _safe_tg_label
    _safe_tg_label=$(printf '%s' "$_tg_label" | tr -d '\047\042\140\044\134')
    local _safe_tg_token
    _safe_tg_token=$(printf '%s' "$_tg_token" | tr -cd 'A-Za-z0-9:_-')
    local _safe_tg_chat
    _safe_tg_chat=$(printf '%s' "$_tg_chat" | tr -cd 'A-Za-z0-9_-')

    cat > "$_tmp" << EOF
# Torware Settings - v${VERSION}
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

# Relay Configuration
RELAY_TYPE='${RELAY_TYPE}'
NICKNAME='${_safe_nickname}'
CONTACT_INFO='${_safe_contact}'
BANDWIDTH='${BANDWIDTH}'
CONTAINER_COUNT='${CONTAINER_COUNT:-1}'
ORPORT_BASE='${ORPORT_BASE}'
CONTROLPORT_BASE='${CONTROLPORT_BASE}'
PT_PORT_BASE='${PT_PORT_BASE}'
EXIT_POLICY='${EXIT_POLICY:-reduced}'
DATA_CAP_GB='${DATA_CAP_GB:-0}'

# Snowflake Proxy
SNOWFLAKE_ENABLED='${SNOWFLAKE_ENABLED:-false}'
SNOWFLAKE_PORT_RANGE='${SNOWFLAKE_PORT_RANGE:-30000:60000}'
SNOWFLAKE_CPUS='${SNOWFLAKE_CPUS:-1.0}'
SNOWFLAKE_MEMORY='${SNOWFLAKE_MEMORY:-256m}'

# Telegram Integration
TELEGRAM_BOT_TOKEN='${_safe_tg_token}'
TELEGRAM_CHAT_ID='${_safe_tg_chat}'
TELEGRAM_INTERVAL='${_tg_interval}'
TELEGRAM_ENABLED='${_tg_enabled}'
TELEGRAM_ALERTS_ENABLED='${_tg_alerts}'
TELEGRAM_DAILY_SUMMARY='${_tg_daily}'
TELEGRAM_WEEKLY_SUMMARY='${_tg_weekly}'
TELEGRAM_SERVER_LABEL='${_safe_tg_label}'
TELEGRAM_START_HOUR='${_tg_start_hour}'

# Docker Resource Limits (per-container overrides)
DOCKER_CPUS=''
DOCKER_MEMORY=''
EOF

    # Add per-container overrides (sanitize to strip quotes/shell metacharacters)
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local rt_var="RELAY_TYPE_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpus_var="CPUS_${i}"
        local mem_var="MEMORY_${i}"
        local orport_var="ORPORT_${i}"
        local ptport_var="PT_PORT_${i}"
        # Relay type: only allow known values
        if [ -n "${!rt_var}" ]; then
            local _srt="${!rt_var}"
            case "$_srt" in bridge|middle|exit) ;; *) _srt="bridge" ;; esac
            echo "${rt_var}='${_srt}'" >> "$_tmp"
        fi
        # Numeric values: strip non-numeric/dot chars
        if [ -n "${!bw_var}" ]; then echo "${bw_var}='$(printf '%s' "${!bw_var}" | tr -cd '0-9.\-')'" >> "$_tmp"; fi
        if [ -n "${!cpus_var}" ]; then echo "${cpus_var}='$(printf '%s' "${!cpus_var}" | tr -cd '0-9.')'" >> "$_tmp"; fi
        if [ -n "${!mem_var}" ]; then echo "${mem_var}='$(printf '%s' "${!mem_var}" | tr -cd '0-9a-zA-Z')'" >> "$_tmp"; fi
        if [ -n "${!orport_var}" ]; then echo "${orport_var}='$(printf '%s' "${!orport_var}" | tr -cd '0-9')'" >> "$_tmp"; fi
        if [ -n "${!ptport_var}" ]; then echo "${ptport_var}='$(printf '%s' "${!ptport_var}" | tr -cd '0-9')'" >> "$_tmp"; fi
    done

    if ! chmod 600 "$_tmp" 2>/dev/null; then
        log_warn "Could not set permissions on settings file — check filesystem"
    fi
    if ! mv "$_tmp" "$INSTALL_DIR/settings.conf"; then
        log_error "Failed to save settings (mv failed). Check disk space and permissions."
        return 1
    fi

    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. File missing after write."
        return 1
    fi

    log_success "Settings saved"
}

load_settings() {
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        # Copy to temp file to avoid TOCTOU race between validation and source
        local _tmp_settings
        _tmp_settings=$(mktemp "${TMPDIR:-/tmp}/.tor_settings.XXXXXX") || return 1
        cp "$INSTALL_DIR/settings.conf" "$_tmp_settings" || { rm -f "$_tmp_settings"; return 1; }
        chmod 600 "$_tmp_settings" 2>/dev/null
        # Whitelist validation on the copy
        if grep -vE '^\s*$|^\s*#|^[A-Za-z_][A-Za-z0-9_]*='\''[^'\'']*'\''$|^[A-Za-z_][A-Za-z0-9_]*=[0-9]+$|^[A-Za-z_][A-Za-z0-9_]*=(true|false)$' "$_tmp_settings" 2>/dev/null | grep -q .; then
            log_error "settings.conf contains unsafe content. Refusing to load."
            rm -f "$_tmp_settings"
            return 1
        fi
        source "$_tmp_settings" 2>/dev/null
        rm -f "$_tmp_settings"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Docker Container Lifecycle
#═══════════════════════════════════════════════════════════════════════

get_docker_image() {
    local idx=${1:-1}
    local rtype=$(get_container_relay_type $idx)
    case "$rtype" in
        bridge) echo "$BRIDGE_IMAGE" ;;
        *)      echo "$RELAY_IMAGE" ;;
    esac
}

run_relay_container() {
    local idx=$1
    local cname=$(get_container_name $idx)
    local vname=$(get_volume_name $idx)
    local orport=$(get_container_orport $idx)
    local controlport=$(get_container_controlport $idx)
    local ptport=$(get_container_ptport $idx)
    local image=$(get_docker_image $idx)

    # Validate ports
    if ! validate_port "$orport" || ! validate_port "$controlport" || ! validate_port "$ptport"; then
        log_error "Invalid port configuration for container $idx (OR:$orport CP:$controlport PT:$ptport)"
        return 1
    fi

    # Generate torrc for this container (only needed for middle/exit — bridges use env vars)
    local rtype=$(get_container_relay_type $idx)
    if [ "$rtype" != "bridge" ]; then
        generate_torrc $idx
    fi

    # Remove existing container
    docker rm -f "$cname" 2>/dev/null || true

    # Ensure volume exists
    docker volume create "$vname" 2>/dev/null || true

    # Resource limits (use arrays for safe word splitting)
    local resource_args=()
    local cpus=$(get_container_cpus $idx)
    local mem=$(get_container_memory $idx)
    # Auto-calculate defaults if not explicitly set
    if [ -z "$cpus" ] && [ -z "$DOCKER_CPUS" ]; then
        local _sys_cores=$(get_cpu_cores)
        local _count=${CONTAINER_COUNT:-1}
        # Reserve 1 core for the host, split the rest among containers (min 0.5 per container)
        cpus=$(awk -v c="$_sys_cores" -v n="$_count" 'BEGIN {v=(c>1)?(c-1)/n:0.5; if(v<0.5)v=0.5; printf "%.1f",v}')
    elif [ -z "$cpus" ] && [ -n "$DOCKER_CPUS" ]; then
        cpus="$DOCKER_CPUS"
    fi
    if [ -z "$mem" ] && [ -z "$DOCKER_MEMORY" ]; then
        local _sys_ram=$(get_ram_mb)
        local _count=${CONTAINER_COUNT:-1}
        # Reserve 512MB for host, split rest among containers (min 256MB, max 2GB per container)
        local _per_mb=$(awk -v r="$_sys_ram" -v n="$_count" 'BEGIN {v=(r-512)/n; if(v<256)v=256; if(v>2048)v=2048; printf "%.0f",v}')
        mem="${_per_mb}m"
    elif [ -z "$mem" ] && [ -n "$DOCKER_MEMORY" ]; then
        mem="$DOCKER_MEMORY"
    fi
    [ -n "$cpus" ] && resource_args+=(--cpus "$cpus")
    [ -n "$mem" ] && resource_args+=(--memory "$mem")

    local torrc_path="$CONTAINERS_DIR/relay-${idx}/torrc"

    # Compute bandwidth in bytes/sec for env vars
    local bw=$(get_container_bandwidth $idx)
    local bw_bytes=""
    if [ "$bw" != "-1" ] && [ -n "$bw" ]; then
        bw_bytes=$(awk -v b="$bw" 'BEGIN {printf "%.0f", b * 125000}')
    fi

    if [ "$rtype" = "bridge" ]; then
        # For the official bridge image, use environment variables
        # Enable ControlPort via OBFS4V_ env vars for monitoring
        local bw_env=()
        if [ -n "$bw_bytes" ]; then
            bw_env=(-e "OBFS4V_BandwidthRate=${bw_bytes}" -e "OBFS4V_BandwidthBurst=$((bw_bytes * 2))")
        fi
        # NOTE: --network host is required for Tor relays: ORPort must bind directly on the
        # host interface, and ControlPort cookie auth requires shared localhost access.
        if ! docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            -v "${vname}:/var/lib/tor" \
            --network host \
            -e "OR_PORT=${orport}" \
            -e "PT_PORT=${ptport}" \
            -e "EMAIL=${CONTACT_INFO}" \
            -e "NICKNAME=$(get_container_nickname $idx)" \
            -e "OBFS4_ENABLE_ADDITIONAL_VARIABLES=1" \
            -e "OBFS4V_ControlPort=127.0.0.1:${controlport}" \
            -e "OBFS4V_CookieAuthentication=1" \
            "${bw_env[@]}" \
            "${resource_args[@]}" \
            "$image"; then
            log_error "Failed to start $cname (bridge)"
            return 1
        fi
    else
        # For middle/exit relays, mount our custom torrc
        # NOTE: --network host required for Tor ORPort binding and ControlPort cookie auth
        if ! docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            -v "${vname}:/var/lib/tor" \
            -v "${torrc_path}:/etc/tor/torrc:ro" \
            --network host \
            "${resource_args[@]}" \
            "$image"; then
            log_error "Failed to start $cname (relay)"
            return 1
        fi
    fi

    log_success "$cname started (ORPort: $orport, ControlPort: $controlport)"
}

run_all_containers() {
    local count=${CONTAINER_COUNT:-1}

    log_info "Starting Torware ($count container(s))..."

    # Pull required images (may need both bridge and relay images for mixed types)
    local needs_bridge=false needs_relay=false
    for i in $(seq 1 $count); do
        local rt=$(get_container_relay_type $i)
        [ "$rt" = "bridge" ] && needs_bridge=true || needs_relay=true
    done
    if [ "$needs_bridge" = "true" ]; then
        log_info "Pulling bridge image ($BRIDGE_IMAGE)..."
        if ! docker pull "$BRIDGE_IMAGE"; then
            log_error "Failed to pull bridge image. Check your internet connection."
            exit 1
        fi
    fi
    if [ "$needs_relay" = "true" ]; then
        log_info "Pulling relay image ($RELAY_IMAGE)..."
        if ! docker pull "$RELAY_IMAGE"; then
            log_error "Failed to pull relay image. Check your internet connection."
            exit 1
        fi
    fi

    # Pull Alpine image used for cookie auth reading
    log_info "Pulling utility image (alpine:latest)..."
    docker pull alpine:latest 2>/dev/null || log_warn "Could not pre-pull alpine image (cookie auth may be slower on first use)"

    for i in $(seq 1 $count); do
        run_relay_container $i
    done

    # Start Snowflake proxy if enabled
    run_snowflake_container

    sleep 5
    if docker ps | grep -q "torware"; then
        local bw_display="$BANDWIDTH Mbps"
        [ "$BANDWIDTH" = "-1" ] && bw_display="Unlimited"
        log_success "Settings: default_type=$RELAY_TYPE, bandwidth=$bw_display, containers=$count"
        if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running; then
            log_success "Snowflake proxy: running (WebRTC transport)"
        fi
    else
        log_error "Tor relay failed to start"
        docker logs "$(get_container_name 1)" 2>&1 | tail -10
        exit 1
    fi
}

start_relay() {
    local count=${CONTAINER_COUNT:-1}
    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
            if docker start "$cname" 2>/dev/null; then
                log_success "$cname started"
            else
                log_error "Failed to start $cname, recreating..."
                run_relay_container $i
            fi
        else
            run_relay_container $i
        fi
    done
    start_snowflake_container
}

stop_relay() {
    log_info "Stopping Tor relay containers..."
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            docker stop --timeout 30 "$cname" 2>/dev/null || true
            log_success "$cname stopped"
        fi
    done
    stop_snowflake_container
}

restart_relay() {
    log_info "Restarting Tor relay containers..."
    local count=${CONTAINER_COUNT:-1}
    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)

        # Regenerate torrc in case settings changed (only for non-bridge; bridges use env vars)
        local _rtype=$(get_container_relay_type $i)
        if [ "$_rtype" != "bridge" ]; then
            generate_torrc $i
        fi

        # Check if container exists
        if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
            docker rm -f "$cname" 2>/dev/null || true
        fi

        run_relay_container $i
    done
    restart_snowflake_container
}

#═══════════════════════════════════════════════════════════════════════
# Snowflake Proxy Container Lifecycle
#═══════════════════════════════════════════════════════════════════════

run_snowflake_container() {
    if [ "$SNOWFLAKE_ENABLED" != "true" ]; then
        return 0
    fi

    log_info "Starting Snowflake proxy..."

    # Pull image
    if ! docker pull "$SNOWFLAKE_IMAGE"; then
        log_error "Failed to pull Snowflake image."
        return 1
    fi

    # Remove existing
    docker rm -f "$SNOWFLAKE_CONTAINER" 2>/dev/null || true

    # Ensure volume exists for data persistence
    docker volume create "$SNOWFLAKE_VOLUME" 2>/dev/null || true

    # Validate port range format
    if ! [[ "$SNOWFLAKE_PORT_RANGE" =~ ^[0-9]+:[0-9]+$ ]]; then
        log_error "Invalid SNOWFLAKE_PORT_RANGE format: $SNOWFLAKE_PORT_RANGE (expected START:END)"
        return 1
    fi

    if ! docker run -d \
        --name "$SNOWFLAKE_CONTAINER" \
        --restart unless-stopped \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --cpus "${SNOWFLAKE_CPUS:-1.0}" \
        --memory "${SNOWFLAKE_MEMORY:-256m}" \
        --network host \
        -v "${SNOWFLAKE_VOLUME}:/var/lib/snowflake" \
        "$SNOWFLAKE_IMAGE" \
        -metrics \
        -ephemeral-ports-range "$SNOWFLAKE_PORT_RANGE"; then
        log_error "Failed to start Snowflake proxy"
        return 1
    fi
    log_success "Snowflake proxy started (metrics on port $SNOWFLAKE_METRICS_PORT)"
}

stop_snowflake_container() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SNOWFLAKE_CONTAINER}$"; then
        docker stop --timeout 10 "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
        log_success "Snowflake proxy stopped"
    fi
}

start_snowflake_container() {
    if [ "$SNOWFLAKE_ENABLED" != "true" ]; then
        return 0
    fi
    if docker ps -a --format '{{.Names}}' | grep -q "^${SNOWFLAKE_CONTAINER}$"; then
        if docker start "$SNOWFLAKE_CONTAINER" 2>/dev/null; then
            log_success "Snowflake proxy started"
        else
            log_warn "Failed to start Snowflake, recreating..."
            run_snowflake_container
        fi
    else
        run_snowflake_container
    fi
}

restart_snowflake_container() {
    if [ "$SNOWFLAKE_ENABLED" != "true" ]; then
        return 0
    fi
    docker rm -f "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
    run_snowflake_container
}

is_snowflake_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SNOWFLAKE_CONTAINER}$"
}

get_snowflake_stats() {
    # Get connections from Prometheus metrics (accurate per-country counts)
    local metrics=""
    metrics=$(curl -s --max-time 3 "http://127.0.0.1:${SNOWFLAKE_METRICS_PORT}/internal/metrics" 2>/dev/null)

    local connections=0
    if [ -n "$metrics" ]; then
        connections=$(echo "$metrics" | awk '
            /^tor_snowflake_proxy_connections_total[{ ]/ { sum += $NF }
            END { printf "%.0f", sum }
        ' 2>/dev/null)
    fi

    # Get cumulative traffic from docker logs (Prometheus metrics undercount)
    # Logs contain: "Traffic Relayed ↓ XXXX KB (...), ↑ YYYY KB (...)"
    local inbound=0 outbound=0
    local log_data
    log_data=$(docker logs "$SNOWFLAKE_CONTAINER" 2>&1 | grep "Traffic Relayed" 2>/dev/null)
    if [ -n "$log_data" ]; then
        # Sum all hourly inbound/outbound KB values, convert to bytes
        inbound=$(echo "$log_data" | awk -F'[↓↑]' '{
            split($2, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1]
        } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
        outbound=$(echo "$log_data" | awk -F'[↓↑]' '{
            split($3, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1]
        } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
    fi

    echo "${connections:-0} ${inbound:-0} ${outbound:-0}"
}

get_snowflake_country_stats() {
    # Return connections per country from Snowflake metrics
    local metrics=""
    metrics=$(curl -s --max-time 3 "http://127.0.0.1:${SNOWFLAKE_METRICS_PORT}/internal/metrics" 2>/dev/null) || return 1

    # Parse tor_snowflake_proxy_connections_total{type="...",country="xx"} value
    # Portable awk — no gawk match() needed
    echo "$metrics" | awk '
        /^tor_snowflake_proxy_connections_total\{/ {
            val = $NF + 0
            country = ""
            s = $0
            idx = index(s, "country=\"")
            if (idx > 0) {
                s = substr(s, idx + 9)
                end = index(s, "\"")
                if (end > 0) country = substr(s, 1, end - 1)
            }
            if (country != "" && val > 0) counts[country] += val
        }
        END {
            for (c in counts) print counts[c] "|" c
        }
    ' 2>/dev/null | sort -t'|' -k1 -nr
}

#═══════════════════════════════════════════════════════════════════════
# Status Display
#═══════════════════════════════════════════════════════════════════════

show_status() {
    load_settings
    local count=${CONTAINER_COUNT:-1}

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              🧅 TORWARE STATUS                              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "  ${BOLD}Default Type:${NC} ${GREEN}${RELAY_TYPE}${NC}"
    echo -e "  ${BOLD}Nickname:${NC}    ${GREEN}${NICKNAME}${NC}"

    if [ "$BANDWIDTH" = "-1" ]; then
        echo -e "  ${BOLD}Bandwidth:${NC}   ${GREEN}Unlimited${NC}"
    else
        echo -e "  ${BOLD}Bandwidth:${NC}   ${GREEN}${BANDWIDTH} Mbps${NC}"
    fi
    echo ""

    local total_read=0
    local total_written=0
    local total_circuits=0
    local total_conns=0
    local running=0

    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        local orport=$(get_container_orport $i)
        local controlport=$(get_container_controlport $i)

        local status="STOPPED"
        local status_color="${RED}"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            status="RUNNING"
            status_color="${GREEN}"
            running=$((running + 1))

            # Get uptime
            local started_at
            started_at=$(docker inspect --format '{{.State.StartedAt}}' "$cname" 2>/dev/null)
            local uptime_str=""
            if [ -n "$started_at" ]; then
                local start_epoch
                start_epoch=$(date -d "${started_at}" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" +%s 2>/dev/null || echo "0")
                local now_epoch=$(date +%s)
                if [ "$start_epoch" -gt 0 ] 2>/dev/null; then
                    uptime_str=$(format_duration $((now_epoch - start_epoch)))
                fi
            fi

            # Get traffic
            local traffic
            traffic=$(get_tor_traffic $i)
            local rb=$(echo "$traffic" | awk '{print $1}')
            local wb=$(echo "$traffic" | awk '{print $2}')
            rb=${rb:-0}; wb=${wb:-0}
            total_read=$((total_read + rb))
            total_written=$((total_written + wb))

            # Get circuits
            local circuits=$(get_tor_circuits $i)
            circuits=${circuits//[^0-9]/}; circuits=${circuits:-0}
            total_circuits=$((total_circuits + circuits))

            # Get connections
            local conns=$(get_tor_connections $i)
            conns=${conns//[^0-9]/}; conns=${conns:-0}
            total_conns=$((total_conns + conns))

            local c_rtype=$(get_container_relay_type $i)
            echo -e "  ${BOLD}Container ${i} [${c_rtype}]:${NC} ${status_color}${status}${NC} (up ${uptime_str:-unknown})"
            echo -e "    ORPort: ${orport} | ControlPort: ${controlport}"
            echo -e "    Traffic: ↓ $(format_bytes $rb)  ↑ $(format_bytes $wb)"
            echo -e "    Circuits: ${circuits} | Connections: ${conns}"

            # Show fingerprint
            local fp=$(get_tor_fingerprint $i)
            if [ -n "$fp" ]; then
                echo -e "    Fingerprint: ${DIM}${fp}${NC}"
            fi

            # Show bridge line for bridges
            if [ "$c_rtype" = "bridge" ]; then
                local bl=$(get_bridge_line $i)
                if [ -n "$bl" ]; then
                    echo -e "    Bridge Line: ${DIM}${bl:0:120}...${NC}"
                fi
            fi
        else
            echo -e "  ${BOLD}Container ${i}:${NC} ${status_color}${status}${NC}"
        fi
        echo ""
    done

    # Snowflake status
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo -e "  ${BOLD}Snowflake Proxy:${NC}"
        if is_snowflake_running; then
            local sf_stats=$(get_snowflake_stats 2>/dev/null)
            local sf_conns=$(echo "$sf_stats" | awk '{print $1}')
            local sf_in=$(echo "$sf_stats" | awk '{print $2}')
            local sf_out=$(echo "$sf_stats" | awk '{print $3}')
            echo -e "    Status: ${GREEN}RUNNING${NC}"
            echo -e "    Connections: ${sf_conns:-0}  Traffic: ↓ $(format_bytes ${sf_in:-0})  ↑ $(format_bytes ${sf_out:-0})"
        else
            echo -e "    Status: ${RED}STOPPED${NC}"
        fi
        echo ""
    fi

    # Include snowflake in totals
    local total_containers=$count
    local total_running=$running
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        total_containers=$((total_containers + 1))
        if is_snowflake_running; then
            total_running=$((total_running + 1))
            local sf_stats=$(get_snowflake_stats 2>/dev/null)
            local sf_in=$(echo "$sf_stats" | awk '{print $2}')
            local sf_out=$(echo "$sf_stats" | awk '{print $3}')
            total_read=$((total_read + ${sf_in:-0}))
            total_written=$((total_written + ${sf_out:-0}))
        fi
    fi

    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Totals:${NC}"
    echo -e "    Containers: ${GREEN}${total_running}${NC}/${total_containers} running"
    echo -e "    Traffic:    ↓ $(format_bytes $total_read)  ↑ $(format_bytes $total_written)"
    echo -e "    Circuits:   ${total_circuits}"
    echo -e "    Connections: ${total_conns}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Backup & Restore
#═══════════════════════════════════════════════════════════════════════

backup_keys() {
    load_settings
    local count=${CONTAINER_COUNT:-1}
    mkdir -p "$BACKUP_DIR"

    local timestamp=$(date '+%Y%m%d_%H%M%S')

    for i in $(seq 1 $count); do
        local vname=$(get_volume_name $i)
        local backup_file="$BACKUP_DIR/tor_keys_relay${i}_${timestamp}.tar.gz"

        if docker volume inspect "$vname" &>/dev/null; then
            ( umask 077; docker run --rm -v "${vname}:/data:ro" alpine \
                sh -c 'cd /data && tar -czf - keys fingerprint pt_state state 2>/dev/null || tar -czf - keys fingerprint state 2>/dev/null' \
                > "$backup_file" 2>/dev/null )

            if [ -s "$backup_file" ]; then
                chmod 600 "$backup_file"
                local fp=$(get_tor_fingerprint $i)
                log_success "Relay $i backed up: $backup_file"
                if [ -n "$fp" ]; then
                    echo -e "    Fingerprint: ${DIM}${fp}${NC}"
                fi
            else
                rm -f "$backup_file"
                log_warn "Relay $i: No key data found to backup"
            fi
        else
            log_warn "Relay $i: Volume $vname does not exist"
        fi
    done

    # Rotate old backups — keep only the 10 most recent per relay
    for i in $(seq 1 $count); do
        local old_backups
        old_backups=$(find "$BACKUP_DIR" -maxdepth 1 -name "tor_keys_relay${i}_*.tar.gz" 2>/dev/null | sort -r | tail -n +11)
        if [ -n "$old_backups" ]; then
            echo "$old_backups" | xargs rm -f 2>/dev/null
            log_info "Rotated old backups for relay $i (keeping 10 most recent)"
        fi
    done
}

restore_keys() {
    load_settings

    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "No backups directory found."
        return 1
    fi

    local backups=()
    while IFS= read -r -d '' f; do
        backups+=("$f")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'tor_keys_*.tar.gz' -print0 2>/dev/null | sort -z -r)

    if [ ${#backups[@]} -eq 0 ]; then
        log_warn "No backup files found."
        return 1
    fi

    echo ""
    echo -e "${CYAN}  Available Backups:${NC}"
    echo ""
    local idx=1
    for backup in "${backups[@]}"; do
        local fname=$(basename "$backup")
        echo -e "    ${GREEN}${idx}.${NC} $fname"
        idx=$((idx + 1))
    done
    echo ""

    read -p "  Select backup number (or 'q' to cancel): " choice < /dev/tty || true

    if [ "$choice" = "q" ] || [ -z "$choice" ]; then
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log_error "Invalid selection."
        return 1
    fi

    local selected="${backups[$((choice - 1))]}"
    local target_relay=1

    # Try to detect which relay this backup is for
    local fname=$(basename "$selected")
    if [[ "$fname" =~ relay([0-9]+) ]]; then
        target_relay="${BASH_REMATCH[1]}"
    fi

    echo ""
    read -p "  Restore to relay container $target_relay? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 0
    fi

    local vname=$(get_volume_name $target_relay)
    local cname=$(get_container_name $target_relay)

    # Stop container
    docker stop --timeout 30 "$cname" 2>/dev/null || true

    # Ensure volume exists
    docker volume create "$vname" 2>/dev/null || true

    # Validate backup filename (prevent path traversal)
    local restore_basename
    restore_basename=$(basename "$selected")
    if [[ ! "$restore_basename" =~ ^tor_keys_relay[0-9]+_[0-9]+_[0-9]+\.tar\.gz$ ]]; then
        log_error "Invalid backup filename: $restore_basename"
        return 1
    fi

    # Validate backup integrity
    if ! tar -tzf "$selected" &>/dev/null; then
        log_error "Backup file is corrupt or not a valid tar.gz: $restore_basename"
        return 1
    fi

    # Restore from backup
    docker run --rm -v "${vname}:/data" -v "$(dirname "$selected"):/backup:ro" alpine \
        sh -c "cd /data && tar -xzf '/backup/$restore_basename'" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Keys restored to relay $target_relay"
        # Restart container
        docker start "$cname" 2>/dev/null || run_relay_container $target_relay
    else
        log_error "Failed to restore keys"
        return 1
    fi
}

check_and_offer_backup_restore() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -name 'tor_keys_*.tar.gz' -print 2>/dev/null | sort -r | head -1)

    if [ -z "$latest_backup" ]; then
        return 0
    fi

    local backup_filename=$(basename "$latest_backup")

    # Validate filename to prevent path traversal
    if ! [[ "$backup_filename" =~ ^tor_keys_relay[0-9]+_[0-9]+_[0-9]+\.tar\.gz$ ]]; then
        log_warn "Backup filename has unexpected format: $backup_filename — skipping"
        return 0
    fi
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  📁 PREVIOUS RELAY IDENTITY BACKUP FOUND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A backup of your relay identity keys was found:"
    echo -e "    ${YELLOW}File:${NC} $backup_filename"
    echo ""
    echo -e "  Restoring will:"
    echo -e "    • Preserve your relay's identity on the Tor network"
    echo -e "    • Maintain your relay's reputation and consensus weight"
    echo -e "    • Keep the same fingerprint and bridge line"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} If you don't restore, a new identity will be generated."
    echo ""

    while true; do
        read -p "  Restore your previous relay identity? (y/n): " restore_choice < /dev/tty || true

        if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
            echo ""
            log_info "Restoring relay identity from backup..."

            # Determine target relay
            local target_relay=1
            if [[ "$backup_filename" =~ relay([0-9]+) ]]; then
                target_relay="${BASH_REMATCH[1]}"
            fi

            local vname=$(get_volume_name $target_relay)
            docker volume create "$vname" 2>/dev/null || true

            local restore_ok=false
            if docker run --rm -v "${vname}:/data" -v "$BACKUP_DIR":/backup:ro alpine \
                sh -c 'cd /data && tar -xzf "/backup/$1"' -- "$backup_filename" 2>/dev/null; then
                restore_ok=true
            fi

            if [ "$restore_ok" = "true" ]; then
                log_success "Relay identity restored successfully!"
                echo ""
                return 0
            else
                log_error "Failed to restore backup. Proceeding with fresh install."
                echo ""
                return 1
            fi
        elif [[ "$restore_choice" =~ ^[Nn]$ ]]; then
            echo ""
            log_info "Skipping restore. A new relay identity will be generated."
            echo ""
            return 1
        else
            echo "  Please enter y or n."
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════
# Auto-Start Services
#═══════════════════════════════════════════════════════════════════════

setup_autostart() {
    log_info "Setting up auto-start on boot..."

    if [ "$HAS_SYSTEMD" = "true" ]; then
        cat > /etc/systemd/system/torware.service << EOF
[Unit]
Description=Torware Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
TimeoutStopSec=120
ExecStart=/usr/local/bin/torware start
ExecStop=/usr/local/bin/torware stop

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable torware.service 2>/dev/null || true
        systemctl start torware.service 2>/dev/null || true
        log_success "Systemd service created, enabled, and started"

    elif command -v rc-update &>/dev/null; then
        cat > /etc/init.d/torware << 'EOF'
#!/sbin/openrc-run

name="torware"
description="Torware Service"
depend() {
    need docker
    after network
}
start() {
    ebegin "Starting Torware"
    /usr/local/bin/torware start
    eend $?
}
stop() {
    ebegin "Stopping Torware"
    /usr/local/bin/torware stop
    eend $?
}
status() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^torware'; then
        einfo "Torware is running"
        return 0
    else
        einfo "Torware is stopped"
        return 3
    fi
}
EOF
        chmod +x /etc/init.d/torware
        rc-update add torware default 2>/dev/null || true
        log_success "OpenRC service created and enabled"

    elif [ -d /etc/init.d ]; then
        cat > /etc/init.d/torware << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          torware
# Required-Start:    docker
# Required-Stop:     docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Torware Service
### END INIT INFO

case "$1" in
    start)
        /usr/local/bin/torware start
        ;;
    stop)
        /usr/local/bin/torware stop
        ;;
    restart)
        /usr/local/bin/torware restart
        ;;
    status)
        docker ps | grep -q torware && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/init.d/torware
        if command -v update-rc.d &>/dev/null; then
            update-rc.d torware defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig torware on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"

    else
        log_warn "Could not set up auto-start. Docker's restart policy will handle restarts."
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Health Check
#═══════════════════════════════════════════════════════════════════════

health_check() {
    load_settings
    local count=${CONTAINER_COUNT:-1}
    local all_ok=true

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              🧅 TORWARE HEALTH CHECK                        ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # 1. Docker daemon
    echo -n "  Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        local controlport=$(get_container_controlport $i)
        echo ""
        echo -e "  ${BOLD}--- Container $i ($cname) ---${NC}"

        # 2. Container exists
        echo -n "  Container exists:     "
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}NOT FOUND${NC}"
            all_ok=false
            continue
        fi

        # 3. Container running
        echo -n "  Container running:    "
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}STOPPED${NC}"
            all_ok=false
            continue
        fi

        # 4. Restart count
        local restarts
        restarts=$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")
        echo -n "  Restart count:        "
        if [ "$restarts" -eq 0 ] 2>/dev/null; then
            echo -e "${GREEN}0 (healthy)${NC}"
        elif [ "$restarts" -lt 5 ] 2>/dev/null; then
            echo -e "${YELLOW}${restarts} (some restarts)${NC}"
        else
            echo -e "${RED}${restarts} (excessive)${NC}"
            all_ok=false
        fi

        # 5. ControlPort accessible
        echo -n "  ControlPort:          "
        local nc_cmd=$(get_nc_cmd)
        if [ -n "$nc_cmd" ] && timeout 3 $nc_cmd -z 127.0.0.1 "$controlport" 2>/dev/null; then
            echo -e "${GREEN}OK (port $controlport)${NC}"
        else
            echo -e "${YELLOW}NOT ACCESSIBLE (port $controlport)${NC}"
        fi

        # 6. Cookie auth
        echo -n "  Cookie auth:          "
        local cookie=$(get_control_cookie $i)
        if [ -n "$cookie" ] && [ "$cookie" != "" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}NO COOKIE (relay may still be bootstrapping)${NC}"
        fi

        # 7. Data volume
        local vname=$(get_volume_name $i)
        echo -n "  Data volume:          "
        if docker volume inspect "$vname" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}MISSING${NC}"
            all_ok=false
        fi

        # 8. Network mode
        echo -n "  Network (host mode):  "
        local netmode
        netmode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null)
        if [ "$netmode" = "host" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}${netmode} (should be host)${NC}"
            all_ok=false
        fi

        # 9. Fingerprint
        echo -n "  Relay fingerprint:    "
        local fp=$(get_tor_fingerprint $i)
        if [ -n "$fp" ]; then
            echo -e "${GREEN}OK${NC} (${fp:0:20}...)"
        else
            echo -e "${YELLOW}NOT YET GENERATED${NC}"
        fi

        # 10. Logs check
        echo -n "  Recent activity:      "
        local recent_logs
        recent_logs=$(docker logs --tail 30 "$cname" 2>&1)
        if echo "$recent_logs" | grep -qi "bootstrapped 100%\|self-testing indicates"; then
            echo -e "${GREEN}OK (fully bootstrapped)${NC}"
        elif echo "$recent_logs" | grep -qi "bootstrapped"; then
            local pct
            pct=$(echo "$recent_logs" | sed -n 's/.*Bootstrapped \([0-9]*\).*/\1/p' | tail -1)
            echo -e "${YELLOW}Bootstrapping (${pct}%)${NC}"
        else
            echo -e "${YELLOW}Checking...${NC}"
        fi
    done

    echo ""

    # 11. GeoIP (bridges use Tor's built-in CLIENTS_SEEN; relays need system GeoIP)
    echo -n "  GeoIP available:      "
    if command -v geoiplookup &>/dev/null; then
        echo -e "${GREEN}OK (geoiplookup)${NC}"
    elif command -v mmdblookup &>/dev/null; then
        echo -e "${GREEN}OK (mmdblookup)${NC}"
    else
        # Check if any non-bridge containers exist
        local _needs_geoip=false
        for _gi in $(seq 1 $count); do
            [ "$(get_container_relay_type $_gi)" != "bridge" ] && _needs_geoip=true
        done
        if [ "$_needs_geoip" = "true" ]; then
            echo -e "${YELLOW}NOT INSTALLED (needed for relay country stats)${NC}"
        else
            echo -e "${GREEN}N/A (bridges use Tor's built-in country data)${NC}"
        fi
    fi

    # 12. netcat
    echo -n "  netcat available:     "
    if command -v nc &>/dev/null || command -v ncat &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}NOT INSTALLED (ControlPort queries will fail)${NC}"
        all_ok=false
    fi

    # 13. od (used for cookie hex conversion — always available in Alpine/busybox)
    echo -n "  od available:         "
    if command -v od &>/dev/null; then
        echo -e "${GREEN}OK (host)${NC}"
    elif docker image inspect alpine &>/dev/null; then
        echo -e "${GREEN}OK (Alpine has od via busybox)${NC}"
    else
        echo -e "${YELLOW}UNCHECKED (Alpine image not cached)${NC}"
    fi

    # Snowflake proxy health
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo ""
        echo -e "  ${BOLD}--- Snowflake Proxy ---${NC}"

        echo -n "  Container running:    "
        if is_snowflake_running; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}STOPPED${NC}"
            all_ok=false
        fi

        echo -n "  Metrics endpoint:     "
        if curl -s --max-time 3 "http://127.0.0.1:${SNOWFLAKE_METRICS_PORT}/internal/metrics" &>/dev/null; then
            echo -e "${GREEN}OK (port $SNOWFLAKE_METRICS_PORT)${NC}"
        else
            echo -e "${YELLOW}NOT ACCESSIBLE${NC}"
        fi
    fi

    echo ""
    if [ "$all_ok" = "true" ]; then
        echo -e "  ${GREEN}✓ All health checks passed${NC}"
    else
        echo -e "  ${YELLOW}⚠ Some checks failed. Review issues above.${NC}"
    fi
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Container Stats Aggregation
#═══════════════════════════════════════════════════════════════════════

get_container_stats() {
    # Get CPU and RAM usage across all torware containers
    local names=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        names+=" $(get_container_name $i)"
    done
    if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running; then
        names+=" $SNOWFLAKE_CONTAINER"
    fi
    local all_stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $names 2>/dev/null)
    local _nlines=$(echo "$all_stats" | wc -l)
    if [ -z "$all_stats" ]; then
        echo "0% 0MiB"
    elif [ "$_nlines" -le 1 ]; then
        echo "$all_stats"
    else
        echo "$all_stats" | awk '{
            cpu = $1; gsub(/%/, "", cpu); total_cpu += cpu + 0
            mem = $2; gsub(/[^0-9.]/, "", mem); mem += 0
            if ($2 ~ /GiB/) mem *= 1024
            else if ($2 ~ /KiB/) mem /= 1024
            total_mem += mem
            if (mem_limit == "") mem_limit = $4
            found = 1
        } END {
            if (!found) { print "0% 0MiB"; exit }
            if (total_mem >= 1024) mem_display = sprintf("%.2fGiB", total_mem/1024)
            else mem_display = sprintf("%.1fMiB", total_mem)
            printf "%.2f%% %s / %s\n", total_cpu, mem_display, mem_limit
        }'
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Live TUI Dashboard (Phase 2)
#═══════════════════════════════════════════════════════════════════════

print_dashboard_header() {
    local EL="\033[K"
    local bar="═══════════════════════════════════════════════════════════════════"
    echo -e "${CYAN}╔${bar}╗${NC}${EL}"
    # 🧅 emoji = 2 display cols but 1 char, so printf sees 4 cols for "  🧅 " but display is 5; use %-62s
    printf "${CYAN}║${NC}  🧅 ${BOLD}%-62s${NC}${CYAN}║${NC}${EL}\n" "TORWARE v${VERSION}       TORWARE LIVE STATISTICS"
    echo -e "${CYAN}╠${bar}╣${NC}${EL}"
    # Detect mixed relay types for dashboard header
    local _dh_type="${RELAY_TYPE}"
    for _dhi in $(seq 1 ${CONTAINER_COUNT:-1}); do
        [ "$(get_container_relay_type $_dhi)" != "$RELAY_TYPE" ] && _dh_type="mixed" && break
    done
    # Inner width=67: "  Relay Type: "(14) + type(10) + "  Nickname: "(12) + nick(31) = 67
    local _type_pad=$(printf '%-10s' "$_dh_type")
    local _nick_pad=$(printf '%-31s' "$NICKNAME")
    echo -e "${CYAN}║${NC}  Relay Type: ${GREEN}${_type_pad}${NC}  Nickname: ${GREEN}${_nick_pad}${NC}${CYAN}║${NC}${EL}"
    local _bw_text
    if [ "$BANDWIDTH" = "-1" ]; then
        _bw_text="Unlimited"
    else
        _bw_text="${BANDWIDTH} Mbps"
    fi
    # "  Bandwidth:  "(14) + bw(53) = 67
    local _bw_pad=$(printf '%-53s' "$_bw_text")
    echo -e "${CYAN}║${NC}  Bandwidth:  ${GREEN}${_bw_pad}${NC}${CYAN}║${NC}${EL}"
    echo -e "${CYAN}╚${bar}╝${NC}${EL}"
}

show_dashboard() {
    load_settings
    local stop_dashboard=0
    local _dash_pid=$$
    # Pre-seed CPU state file so first iteration has a valid delta
    local _cpu_seed="${TMPDIR:-/tmp}/torware_cpu_state_$$"
    if [ -f /proc/stat ] && [ ! -f "$_cpu_seed" ]; then
        read -r _cpu user nice system idle iowait irq softirq steal guest < /proc/stat 2>/dev/null
        echo "$(( user + nice + system + idle + iowait + irq + softirq + steal )) $(( user + nice + system + irq + softirq + steal ))" > "$_cpu_seed" 2>/dev/null
    fi
    _dashboard_cleanup() {
        echo -ne "\033[?25h"
        tput rmcup 2>/dev/null || true
        rm -rf "/tmp/.tor_dash.${_dash_pid}."* 2>/dev/null
    }
    trap '_dashboard_cleanup; stop_dashboard=1' INT TERM
    trap '_dashboard_cleanup' RETURN

    # Alternate screen buffer
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Cursor home (no clear = no flicker)
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi

        local EL="\033[K"
        local count=${CONTAINER_COUNT:-1}

        print_dashboard_header

        echo -e "${EL}"

        # Collect stats from all containers in parallel
        local _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/.tor_dash.${_dash_pid}.XXXXXX")

        # ControlPort queries in parallel per container
        # Note: subshells inherit env (including TELEGRAM_BOT_TOKEN) but only write to temp files
        for i in $(seq 1 $count); do
            (
                local cname=$(get_container_name $i)
                local port=$(get_container_controlport $i)
                local running=0

                if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                    running=1

                    # Uptime
                    local started_at
                    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$cname" 2>/dev/null)
                    local start_epoch=0
                    if [ -n "$started_at" ]; then
                        start_epoch=$(date -d "$started_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" +%s 2>/dev/null || echo "0")
                    fi

                    # Traffic via ControlPort
                    local result
                    result=$(controlport_query "$port" \
                        "GETINFO traffic/read" \
                        "GETINFO traffic/written" \
                        "GETINFO circuit-status" \
                        "GETINFO orconn-status" 2>/dev/null)

                    local rb=$(echo "$result" | sed -n 's/.*traffic\/read=\([0-9]*\).*/\1/p' | head -1 2>/dev/null || echo "0")
                    local wb=$(echo "$result" | sed -n 's/.*traffic\/written=\([0-9]*\).*/\1/p' | head -1 2>/dev/null || echo "0")
                    local circuits=$(echo "$result" | grep -cE '^[0-9]+ (BUILT|EXTENDED|LAUNCHED)' 2>/dev/null || echo "0")
                    local conns=$(echo "$result" | grep -c '\$' 2>/dev/null || echo "0")
                    rb=${rb//[^0-9]/}; rb=${rb:-0}
                    wb=${wb//[^0-9]/}; wb=${wb:-0}
                    circuits=${circuits//[^0-9]/}; circuits=${circuits:-0}
                    conns=${conns//[^0-9]/}; conns=${conns:-0}

                    echo "$running $rb $wb $circuits $conns $start_epoch" > "$_tmpdir/c_${i}"
                else
                    echo "0 0 0 0 0 0" > "$_tmpdir/c_${i}"
                fi
            ) &
        done

        # System stats in parallel
        ( get_container_stats > "$_tmpdir/cstats" ) &
        ( get_net_speed > "$_tmpdir/net" ) &
        wait

        # Aggregate
        local total_read=0 total_written=0 total_circuits=0 total_conns=0 running=0
        local earliest_start=0

        for i in $(seq 1 $count); do
            if [ -f "$_tmpdir/c_${i}" ]; then
                read -r c_run c_rb c_wb c_circ c_conn c_start < "$_tmpdir/c_${i}"
                c_run=${c_run:-0}; c_rb=${c_rb:-0}; c_wb=${c_wb:-0}; c_circ=${c_circ:-0}; c_conn=${c_conn:-0}; c_start=${c_start:-0}
                if [ "$c_run" = "1" ]; then
                    running=$((running + 1))
                    total_read=$((total_read + c_rb))
                    total_written=$((total_written + c_wb))
                    total_circuits=$((total_circuits + c_circ))
                    total_conns=$((total_conns + c_conn))
                    if [ "$earliest_start" -eq 0 ] || { [ "$c_start" -gt 0 ] && [ "$c_start" -lt "$earliest_start" ]; }; then
                        earliest_start=$c_start
                    fi
                fi
            fi
        done

        # Include snowflake in totals
        if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running 2>/dev/null; then
            local _sf_stats=$(get_snowflake_stats 2>/dev/null)
            local _sf_in=$(echo "$_sf_stats" | awk '{print $2}'); _sf_in=${_sf_in:-0}
            local _sf_out=$(echo "$_sf_stats" | awk '{print $3}'); _sf_out=${_sf_out:-0}
            total_read=$((total_read + _sf_in))
            total_written=$((total_written + _sf_out))
        fi

        local uptime_str="N/A"
        if [ "$earliest_start" -gt 0 ]; then
            uptime_str=$(format_duration $(($(date +%s) - earliest_start)))
        fi

        # Resource stats
        local stats=$(cat "$_tmpdir/cstats" 2>/dev/null)
        local net_speed=$(cat "$_tmpdir/net" 2>/dev/null)
        rm -rf "$_tmpdir"

        # Normalize App CPU
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu_display="0%"
        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
            app_cpu_display=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
            if [ "$num_cores" -gt 1 ]; then
                app_cpu_display="${app_cpu_display} (${raw_app_cpu}% vCPU)"
            fi
        fi
        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')

        # System CPU/RAM inline (quick /proc read)
        local sys_cpu="N/A" sys_ram_used="N/A" sys_ram_total="N/A"
        local cpu_tmp="${TMPDIR:-/tmp}/torware_cpu_state_$$"
        if [ -f /proc/stat ]; then
            read -r _cpu user nice system idle iowait irq softirq steal guest < /proc/stat
            local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
            local work_curr=$((user + nice + system + irq + softirq + steal))
            if [ -f "$cpu_tmp" ]; then
                read -r total_prev work_prev < "$cpu_tmp"
                local dt=$((total_curr - total_prev))
                local dw=$((work_curr - work_prev))
                if [ "$dt" -gt 0 ]; then
                    sys_cpu=$(awk -v w="$dw" -v t="$dt" 'BEGIN { printf "%.1f%%", w * 100 / t }')
                fi
            fi
            echo "$total_curr $work_curr" > "$cpu_tmp"
        fi
        if command -v free &>/dev/null; then
            local free_out=$(free -m 2>/dev/null)
            sys_ram_used=$(echo "$free_out" | awk '/^Mem:/{if ($3>=1024) printf "%.1fGiB",$3/1024; else printf "%.0fMiB",$3}')
            sys_ram_total=$(echo "$free_out" | awk '/^Mem:/{if ($2>=1024) printf "%.1fGiB",$2/1024; else printf "%.0fMiB",$2}')
        fi

        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')

        # ── Display ──
        if [ "$running" -gt 0 ]; then
            echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC} (${uptime_str})${EL}"
            echo -e "  Containers: ${GREEN}${running}${NC}/${count}    Circuits: ${GREEN}${total_circuits}${NC}    Connections: ${GREEN}${total_conns}${NC}${EL}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic (total) ═══${NC}${EL}"
            echo -e "  Downloaded:   ${CYAN}$(format_bytes $total_read)${NC}${EL}"
            echo -e "  Uploaded:     ${CYAN}$(format_bytes $total_written)${NC}${EL}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            local _acpu=$(printf '%-24s' "$app_cpu_display")
            local _aram=$(printf '%-20s' "$app_ram")
            echo -e "  App:     CPU: ${YELLOW}${_acpu}${NC}| RAM: ${YELLOW}${_aram}${NC}${EL}"
            local _scpu=$(printf '%-24s' "$sys_cpu")
            local _sram=$(printf '%-20s' "$sys_ram_used / $sys_ram_total")
            echo -e "  System:  CPU: ${YELLOW}${_scpu}${NC}| RAM: ${YELLOW}${_sram}${NC}${EL}"
            local _rx=$(printf '%-10s' "$rx_mbps")
            local _tx=$(printf '%-10s' "$tx_mbps")
            echo -e "  Total:   Net: ${YELLOW}↓ ${_rx}Mbps  ↑ ${_tx}Mbps${NC}${EL}"

            # Data cap from Tor accounting
            if [ "${DATA_CAP_GB}" -gt 0 ] 2>/dev/null; then
                echo -e "${EL}"
                echo -e "${CYAN}═══ DATA CAP ═══${NC}${EL}"
                local acct_result
                acct_result=$(controlport_query "$(get_container_controlport 1)" \
                    "GETINFO accounting/bytes" \
                    "GETINFO accounting/bytes-left" \
                    "GETINFO accounting/interval-end" 2>/dev/null)
                local acct_bytes=$(echo "$acct_result" | sed -n 's/.*accounting\/bytes=\([^\r]*\)/\1/p' | head -1 2>/dev/null)
                local acct_left=$(echo "$acct_result" | sed -n 's/.*accounting\/bytes-left=\([^\r]*\)/\1/p' | head -1 2>/dev/null)
                local acct_end=$(echo "$acct_result" | sed -n 's/.*accounting\/interval-end=\([^\r]*\)/\1/p' | head -1 2>/dev/null)
                if [ -n "$acct_bytes" ]; then
                    local acct_read=$(echo "$acct_bytes" | awk '{print $1}')
                    local acct_write=$(echo "$acct_bytes" | awk '{print $2}')
                    local acct_total=$((acct_read + acct_write))
                    echo -e "  Used: ${YELLOW}$(format_bytes $acct_total)${NC} / ${GREEN}${DATA_CAP_GB} GB${NC}${EL}"
                    [ -n "$acct_end" ] && echo -e "  Resets: ${DIM}${acct_end}${NC}${EL}"
                fi
            fi

            # Country breakdown — try tracker snapshot, fallback to CLIENTS_SEEN for bridges
            local snap_file="$STATS_DIR/tracker_snapshot"
            local data_file="$STATS_DIR/cumulative_data"

            # If no tracker data, try querying CLIENTS_SEEN directly for bridges
            if [ ! -s "$snap_file" ]; then
                local _any_bridge_running=false
                for _bi in $(seq 1 $count); do
                    [ "$(get_container_relay_type $_bi)" = "bridge" ] && _any_bridge_running=true && break
                done
                if [ "$_any_bridge_running" = "true" ]; then
                    local cs_data=$(get_tor_clients_seen 1)
                    if [ -n "$cs_data" ]; then
                        # Write a temporary snap file from CLIENTS_SEEN
                        local _tmp_snap=""
                        IFS=',' read -ra _cs_entries <<< "$cs_data"
                        for _cse in "${_cs_entries[@]}"; do
                            local _cc=$(echo "$_cse" | cut -d= -f1)
                            local _cn=$(echo "$_cse" | cut -d= -f2)
                            [ -z "$_cc" ] || [ -z "$_cn" ] && continue
                            local _country
                            _country=$(country_code_to_name "$_cc")
                            _tmp_snap+="UP|${_country}|${_cn}|bridge\n"
                        done
                        [ -n "$_tmp_snap" ] && printf '%b' "$_tmp_snap" > "$snap_file"
                    fi
                fi
            fi

            if [ -s "$snap_file" ] || [ -s "$data_file" ]; then
                echo -e "${EL}"

                # Left: Active Circuits by Country
                local left_lines=()
                if [ -s "$snap_file" ] && [ "$total_circuits" -gt 0 ]; then
                    local snap_data
                    snap_data=$(awk -F'|' '{c[$2]+=$3} END{for(co in c) if(co!="") print c[co]"|"co}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -5)
                    local snap_total=0
                    if [ -n "$snap_data" ]; then
                        while IFS='|' read -r cnt co; do
                            snap_total=$((snap_total + cnt))
                        done <<< "$snap_data"
                    fi
                    [ "$snap_total" -eq 0 ] && snap_total=1
                    if [ -n "$snap_data" ]; then
                        while IFS='|' read -r cnt country; do
                            [ -z "$country" ] && continue
                            local pct=$((cnt * 100 / snap_total))
                            [ "$pct" -gt 100 ] && pct=100
                            local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                            local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                            left_lines+=("$(printf "%-11.11s %3d%% \033[32m%s%s\033[0m %5s" "$country" "$pct" "$bf" "$bp" "$(format_number $cnt)")")
                        done <<< "$snap_data"
                    fi
                fi

                # Right: Top 5 Upload (cumulative)
                local right_lines=()
                if [ -s "$data_file" ]; then
                    local all_upload
                    all_upload=$(awk -F'|' '{if($1!="" && $3+0>0) print $3"|"$1}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr)
                    local top5_upload=$(echo "$all_upload" | head -5)
                    local total_upload=0
                    if [ -n "$all_upload" ]; then
                        while IFS='|' read -r bytes co; do
                            bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                            total_upload=$((total_upload + bytes))
                        done <<< "$all_upload"
                    fi
                    [ "$total_upload" -eq 0 ] && total_upload=1
                    if [ -n "$top5_upload" ]; then
                        while IFS='|' read -r bytes country; do
                            [ -z "$country" ] && continue
                            bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                            local pct=$((bytes * 100 / total_upload))
                            local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                            local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                            local fmt_bytes=$(format_bytes $bytes)
                            right_lines+=("$(printf "%-11.11s %3d%% \033[35m%s%s\033[0m %9s" "$country" "$pct" "$bf" "$bp" "$fmt_bytes")")
                        done <<< "$top5_upload"
                    fi
                fi

                # Print side by side
                if [ ${#left_lines[@]} -gt 0 ] || [ ${#right_lines[@]} -gt 0 ]; then
                    # Use "CLIENTS" for bridges, "CIRCUITS" for relays
                    local _country_label="CIRCUITS BY COUNTRY"
                    local _any_b=false
                    for _li in $(seq 1 $count); do [ "$(get_container_relay_type $_li)" = "bridge" ] && _any_b=true; done
                    [ "$_any_b" = "true" ] && _country_label="CLIENTS BY COUNTRY"
                    printf "  ${GREEN}${BOLD}%-30s${NC} ${YELLOW}${BOLD}%s${NC}${EL}\n" "$_country_label" "TOP 5 UPLOAD (cumulative)"
                    local max_rows=${#left_lines[@]}
                    [ ${#right_lines[@]} -gt $max_rows ] && max_rows=${#right_lines[@]}
                    for ((ri=0; ri<max_rows; ri++)); do
                        local lc="${left_lines[$ri]:-}"
                        local rc="${right_lines[$ri]:-}"
                        if [ -n "$lc" ] && [ -n "$rc" ]; then
                            printf "  "
                            echo -ne "$lc"
                            printf "   "
                            echo -e "$rc${EL}"
                        elif [ -n "$lc" ]; then
                            printf "  "
                            echo -e "$lc${EL}"
                        elif [ -n "$rc" ]; then
                            printf "  %-30s " ""
                            echo -e "$rc${EL}"
                        fi
                    done
                fi
            fi

            echo -e "${EL}"
        else
            echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
            echo -e "  All $count container(s) are stopped.${EL}"
            echo -e "${EL}"
        fi

        # Snowflake stats
        if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
            echo -e "${CYAN}═══ Snowflake Proxy (WebRTC) ═══${NC}${EL}"
            if is_snowflake_running; then
                local sf_stats=$(get_snowflake_stats 2>/dev/null)
                local sf_conns=$(echo "$sf_stats" | awk '{print $1}')
                local sf_in=$(echo "$sf_stats" | awk '{print $2}')
                local sf_out=$(echo "$sf_stats" | awk '{print $3}')
                echo -e "  Status: ${GREEN}Running${NC}  Connections: ${GREEN}${sf_conns:-0}${NC}  Traffic: ↓ $(format_bytes ${sf_in:-0})  ↑ $(format_bytes ${sf_out:-0})${EL}"

                # Snowflake country breakdown (top 5)
                local sf_countries=$(get_snowflake_country_stats 2>/dev/null | head -5)
                if [ -n "$sf_countries" ]; then
                    local sf_total=0
                    while IFS='|' read -r cnt co; do
                        sf_total=$((sf_total + cnt))
                    done <<< "$sf_countries"
                    [ "$sf_total" -eq 0 ] && sf_total=1
                    while IFS='|' read -r cnt country; do
                        [ -z "$country" ] && continue
                        local pct=$((cnt * 100 / sf_total))
                        local _sfname=$(country_code_to_name "$country")
                        printf "  %-14s %3d%%  %5s connections${EL}\n" "$_sfname" "$pct" "$cnt"
                    done <<< "$sf_countries"
                fi
            else
                echo -e "  Status: ${RED}Stopped${NC}${EL}"
            fi
            echo -e "${EL}"
        fi

        # Per-container status (compact)
        if [ "$count" -gt 1 ]; then
            echo -e "${CYAN}═══ Per-Container ═══${NC}${EL}"
            for i in $(seq 1 $count); do
                local cname=$(get_container_name $i)
                local c_status="${RED}STOP${NC}"
                local c_info=""
                if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                    c_status="${GREEN} UP ${NC}"
                    local t=$(get_tor_traffic $i)
                    local rb=$(echo "$t" | awk '{print $1}')
                    local wb=$(echo "$t" | awk '{print $2}')
                    c_info="↓$(format_bytes $rb) ↑$(format_bytes $wb) C:$(get_tor_circuits $i)"
                fi
                printf "  %-14s [${c_status}] %s${EL}\n" "$cname" "$c_info"
            done
            echo -e "${EL}"
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return to menu...${NC}${EL}"

        # Clear leftover lines
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi

        # Wait 4s for keypress
        if read -t 4 -n 1 -s < /dev/tty 2>/dev/null; then
            stop_dashboard=1
        fi
    done

    _dashboard_cleanup
    trap - INT TERM RETURN
}

#═══════════════════════════════════════════════════════════════════════
# Advanced Stats (Phase 3)
#═══════════════════════════════════════════════════════════════════════

show_advanced_stats() {
    load_settings
    local stop_stats=0
    _stats_cleanup() {
        echo -ne "\033[?25h"
        tput rmcup 2>/dev/null || true
    }
    trap '_stats_cleanup; stop_stats=1' INT TERM
    trap '_stats_cleanup' RETURN

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    clear

    while [ $stop_stats -eq 0 ]; do
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi

        local EL="\033[K"
        local count=${CONTAINER_COUNT:-1}

        local _bar="═══════════════════════════════════════════════════════════════════"
        echo -e "${CYAN}╔${_bar}╗${NC}${EL}"
        printf "${CYAN}║${NC}  🧅 %-62s${CYAN}║${NC}${EL}\n" "TORWARE ADVANCED STATISTICS"
        echo -e "${CYAN}╚${_bar}╝${NC}${EL}"
        echo -e "${EL}"

        # Per-container detailed stats
        echo -e "${CYAN}═══ Container Details ═══${NC}${EL}"
        printf "  ${BOLD}%-14s %-8s %-10s %-10s %-8s %-8s %-8s${NC}${EL}\n" "Name" "Status" "Download" "Upload" "Circuits" "Conns" "CPU"

        local docker_stats_out
        docker_stats_out=$(timeout 10 docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" 2>/dev/null)

        for i in $(seq 1 $count); do
            local cname=$(get_container_name $i)
            local status="${RED}STOPPED${NC}"
            local dl="" ul="" circ="" conn="" cpu="" ram=""

            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                status="${GREEN}RUNNING${NC}"
                local t=$(get_tor_traffic $i)
                dl=$(format_bytes $(echo "$t" | awk '{print $1}'))
                ul=$(format_bytes $(echo "$t" | awk '{print $2}'))
                circ=$(get_tor_circuits $i)
                conn=$(get_tor_connections $i)
                cpu=$(echo "$docker_stats_out" | grep "^${cname} " | awk '{print $2}')
            fi
            printf "  %-14s %-20b %-10s %-10s %-8s %-8s %-8s${EL}\n" \
                "$cname" "$status" "${dl:-–}" "${ul:-–}" "${circ:-–}" "${conn:-–}" "${cpu:-–}"
        done

        # Snowflake row in advanced stats
        if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
            local sf_status="${RED}STOPPED${NC}"
            local sf_dl="" sf_ul="" sf_conns_adv="" sf_cpu=""
            if is_snowflake_running; then
                sf_status="${GREEN}RUNNING${NC}"
                local sf_s=$(get_snowflake_stats 2>/dev/null)
                sf_conns_adv=$(echo "$sf_s" | awk '{print $1}')
                sf_dl=$(format_bytes $(echo "$sf_s" | awk '{print $2}'))
                sf_ul=$(format_bytes $(echo "$sf_s" | awk '{print $3}'))
                sf_cpu=$(echo "$docker_stats_out" | grep "^${SNOWFLAKE_CONTAINER} " | awk '{print $2}')
            fi
            printf "  %-14s %-20b %-10s %-10s %-8s %-8s %-8s${EL}\n" \
                "snowflake" "$sf_status" "${sf_dl:-–}" "${sf_ul:-–}" "${sf_conns_adv:-–}" "–" "${sf_cpu:-–}"
        fi

        echo -e "${EL}"

        # Country charts from tracker data
        local data_file="$STATS_DIR/cumulative_data"
        local ips_file="$STATS_DIR/cumulative_ips"

        if [ -s "$data_file" ]; then
            echo -e "${CYAN}═══ Top 7 Countries by Upload (All-Time) ═══${NC}${EL}"
            local all_upload
            all_upload=$(awk -F'|' '{if($1!="" && $3+0>0) print $3"|"$1}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr)
            local top7_upload=$(echo "$all_upload" | head -7)
            local total_upload=0
            if [ -n "$all_upload" ]; then
                while IFS='|' read -r bytes co; do
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    total_upload=$((total_upload + bytes))
                done <<< "$all_upload"
            fi
            [ "$total_upload" -eq 0 ] && total_upload=1

            if [ -n "$top7_upload" ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    local pct=$((bytes * 100 / total_upload))
                    local bl=$((pct / 5)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 20 ] && bl=20
                    local bf=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done
                    printf "  %-14.14s %3d%% ${MAGENTA}%-20s${NC} %10s${EL}\n" "$country" "$pct" "$bf" "$(format_bytes $bytes)"
                done <<< "$top7_upload"
            fi
            echo -e "${EL}"

            echo -e "${CYAN}═══ Top 7 Countries by Download (All-Time) ═══${NC}${EL}"
            local all_download
            all_download=$(awk -F'|' '{if($1!="" && $2+0>0) print $2"|"$1}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr)
            local top7_download=$(echo "$all_download" | head -7)
            local total_download=0
            if [ -n "$all_download" ]; then
                while IFS='|' read -r bytes co; do
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    total_download=$((total_download + bytes))
                done <<< "$all_download"
            fi
            [ "$total_download" -eq 0 ] && total_download=1

            if [ -n "$top7_download" ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    local pct=$((bytes * 100 / total_download))
                    local bl=$((pct / 5)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 20 ] && bl=20
                    local bf=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done
                    printf "  %-14.14s %3d%% ${CYAN}%-20s${NC} %10s${EL}\n" "$country" "$pct" "$bf" "$(format_bytes $bytes)"
                done <<< "$top7_download"
            fi
            echo -e "${EL}"
        fi

        if [ -s "$ips_file" ]; then
            local total_ips
            total_ips=$(wc -l < "$ips_file" 2>/dev/null || echo "0")
            local unique_countries
            unique_countries=$(awk -F'|' '{print $1}' "$ips_file" 2>/dev/null | sort -u | wc -l)
            echo -e "  ${BOLD}Lifetime:${NC} ${GREEN}${total_ips}${NC} unique IPs from ${GREEN}${unique_countries}${NC} countries${EL}"
            echo -e "${EL}"
        fi

        echo -e "${BOLD}Refreshes every 15 seconds. Press any key to return...${NC}${EL}"

        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi

        if read -t 14 -n 1 -s < /dev/tty 2>/dev/null; then
            stop_stats=1
        fi
    done

    _stats_cleanup
    trap - INT TERM RETURN
}

#═══════════════════════════════════════════════════════════════════════
# Live Peers by Country (Phase 3)
#═══════════════════════════════════════════════════════════════════════

show_peers() {
    load_settings
    local stop_peers=0
    _peers_cleanup() {
        echo -ne "\033[?25h"
        tput rmcup 2>/dev/null || true
    }
    trap '_peers_cleanup; stop_peers=1' INT TERM
    trap '_peers_cleanup' RETURN

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    clear

    while [ $stop_peers -eq 0 ]; do
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi

        local EL="\033[K"
        local _bar="═══════════════════════════════════════════════════════════════════"
        echo -e "${CYAN}╔${_bar}╗${NC}${EL}"
        printf "${CYAN}║${NC}  🧅 %-62s${CYAN}║${NC}${EL}\n" "LIVE CONNECTIONS BY COUNTRY"
        echo -e "${CYAN}╚${_bar}╝${NC}${EL}"
        echo -e "${EL}"

        local snap_file="$STATS_DIR/tracker_snapshot"

        # If no tracker snapshot, try direct ControlPort query as fallback
        if [ ! -s "$snap_file" ]; then
            local _fb_lines=""
            for _pi in $(seq 1 $count); do
                local _pport=$(get_container_controlport $_pi)
                local _prtype=$(get_container_relay_type $_pi)
                if [ "$_prtype" = "bridge" ]; then
                    local _cs=$(controlport_query "$_pport" "GETINFO status/clients-seen" 2>/dev/null)
                    local _csdata=$(echo "$_cs" | sed -n 's/.*CountrySummary=\([^ \r]*\).*/\1/p' | head -1 2>/dev/null)
                    if [ -n "$_csdata" ]; then
                        IFS=',' read -ra _cse <<< "$_csdata"
                        for _ce in "${_cse[@]}"; do
                            local _cc=$(echo "$_ce" | cut -d= -f1)
                            local _cn=$(echo "$_ce" | cut -d= -f2)
                            [ -z "$_cc" ] || [ -z "$_cn" ] && continue
                            _fb_lines+="UP|$(country_code_to_name "$_cc")|${_cn}|bridge\n"
                        done
                    fi
                else
                    local _oc=$(controlport_query "$_pport" "GETINFO orconn-status" 2>/dev/null)
                    local _ips=$(echo "$_oc" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' 2>/dev/null | sort -u)
                    if [ -n "$_ips" ]; then
                        while read -r _ip; do
                            [ -z "$_ip" ] && continue
                            local _geo=$(tor_geo_lookup "$_ip" 2>/dev/null)
                            _fb_lines+="UP|${_geo:-Unknown}|1|${_ip}\n"
                        done <<< "$_ips"
                    fi
                fi
            done
            if [ -n "$_fb_lines" ]; then
                printf '%b' "$_fb_lines" > "$snap_file.tmp.$$"
                mv "$snap_file.tmp.$$" "$snap_file"
            fi
        fi

        if [ -s "$snap_file" ]; then
            local snap_data
            snap_data=$(awk -F'|' '{c[$2]+=$3} END{for(co in c) if(co!="") print c[co]"|"co}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr)

            if [ -n "$snap_data" ]; then
                local total=0
                while IFS='|' read -r cnt co; do
                    total=$((total + cnt))
                done <<< "$snap_data"
                [ "$total" -eq 0 ] && total=1

                printf "  ${BOLD}%-20s %6s %8s   %-30s${NC}${EL}\n" "Country" "Traffic" "Pct" "Activity"

                while IFS='|' read -r cnt country; do
                    [ -z "$country" ] && continue
                    local pct=$((cnt * 100 / total))
                    local bl=$((pct / 5)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 20 ] && bl=20
                    local bf=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done
                    printf "  %-20.20s %6s %7d%%   ${GREEN}%s${NC}${EL}\n" "$country" "$(format_bytes $cnt)" "$pct" "$bf"
                done <<< "$snap_data"
            else
                echo -e "  ${DIM}No circuit or client data available yet.${NC}${EL}"
            fi
        else
            echo -e "  ${DIM}No connections yet. Bridge may still be bootstrapping.${NC}${EL}"
            echo -e "  ${DIM}New bridges can take hours to receive clients from Tor's distributor.${NC}${EL}"
        fi

        # Snowflake section
        if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running; then
            echo -e "${EL}"
            echo -e "${CYAN}═══ Snowflake Proxy (WebRTC) ═══${NC}${EL}"
            local _sf_country
            _sf_country=$(get_snowflake_country_stats 2>/dev/null)
            local _sf_stats
            _sf_stats=$(get_snowflake_stats 2>/dev/null)
            local _sf_conns=$(echo "$_sf_stats" | awk '{print $1}')
            local _sf_in=$(echo "$_sf_stats" | awk '{print $2}')
            local _sf_out=$(echo "$_sf_stats" | awk '{print $3}')
            echo -e "  Total connections: ${GREEN}${_sf_conns:-0}${NC}  Traffic: ↓ $(format_bytes ${_sf_in:-0})  ↑ $(format_bytes ${_sf_out:-0})${EL}"

            if [ -n "$_sf_country" ]; then
                local _sf_total=0
                while IFS='|' read -r _sc _sco; do
                    _sf_total=$((_sf_total + _sc))
                done <<< "$_sf_country"
                [ "$_sf_total" -eq 0 ] && _sf_total=1
                echo -e "${EL}"
                printf "  ${BOLD}%-20s %6s %8s   %-30s${NC}${EL}\n" "Country" "Conns" "Pct" "Activity"
                echo "$_sf_country" | head -15 | while IFS='|' read -r _scnt _scountry; do
                    [ -z "$_scountry" ] && continue
                    _scountry=$(country_code_to_name "$_scountry")
                    local _spct=$((_scnt * 100 / _sf_total))
                    local _sbl=$((_spct / 5)); [ "$_sbl" -lt 1 ] && _sbl=1; [ "$_sbl" -gt 20 ] && _sbl=20
                    local _sbf=""; for ((_si=0; _si<_sbl; _si++)); do _sbf+="█"; done
                    printf "  %-20.20s %6s %7d%%   ${MAGENTA}%s${NC}${EL}\n" "$_scountry" "$_scnt" "$_spct" "$_sbf"
                done
            else
                echo -e "  ${DIM}No Snowflake clients yet. Waiting for broker to assign connections...${NC}${EL}"
            fi
        fi

        echo -e "${EL}"
        echo -e "${BOLD}Refreshes every 15 seconds. Press any key to return...${NC}${EL}"

        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi

        if read -t 14 -n 1 -s < /dev/tty 2>/dev/null; then
            stop_peers=1
        fi
    done

    _peers_cleanup
    trap - INT TERM RETURN
}

#═══════════════════════════════════════════════════════════════════════
# Background Tracker Service (Phase 3)
#═══════════════════════════════════════════════════════════════════════

is_tracker_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active torware-tracker.service &>/dev/null
        return $?
    fi
    pgrep -f "torware-tracker.sh" &>/dev/null
}

geo_lookup() {
    local ip="$1"
    local cache_file="$STATS_DIR/geoip_cache"

    # Check cache
    if [ -f "$cache_file" ]; then
        local cached
        local escaped_ip="${ip//./\\.}"
        cached=$(grep "^${escaped_ip}|" "$cache_file" 2>/dev/null | head -1 | cut -d'|' -f2)
        if [ -n "$cached" ]; then
            echo "$cached"
            return
        fi
    fi

    # Try Tor's built-in GeoIP via ControlPort
    local country=""
    local port=$(get_container_controlport 1)
    local result
    result=$(controlport_query "$port" "GETINFO ip-to-country/$ip" 2>/dev/null)
    local code
    code=$(echo "$result" | sed -n "s/.*ip-to-country\/$ip=\([a-z]*\).*/\1/p" | head -1 2>/dev/null)

    if [ -n "$code" ] && [ "$code" != "??" ]; then
        country=$(country_code_to_name "$code")
    fi

    # Fallback to system GeoIP
    if [ -z "$country" ]; then
        if command -v geoiplookup &>/dev/null; then
            country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{gsub(/^ +/,"",$2); print $2}' | head -1)
            country=$(echo "$country" | sed 's/,.*//')
        elif command -v mmdblookup &>/dev/null; then
            local db=""
            [ -f /usr/share/GeoIP/GeoLite2-Country.mmdb ] && db="/usr/share/GeoIP/GeoLite2-Country.mmdb"
            [ -f /var/lib/GeoIP/GeoLite2-Country.mmdb ] && db="/var/lib/GeoIP/GeoLite2-Country.mmdb"
            if [ -n "$db" ]; then
                country=$(mmdblookup --file "$db" --ip "$ip" country names en 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')
            fi
        fi
    fi

    [ -z "$country" ] && country="Unknown"
    # Sanitize country name (strip pipe, newlines, control chars)
    country=$(printf '%s' "$country" | tr -d '|\n\r' | tr -cd '[:print:]' | head -c 50)
    [ -z "$country" ] && country="Unknown"

    # Cache it
    if [ -n "$cache_file" ]; then
        mkdir -p "$(dirname "$cache_file")"
        [ ! -f "$cache_file" ] && ( umask 077; touch "$cache_file" )
        echo "${ip}|${country}" >> "$cache_file"
        # Trim cache if too large
        local cache_lines
        cache_lines=$(wc -l < "$cache_file" 2>/dev/null || echo "0")
        if [ "$cache_lines" -gt 10000 ]; then
            tail -5000 "$cache_file" > "${cache_file}.tmp"
            mv "${cache_file}.tmp" "$cache_file"
        fi
    fi

    echo "$country"
}

regenerate_tracker_script() {
    mkdir -p "$STATS_DIR"

    cat > "$INSTALL_DIR/torware-tracker.sh" << 'TRACKER_EOF'
#!/bin/bash
# Torware Tracker - Background ControlPort Monitor
# Generated by torware.sh

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "Error: torware-tracker requires bash 4+ (for associative arrays)" >&2
    exit 1
fi

INSTALL_DIR="REPLACE_INSTALL_DIR"
STATS_DIR="$INSTALL_DIR/relay_stats"
CONTROLPORT_BASE=REPLACE_CONTROLPORT_BASE
CONTAINER_COUNT=REPLACE_CONTAINER_COUNT

mkdir -p "$STATS_DIR"

# Source settings (with whitelist validation)
if [ -f "$INSTALL_DIR/settings.conf" ]; then
    if ! grep -vE '^\s*$|^\s*#|^[A-Za-z_][A-Za-z0-9_]*='\''[^'\'']*'\''$|^[A-Za-z_][A-Za-z0-9_]*=[0-9]+$|^[A-Za-z_][A-Za-z0-9_]*=(true|false)$' "$INSTALL_DIR/settings.conf" 2>/dev/null | grep -q .; then
        source "$INSTALL_DIR/settings.conf"
    fi
fi

get_nc_cmd() {
    if command -v ncat &>/dev/null; then echo "ncat"
    elif command -v nc &>/dev/null; then echo "nc"
    else echo ""; fi
}

get_control_cookie() {
    local idx=$1
    local vol="relay-data-${idx}"
    local cache_file="${TMPDIR:-/tmp}/.tor_cookie_cache_${idx}"
    [ -L "$cache_file" ] && rm -f "$cache_file"
    if [ -f "$cache_file" ]; then
        local mtime
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt 60 ] && [ "$age" -ge 0 ]; then cat "$cache_file"; return; fi
    fi
    local cookie
    cookie=$(docker run --rm -v "${vol}:/data:ro" alpine \
        sh -c 'od -A n -t x1 /data/control_auth_cookie 2>/dev/null | tr -d " \n"' 2>/dev/null)
    if [ -n "$cookie" ]; then
        ( umask 077; echo "$cookie" > "$cache_file" )
    fi
    echo "$cookie"
}

controlport_query() {
    local port=$1; shift
    local nc_cmd=$(get_nc_cmd)
    [ -z "$nc_cmd" ] && return 1
    local idx=$((port - CONTROLPORT_BASE + 1))
    local cookie=$(get_control_cookie $idx)
    [ -z "$cookie" ] && return 1
    {
        printf 'AUTHENTICATE %s\r\n' "$cookie"
        for cmd in "$@"; do printf "%s\r\n" "$cmd"; done
        printf "QUIT\r\n"
    } | timeout 5 "$nc_cmd" 127.0.0.1 "$port" 2>/dev/null | tr -d '\r'
}

country_code_to_name() {
    local cc="$1"
    case "$cc" in
        # Americas (18)
        us) echo "United States" ;; ca) echo "Canada" ;; mx) echo "Mexico" ;;
        br) echo "Brazil" ;; ar) echo "Argentina" ;; co) echo "Colombia" ;;
        cl) echo "Chile" ;; pe) echo "Peru" ;; ve) echo "Venezuela" ;;
        ec) echo "Ecuador" ;; bo) echo "Bolivia" ;; py) echo "Paraguay" ;;
        uy) echo "Uruguay" ;; cu) echo "Cuba" ;; cr) echo "Costa Rica" ;;
        pa) echo "Panama" ;; do) echo "Dominican Rep." ;; gt) echo "Guatemala" ;;
        # Europe West (16)
        gb|uk) echo "United Kingdom" ;; de) echo "Germany" ;; fr) echo "France" ;;
        nl) echo "Netherlands" ;; be) echo "Belgium" ;; at) echo "Austria" ;;
        ch) echo "Switzerland" ;; ie) echo "Ireland" ;; lu) echo "Luxembourg" ;;
        es) echo "Spain" ;; pt) echo "Portugal" ;; it) echo "Italy" ;;
        gr) echo "Greece" ;; mt) echo "Malta" ;; cy) echo "Cyprus" ;;
        is) echo "Iceland" ;;
        # Europe North (7)
        se) echo "Sweden" ;; no) echo "Norway" ;; fi) echo "Finland" ;;
        dk) echo "Denmark" ;; ee) echo "Estonia" ;; lv) echo "Latvia" ;;
        lt) echo "Lithuania" ;;
        # Europe East (16)
        pl) echo "Poland" ;; cz) echo "Czech Rep." ;; sk) echo "Slovakia" ;;
        hu) echo "Hungary" ;; ro) echo "Romania" ;; bg) echo "Bulgaria" ;;
        hr) echo "Croatia" ;; rs) echo "Serbia" ;; si) echo "Slovenia" ;;
        ba) echo "Bosnia" ;; mk) echo "N. Macedonia" ;; al) echo "Albania" ;;
        me) echo "Montenegro" ;; ua) echo "Ukraine" ;; md) echo "Moldova" ;;
        by) echo "Belarus" ;;
        # Russia & Central Asia (6)
        ru) echo "Russia" ;; kz) echo "Kazakhstan" ;; uz) echo "Uzbekistan" ;;
        tm) echo "Turkmenistan" ;; kg) echo "Kyrgyzstan" ;; tj) echo "Tajikistan" ;;
        # Middle East (10)
        tr) echo "Turkey" ;; il) echo "Israel" ;; sa) echo "Saudi Arabia" ;;
        ae) echo "UAE" ;; ir) echo "Iran" ;; iq) echo "Iraq" ;;
        sy) echo "Syria" ;; jo) echo "Jordan" ;; lb) echo "Lebanon" ;;
        qa) echo "Qatar" ;;
        # Africa (12)
        za) echo "South Africa" ;; ng) echo "Nigeria" ;; ke) echo "Kenya" ;;
        eg) echo "Egypt" ;; ma) echo "Morocco" ;; tn) echo "Tunisia" ;;
        gh) echo "Ghana" ;; et) echo "Ethiopia" ;; tz) echo "Tanzania" ;;
        ug) echo "Uganda" ;; dz) echo "Algeria" ;; ly) echo "Libya" ;;
        # Asia East (8)
        cn) echo "China" ;; jp) echo "Japan" ;; kr) echo "South Korea" ;;
        tw) echo "Taiwan" ;; hk) echo "Hong Kong" ;; mn) echo "Mongolia" ;;
        kp) echo "North Korea" ;; mo) echo "Macau" ;;
        # Asia South & Southeast (14)
        in) echo "India" ;; pk) echo "Pakistan" ;; bd) echo "Bangladesh" ;;
        np) echo "Nepal" ;; lk) echo "Sri Lanka" ;; mm) echo "Myanmar" ;;
        th) echo "Thailand" ;; vn) echo "Vietnam" ;; ph) echo "Philippines" ;;
        id) echo "Indonesia" ;; my) echo "Malaysia" ;; sg) echo "Singapore" ;;
        kh) echo "Cambodia" ;; la) echo "Laos" ;;
        # Oceania & Caucasus (6)
        au) echo "Australia" ;; nz) echo "New Zealand" ;; ge) echo "Georgia" ;;
        am) echo "Armenia" ;; az) echo "Azerbaijan" ;; bh) echo "Bahrain" ;;
        mu) echo "Mauritius" ;; zm) echo "Zambia" ;; sd) echo "Sudan" ;;
        zw) echo "Zimbabwe" ;; mz) echo "Mozambique" ;; cm) echo "Cameroon" ;;
        ci) echo "Ivory Coast" ;; sn) echo "Senegal" ;; cd) echo "DR Congo" ;;
        ao) echo "Angola" ;; om) echo "Oman" ;; kw) echo "Kuwait" ;;
        '??') echo "Unknown" ;;
        *) echo "$cc" | tr '[:lower:]' '[:upper:]' ;;
    esac
}

# GeoIP lookup (simple version for tracker)
geo_lookup() {
    local ip="$1"
    local cache_file="$STATS_DIR/geoip_cache"
    if [ -f "$cache_file" ]; then
        local escaped_ip=$(printf '%s' "$ip" | sed 's/[.]/\\./g')
        local cached=$(grep "^${escaped_ip}|" "$cache_file" 2>/dev/null | head -1 | cut -d'|' -f2)
        [ -n "$cached" ] && echo "$cached" && return
    fi

    local port=$((CONTROLPORT_BASE))
    local result=$(controlport_query "$port" "GETINFO ip-to-country/$ip" 2>/dev/null)
    local sed_safe_ip=$(printf '%s' "$ip" | sed 's/[.]/\\./g; s/[/]/\\//g')
    local code=$(echo "$result" | sed -n "s/.*ip-to-country\/${sed_safe_ip}=\([a-z]*\).*/\1/p" | head -1 2>/dev/null)
    local country=""

    if [ -n "$code" ] && [ "$code" != "??" ]; then
        country=$(country_code_to_name "$code")
    fi

    if [ -z "$country" ] && command -v geoiplookup &>/dev/null; then
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{gsub(/^ +/,"",$2); print $2}' | head -1 | sed 's/,.*//')
    fi

    [ -z "$country" ] && country="Unknown"

    mkdir -p "$(dirname "$cache_file")"
    [ ! -f "$cache_file" ] && ( umask 077; touch "$cache_file" )
    echo "${ip}|${country}" >> "$cache_file"
    cl=$(wc -l < "$cache_file" 2>/dev/null || echo "0")
    [ "$cl" -gt 10000 ] && { tail -5000 "$cache_file" > "${cache_file}.tmp"; mv "${cache_file}.tmp" "$cache_file"; }

    echo "$country"
}

# Track previous traffic totals per container for delta calculation
declare -A prev_read prev_written

# Determine relay type for each container
get_relay_type_for() {
    local idx=$1
    local var="RELAY_TYPE_${idx}"
    local val="${!var}"
    if [ -n "$val" ]; then echo "$val"; else echo "${RELAY_TYPE:-bridge}"; fi
}

# Main tracker loop
while true; do
    # Reload settings safely
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        if ! grep -vE '^\s*$|^\s*#|^[A-Za-z_][A-Za-z0-9_]*='\''[^'\'']*'\''$|^[A-Za-z_][A-Za-z0-9_]*=[0-9]+$|^[A-Za-z_][A-Za-z0-9_]*=(true|false)$' "$INSTALL_DIR/settings.conf" 2>/dev/null | grep -q .; then
            source "$INSTALL_DIR/settings.conf"
        fi
    fi

    # Collect data from all containers (unset first to clear stale keys)
    unset country_up country_down 2>/dev/null
    declare -A country_up country_down
    snap_lines=""

    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        port=$((CONTROLPORT_BASE + i - 1))
        cname="torware"
        [ "$i" -gt 1 ] && cname="torware-${i}"

        # Check if running
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" || continue

        rtype=$(get_relay_type_for $i)

        if [ "$rtype" = "bridge" ]; then
            # --- BRIDGE: Use Tor's native CLIENTS_SEEN for country data ---
            # This is Tor's built-in GeoIP-resolved per-country client count
            clients_seen=$(controlport_query "$port" "GETINFO status/clients-seen" 2>/dev/null)
            country_summary=$(echo "$clients_seen" | sed -n 's/.*CountrySummary=\([^ \r]*\).*/\1/p' | head -1 2>/dev/null)

            if [ -n "$country_summary" ]; then
                # Parse cc=num,cc=num,...
                IFS=',' read -ra cc_entries <<< "$country_summary"
                for entry in "${cc_entries[@]}"; do
                    cc=$(echo "$entry" | cut -d= -f1)
                    num=$(echo "$entry" | cut -d= -f2)
                    [ -z "$cc" ] || [ -z "$num" ] && continue
                    country=$(country_code_to_name "$cc")
                    snap_lines+="UP|${country}|${num}|bridge\n"
                done
            fi
        else
            # --- RELAY: Use orconn-status to get peer relay IPs, then GeoIP ---
            orconn=$(controlport_query "$port" "GETINFO orconn-status" 2>/dev/null)
            ips=$(echo "$orconn" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' 2>/dev/null | awk -F. '{if($1<=255 && $2<=255 && $3<=255 && $4<=255) print}' | sort -u)

            # Resolve all IPs once and cache country per IP for reuse in traffic distribution
            unset _ip_country 2>/dev/null
            declare -A _ip_country
            if [ -n "$ips" ]; then
                while read -r ip; do
                    [ -z "$ip" ] && continue
                    country=$(geo_lookup "$ip")
                    _ip_country["$ip"]="$country"
                    snap_lines+="UP|${country}|1|${ip}\n"

                    if ! grep -qF "${country}|${ip}" "$STATS_DIR/cumulative_ips" 2>/dev/null; then
                        echo "${country}|${ip}" >> "$STATS_DIR/cumulative_ips"
                        # Cap cumulative_ips at 50000 lines
                        ip_lines=$(wc -l < "$STATS_DIR/cumulative_ips" 2>/dev/null || echo 0)
                        if [ "$ip_lines" -gt 50000 ]; then
                            tail -25000 "$STATS_DIR/cumulative_ips" > "$STATS_DIR/cumulative_ips.tmp"
                            mv "$STATS_DIR/cumulative_ips.tmp" "$STATS_DIR/cumulative_ips"
                        fi
                    fi
                done <<< "$ips"
            fi
        fi

        # Get traffic totals and compute deltas (works for all relay types)
        traffic=$(controlport_query "$port" "GETINFO traffic/read" "GETINFO traffic/written" 2>/dev/null)
        rb=$(echo "$traffic" | sed -n 's/.*traffic\/read=\([0-9]*\).*/\1/p' | head -1)
        wb=$(echo "$traffic" | sed -n 's/.*traffic\/written=\([0-9]*\).*/\1/p' | head -1)
        [ -z "$rb" ] && rb=0
        [ -z "$wb" ] && wb=0

        # Compute deltas from previous reading (fixes double-counting)
        p_rb=${prev_read[$i]:-0}
        p_wb=${prev_written[$i]:-0}
        delta_rb=$((rb - p_rb))
        delta_wb=$((wb - p_wb))
        # Handle container restart (counter reset)
        [ "$delta_rb" -lt 0 ] && delta_rb=$rb
        [ "$delta_wb" -lt 0 ] && delta_wb=$wb
        prev_read[$i]=$rb
        prev_written[$i]=$wb

        if [ "$rtype" = "bridge" ]; then
            # For bridges, distribute traffic evenly across seen countries
            if [ -n "$country_summary" ]; then
                total_clients=0
                IFS=',' read -ra cc_entries <<< "$country_summary"
                for entry in "${cc_entries[@]}"; do
                    num=$(echo "$entry" | cut -d= -f2)
                    total_clients=$((total_clients + ${num:-0}))
                done
                [ "$total_clients" -eq 0 ] && total_clients=1
                for entry in "${cc_entries[@]}"; do
                    cc=$(echo "$entry" | cut -d= -f1)
                    num=$(echo "$entry" | cut -d= -f2)
                    [ -z "$cc" ] || [ -z "$num" ] && continue
                    country=$(country_code_to_name "$cc")
                    frac_up=$((delta_wb * num / total_clients))
                    frac_down=$((delta_rb * num / total_clients))
                    country_up["$country"]=$(( ${country_up["$country"]:-0} + frac_up ))
                    country_down["$country"]=$(( ${country_down["$country"]:-0} + frac_down ))
                done
            fi
        else
            # For relays, distribute delta traffic using cached country lookups (no repeat geo_lookup)
            ip_count=${#_ip_country[@]}
            [ "$ip_count" -eq 0 ] && ip_count=1
            per_ip_up=$((delta_wb / ip_count))
            per_ip_down=$((delta_rb / ip_count))

            for ip in "${!_ip_country[@]}"; do
                country="${_ip_country[$ip]}"
                country_up["$country"]=$(( ${country_up["$country"]:-0} + per_ip_up ))
                country_down["$country"]=$(( ${country_down["$country"]:-0} + per_ip_down ))
            done
            unset _ip_country
        fi
    done

    # Write tracker snapshot atomically (last 15s window)
    if [ -n "$snap_lines" ]; then
        printf '%b' "$snap_lines" > "$STATS_DIR/tracker_snapshot.tmp.$$"
        mv "$STATS_DIR/tracker_snapshot.tmp.$$" "$STATS_DIR/tracker_snapshot"
    fi

    # Merge into cumulative_data (country|from_bytes|to_bytes)
    if [ ${#country_up[@]} -gt 0 ] || [ ${#country_down[@]} -gt 0 ]; then
        tmp_cum="$STATS_DIR/cumulative_data.tmp.$$"

        unset cum_down cum_up 2>/dev/null
        declare -A cum_down cum_up
        if [ -f "$STATS_DIR/cumulative_data" ]; then
            while IFS='|' read -r co dl ul; do
                [ -z "$co" ] && continue
                cum_down["$co"]=$((${cum_down["$co"]:-0} + ${dl:-0}))
                cum_up["$co"]=$((${cum_up["$co"]:-0} + ${ul:-0}))
            done < "$STATS_DIR/cumulative_data"
        fi

        for co in "${!country_down[@]}"; do
            cum_down["$co"]=$((${cum_down["$co"]:-0} + ${country_down["$co"]:-0}))
        done
        for co in "${!country_up[@]}"; do
            cum_up["$co"]=$((${cum_up["$co"]:-0} + ${country_up["$co"]:-0}))
        done

        > "$tmp_cum"
        for co in $(echo "${!cum_down[@]} ${!cum_up[@]}" | tr ' ' '\n' | sort -u); do
            echo "${co}|${cum_down["$co"]:-0}|${cum_up["$co"]:-0}" >> "$tmp_cum"
        done
        mv "$tmp_cum" "$STATS_DIR/cumulative_data"

        unset cum_down cum_up
    fi

    unset country_up country_down

    # Uptime tracking
    running=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        cname="torware"
        [ "$i" -gt 1 ] && cname="torware-${i}"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" && running=$((running + 1))
    done
    echo "$(date +%s)|${running}" >> "$STATS_DIR/uptime_log"

    # Rotate uptime log: trim at 10080 entries (~7 days at 15s intervals), keep 7200 (~5 days)
    ul_lines=$(wc -l < "$STATS_DIR/uptime_log" 2>/dev/null || echo "0")
    if [ "$ul_lines" -gt 10080 ]; then
        tail -7200 "$STATS_DIR/uptime_log" > "$STATS_DIR/uptime_log.tmp"
        mv "$STATS_DIR/uptime_log.tmp" "$STATS_DIR/uptime_log"
    fi

    sleep 15
done
TRACKER_EOF

    # Replace placeholders (portable sed without -i)
    # Escape & and \ for sed replacement; use # as delimiter (safe for paths)
    local escaped_dir=$(printf '%s\n' "$INSTALL_DIR" | sed 's/[&\\]/\\&/g')
    sed "s#REPLACE_INSTALL_DIR#${escaped_dir}#g" "$INSTALL_DIR/torware-tracker.sh" > "$INSTALL_DIR/torware-tracker.sh.tmp" && mv "$INSTALL_DIR/torware-tracker.sh.tmp" "$INSTALL_DIR/torware-tracker.sh"
    sed "s#REPLACE_CONTROLPORT_BASE#$CONTROLPORT_BASE#g" "$INSTALL_DIR/torware-tracker.sh" > "$INSTALL_DIR/torware-tracker.sh.tmp" && mv "$INSTALL_DIR/torware-tracker.sh.tmp" "$INSTALL_DIR/torware-tracker.sh"
    sed "s#REPLACE_CONTAINER_COUNT#${CONTAINER_COUNT:-1}#g" "$INSTALL_DIR/torware-tracker.sh" > "$INSTALL_DIR/torware-tracker.sh.tmp" && mv "$INSTALL_DIR/torware-tracker.sh.tmp" "$INSTALL_DIR/torware-tracker.sh"

    chmod +x "$INSTALL_DIR/torware-tracker.sh"
}

setup_tracker_service() {
    regenerate_tracker_script

    # Detect systemd if not already set
    if [ -z "$HAS_SYSTEMD" ]; then
        if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
            HAS_SYSTEMD=true
        else
            HAS_SYSTEMD=false
        fi
    fi

    if [ "$HAS_SYSTEMD" = "true" ]; then
        cat > /etc/systemd/system/torware-tracker.service << EOF
[Unit]
Description=Torware Traffic Tracker
After=network.target docker.service
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/bin/bash "${INSTALL_DIR}/torware-tracker.sh"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable torware-tracker.service 2>/dev/null || true
        systemctl start torware-tracker.service 2>/dev/null || true
        log_success "Tracker service started"
    else
        log_warn "Tracker service requires systemd. Run manually: bash $INSTALL_DIR/torware-tracker.sh &"
    fi
}

stop_tracker_service() {
    if [ "$HAS_SYSTEMD" = "true" ]; then
        systemctl stop torware-tracker.service 2>/dev/null || true
    fi
    pkill -f "torware-tracker.sh" 2>/dev/null || true
}

#═══════════════════════════════════════════════════════════════════════
# Telegram Integration (Phase 4)
#═══════════════════════════════════════════════════════════════════════

telegram_send_message() {
    local msg="$1"
    local token="${TELEGRAM_BOT_TOKEN}"
    local chat_id="${TELEGRAM_CHAT_ID}"

    { [ -z "$token" ] || [ -z "$chat_id" ]; } && return 1

    # Add server label + IP header
    local label="${TELEGRAM_SERVER_LABEL:-Torware}"
    local ip
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 3 https://ifconfig.me 2>/dev/null \
        || echo "")
    local escaped_label=$(escape_md "$label")
    local header
    if [ -n "$ip" ]; then
        header="[${escaped_label} | ${ip}]"
    else
        header="[${escaped_label}]"
    fi

    local full_msg="${header} ${msg}"

    # Use curl config file to avoid leaking token in process list
    local _curl_cfg
    _curl_cfg=$(mktemp "${TMPDIR:-/tmp}/.tg_curl.XXXXXX") || return 1
    chmod 600 "$_curl_cfg"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" > "$_curl_cfg"
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -X POST \
        -K "$_curl_cfg" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${full_msg}" \
        --data-urlencode "parse_mode=Markdown" \
        2>/dev/null)
    local rc=$?
    rm -f "$_curl_cfg"
    [ $rc -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

telegram_get_chat_id() {
    local token="${TELEGRAM_BOT_TOKEN}"
    [ -z "$token" ] && return 1
    local _curl_cfg
    _curl_cfg=$(mktemp "${TMPDIR:-/tmp}/.tg_curl.XXXXXX") || return 1
    chmod 600 "$_curl_cfg"
    printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$token" > "$_curl_cfg"
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -K "$_curl_cfg" 2>/dev/null)
    rm -f "$_curl_cfg"
    [ -z "$response" ] && return 1
    echo "$response" | grep -q '"ok":true' || return 1

    local chat_id=""
    if command -v python3 &>/dev/null; then
        chat_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    msgs=d.get('result',[])
    if msgs:
        print(msgs[-1]['message']['chat']['id'])
except: pass
" <<< "$response" 2>/dev/null)
    fi
    # Fallback: POSIX-compatible grep extraction
    if [ -z "$chat_id" ]; then
        chat_id=$(echo "$response" | grep -o '"chat"[[:space:]]*:[[:space:]]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-*[0-9]*' | grep -o -- '-*[0-9]*$' | tail -1 2>/dev/null)
    fi
    if [ -n "$chat_id" ]; then
        if ! echo "$chat_id" | grep -qE '^-?[0-9]+$'; then
            return 1
        fi
        TELEGRAM_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

telegram_test_message() {
    local interval_label="${TELEGRAM_INTERVAL:-6}"
    local container_count="${CONTAINER_COUNT:-1}"

    local report=$(telegram_build_report_text)

    local message="✅ *Torware Monitor Connected!*

🧅 *What is Torware?*
You are running a Tor relay node helping people in censored regions access the open internet.

📬 *What this bot sends every ${interval_label}h:*
Container status, uptime, circuits, CPU/RAM, data cap & fingerprints.

⚠️ *Alerts:*
High CPU, high RAM, all containers down, or zero connections 2+ hours.

━━━━━━━━━━━━━━━━━━━━
🎮 *Available Commands:*
━━━━━━━━━━━━━━━━━━━━
/tor\_status — Full status report
/tor\_peers — Current connections
/tor\_uptime — Container uptime
/tor\_containers — Container list
/tor\_snowflake — Snowflake proxy details
/tor\_start\_N / /tor\_stop\_N / /tor\_restart\_N
/tor\_help — Show all commands

${report}"

    telegram_send_message "$message"
}

telegram_build_report_text() {
    load_settings
    local count=${CONTAINER_COUNT:-1}
    local report="📊 *Torware Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'

    # Container status & uptime
    local running=0
    local total_read=0 total_written=0 total_circuits=0 total_conns=0
    local earliest_start=""

    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            running=$((running + 1))
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -n "$started" ]; then
                local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
                    earliest_start=$se
                fi
            fi
            local traffic=$(get_tor_traffic $i)
            local rb=$(echo "$traffic" | awk '{print $1}'); rb=${rb:-0}
            local wb=$(echo "$traffic" | awk '{print $2}'); wb=${wb:-0}
            total_read=$((total_read + rb))
            total_written=$((total_written + wb))
            local circ=$(get_tor_circuits $i); circ=${circ//[^0-9]/}; circ=${circ:-0}
            total_circuits=$((total_circuits + circ))
            local conn=$(get_tor_connections $i); conn=${conn//[^0-9]/}; conn=${conn:-0}
            total_conns=$((total_conns + conn))
        fi
    done

    # Include snowflake in totals
    local total_containers=$count
    local total_running=$running
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        total_containers=$((total_containers + 1))
        if is_snowflake_running 2>/dev/null; then
            total_running=$((total_running + 1))
            local sf_stats=$(get_snowflake_stats 2>/dev/null)
            local sf_in=$(echo "$sf_stats" | awk '{print $2}'); sf_in=${sf_in:-0}
            local sf_out=$(echo "$sf_stats" | awk '{print $3}'); sf_out=${sf_out:-0}
            total_read=$((total_read + sf_in))
            total_written=$((total_written + sf_out))
        fi
    fi

    # Uptime from earliest container
    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        local now=$(date +%s)
        local up=$((now - earliest_start))
        local days=$((up / 86400)) hours=$(( (up % 86400) / 3600 )) mins=$(( (up % 3600) / 60 ))
        if [ "$days" -gt 0 ]; then
            report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
        else
            report+="⏱ Uptime: ${hours}h ${mins}m"
        fi
        report+=$'\n'
    fi

    report+="📦 Containers: ${total_running}/${total_containers} running"
    report+=$'\n'
    report+="🔗 Circuits: ${total_circuits} | Connections: ${total_conns}"
    report+=$'\n'
    report+="📊 Traffic: ↓ $(format_bytes $total_read) ↑ $(format_bytes $total_written)"
    report+=$'\n'

    # CPU / RAM (system-wide)
    local stats=$(get_container_stats 2>/dev/null)
    if [ -n "$stats" ]; then
        local raw_cpu=$(echo "$stats" | awk '{print $1}')
        local cores=$(get_cpu_cores)
        local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
        local sys_ram=""
        if command -v free &>/dev/null; then
            local free_out=$(free -m 2>/dev/null)
            local ram_used=$(echo "$free_out" | awk '/^Mem:/{if ($3>=1024) printf "%.1fGiB",$3/1024; else printf "%dMiB",$3}')
            local ram_total=$(echo "$free_out" | awk '/^Mem:/{if ($2>=1024) printf "%.1fGiB",$2/1024; else printf "%dMiB",$2}')
            sys_ram="${ram_used} / ${ram_total}"
        fi
        if [ -n "$sys_ram" ]; then
            report+="🖥 CPU: ${cpu} | RAM: ${sys_ram}"
        else
            local ram=$(echo "$stats" | awk '{print $2, $3, $4}')
            report+="🖥 CPU: ${cpu} | RAM: ${ram}"
        fi
        report+=$'\n'
    fi

    # Fingerprints
    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            local fp=$(get_tor_fingerprint $i 2>/dev/null)
            if [ -n "$fp" ]; then
                local rtype=$(get_container_relay_type $i)
                report+="🆔 C${i} [${rtype}]: ${fp}"
                report+=$'\n'
            fi
        fi
    done

    # Snowflake details
    if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running 2>/dev/null; then
        local sf_stats=$(get_snowflake_stats 2>/dev/null)
        local sf_conns=$(echo "$sf_stats" | awk '{print $1}'); sf_conns=${sf_conns:-0}
        local sf_in=$(echo "$sf_stats" | awk '{print $2}'); sf_in=${sf_in:-0}
        local sf_out=$(echo "$sf_stats" | awk '{print $3}'); sf_out=${sf_out:-0}
        local sf_total=$((sf_in + sf_out))
        report+="❄ Snowflake: ${sf_conns} conns | $(format_bytes $sf_total) transferred"
        report+=$'\n'
    fi

    echo "$report"
}

telegram_build_report() {
    local msg=$(telegram_build_report_text)
    telegram_send_message "$msg"
}

telegram_setup_wizard() {
    # Save and restore variables on Ctrl+C
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Tor Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_tor_relay_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${BOLD}Recommended:${NC} Send these commands to @BotFather:"
    echo -e "     ${YELLOW}/setjoingroups${NC} → Disable (prevents adding to groups)"
    echo -e "     ${YELLOW}/setprivacy${NC}   → Enable (limits message access)"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram notifications creates"
    echo -e "  outbound connections to api.telegram.org from this server."
    echo -e "  This traffic may be visible to your network provider."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    echo ""
    # Trim whitespace
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    # Validate token format
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format. Should be like: 123456789:ABCdefGHI...${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo -e ""
    echo -e "  ${YELLOW}Important:${NC} You MUST send ${BOLD}/start${NC} to the bot first!"
    echo -e "  The bot cannot respond to you until you do this."
    echo -e ""
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start to your bot... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; return; }

    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        if telegram_get_chat_id; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done

    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot and try again."
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi
    echo -e "${GREEN}✓ Chat ID: ${TELEGRAM_CHAT_ID}${NC}"

    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi

    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send. Check your token.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    TELEGRAM_ENABLED=true
    TELEGRAM_ALERTS_ENABLED=true
    TELEGRAM_DAILY_SUMMARY=true
    TELEGRAM_WEEKLY_SUMMARY=true
    save_settings
    telegram_start_notify

    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

telegram_generate_notify_script() {
    cat > "$INSTALL_DIR/torware-telegram.sh" << 'TGEOF'
#!/bin/bash
# Torware Telegram Notification Service
# Runs as a systemd service, sends periodic status reports
INSTALL_DIR="REPLACE_INSTALL_DIR"

[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

# Exit if not configured
[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0
[ -z "$TELEGRAM_CHAT_ID" ] && exit 0

# Cache server IP once at startup
_server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "")

escape_md() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

telegram_send() {
    local message="$1"
    local token="${TELEGRAM_BOT_TOKEN}"
    local chat_id="${TELEGRAM_CHAT_ID}"
    { [ -z "$token" ] || [ -z "$chat_id" ]; } && return 1
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_md "$label")
    if [ -n "$_server_ip" ]; then
        message="[${label} | ${_server_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    local _cfg
    _cfg=$(mktemp "${TMPDIR:-/tmp}/.tg_curl.XXXXXX") || return 1
    chmod 600 "$_cfg"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" > "$_cfg"
    curl -s --max-time 10 --max-filesize 1048576 -X POST \
        -K "$_cfg" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "parse_mode=Markdown" \
        >/dev/null 2>&1
    rm -f "$_cfg"
}

get_container_name() {
    local i=$1
    if [ "$i" -le 1 ]; then
        echo "torware"
    else
        echo "torware-${i}"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    [ "$cores" -lt 1 ] 2>/dev/null && cores=1
    echo "$cores"
}

track_uptime() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^torware" 2>/dev/null || true)
    running=${running:-0}
    echo "$(date +%s)|${running}" >> "$INSTALL_DIR/relay_stats/uptime_log"
    # Trim to 10080 lines (7 days of per-minute entries)
    local log_file="$INSTALL_DIR/relay_stats/uptime_log"
    local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 10080 ] 2>/dev/null; then
        tail -10080 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

calc_uptime_pct() {
    local period_secs=${1:-86400}
    local log_file="$INSTALL_DIR/relay_stats/uptime_log"
    [ ! -s "$log_file" ] && echo "0" && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local total=0
    local up=0
    while IFS='|' read -r ts count; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        total=$((total + 1))
        [ "$count" -gt 0 ] 2>/dev/null && up=$((up + 1))
    done < "$log_file"
    [ "$total" -eq 0 ] && echo "0" && return
    awk "BEGIN {printf \"%.1f\", ($up/$total)*100}" 2>/dev/null || echo "0"
}

rotate_cumulative_data() {
    local data_file="$INSTALL_DIR/relay_stats/cumulative_data"
    local marker="$INSTALL_DIR/relay_stats/.last_rotation_month"
    local current_month=$(date '+%Y-%m')
    local last_month=""
    [ -f "$marker" ] && last_month=$(cat "$marker" 2>/dev/null)
    if [ -z "$last_month" ]; then
        echo "$current_month" > "$marker"
        return
    fi
    if [ "$current_month" != "$last_month" ] && [ -s "$data_file" ]; then
        cp "$data_file" "${data_file}.${last_month}"
        echo "$current_month" > "$marker"
        local cutoff_ts=$(( $(date +%s) - 7776000 ))
        for archive in "$INSTALL_DIR/relay_stats/cumulative_data."[0-9][0-9][0-9][0-9]-[0-9][0-9]; do
            [ ! -f "$archive" ] && continue
            local archive_mtime=$(stat -c %Y "$archive" 2>/dev/null || stat -f %m "$archive" 2>/dev/null || echo 0)
            if [ "$archive_mtime" -gt 0 ] && [ "$archive_mtime" -lt "$cutoff_ts" ] 2>/dev/null; then
                rm -f "$archive"
            fi
        done
    fi
}

check_alerts() {
    [ "$TELEGRAM_ALERTS_ENABLED" != "true" ] && return
    local now=$(date +%s)
    local cooldown=3600

    # CPU + RAM check
    local torware_containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^torware" 2>/dev/null || true)
    local stats_line=""
    if [ -n "$torware_containers" ]; then
        stats_line=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" $torware_containers 2>/dev/null | head -1)
    fi
    local raw_cpu=$(echo "$stats_line" | awk '{print $1}')
    local ram_pct=$(echo "$stats_line" | awk '{print $2}')

    local cores=$(get_cpu_cores)
    local cpu_val=$(awk "BEGIN {printf \"%.0f\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo 0)
    if [ "${cpu_val:-0}" -gt 90 ] 2>/dev/null; then
        cpu_breach=$((cpu_breach + 1))
    else
        cpu_breach=0
    fi
    if [ "$cpu_breach" -ge 3 ] && [ $((now - last_alert_cpu)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High CPU*
CPU usage at ${cpu_val}% for 3+ minutes"
        last_alert_cpu=$now
        cpu_breach=0
    fi

    local ram_val=${ram_pct%\%}
    ram_val=${ram_val%%.*}
    if [ "${ram_val:-0}" -gt 90 ] 2>/dev/null; then
        ram_breach=$((ram_breach + 1))
    else
        ram_breach=0
    fi
    if [ "$ram_breach" -ge 3 ] && [ $((now - last_alert_ram)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High RAM*
Memory usage at ${ram_pct} for 3+ minutes"
        last_alert_ram=$now
        ram_breach=0
    fi

    # All containers down
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^torware" 2>/dev/null || true)
    running=${running:-0}
    if [ "$running" -eq 0 ] 2>/dev/null && [ $((now - last_alert_down)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "🔴 *Alert: All containers down*
No Torware containers are running!"
        last_alert_down=$now
    fi

    # Zero connections for 2+ hours
    local total_circuits=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local circ=$(timeout 5 docker exec "$cname" sh -c 'echo "GETINFO circuit-status" | nc 127.0.0.1 9051 2>/dev/null | grep -c BUILT' 2>/dev/null || echo 0)
        total_circuits=$((total_circuits + ${circ:-0}))
    done
    if [ "$total_circuits" -eq 0 ] 2>/dev/null; then
        if [ "$zero_peers_since" -eq 0 ] 2>/dev/null; then
            zero_peers_since=$now
        elif [ $((now - zero_peers_since)) -ge 7200 ] && [ $((now - last_alert_peers)) -ge $cooldown ] 2>/dev/null; then
            telegram_send "⚠️ *Alert: Zero connections*
No active circuits for 2+ hours"
            last_alert_peers=$now
            zero_peers_since=$now
        fi
    else
        zero_peers_since=0
    fi
}

record_snapshot() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^torware" 2>/dev/null || true)
    running=${running:-0}
    local total_circuits=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local circ=$(timeout 5 docker exec "$cname" sh -c 'echo "GETINFO circuit-status" | nc 127.0.0.1 9051 2>/dev/null | grep -c BUILT' 2>/dev/null || echo 0)
        total_circuits=$((total_circuits + ${circ:-0}))
    done
    local data_file="$INSTALL_DIR/relay_stats/cumulative_data"
    local total_bw=0
    [ -s "$data_file" ] && total_bw=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file" 2>/dev/null)
    echo "$(date +%s)|${total_circuits}|${total_bw:-0}|${running}" >> "$INSTALL_DIR/relay_stats/report_snapshots"
    local snap_file="$INSTALL_DIR/relay_stats/report_snapshots"
    local lines=$(wc -l < "$snap_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 720 ] 2>/dev/null; then
        tail -720 "$snap_file" > "${snap_file}.tmp" && mv "${snap_file}.tmp" "$snap_file"
    fi
}

build_summary() {
    local period_label="$1"
    local period_secs="$2"
    local snap_file="$INSTALL_DIR/relay_stats/report_snapshots"
    [ ! -s "$snap_file" ] && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local peak_circuits=0
    local sum_circuits=0
    local count=0
    local first_bw=0
    local last_bw=0
    local got_first=false
    while IFS='|' read -r ts circuits bw running; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        count=$((count + 1))
        sum_circuits=$((sum_circuits + ${circuits:-0}))
        [ "${circuits:-0}" -gt "$peak_circuits" ] 2>/dev/null && peak_circuits=${circuits:-0}
        if [ "$got_first" = false ]; then
            first_bw=${bw:-0}
            got_first=true
        fi
        last_bw=${bw:-0}
    done < "$snap_file"
    [ "$count" -eq 0 ] && return

    local avg_circuits=$((sum_circuits / count))
    local period_bw=$((${last_bw:-0} - ${first_bw:-0}))
    [ "$period_bw" -lt 0 ] 2>/dev/null && period_bw=0
    local bw_fmt=$(awk "BEGIN {b=$period_bw; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
    local uptime_pct=$(calc_uptime_pct "$period_secs")

    local msg="📋 *${period_label} Summary*"
    msg+=$'\n'"🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    msg+=$'\n'$'\n'"📊 Bandwidth served: ${bw_fmt}"
    msg+=$'\n'"🔗 Peak circuits: ${peak_circuits} | Avg: ${avg_circuits}"
    msg+=$'\n'"⏱ Uptime: ${uptime_pct}%"
    msg+=$'\n'"📈 Data points: ${count}"

    # New countries detection
    local countries_file="$INSTALL_DIR/relay_stats/known_countries"
    local data_file="$INSTALL_DIR/relay_stats/cumulative_data"
    local new_countries=""
    if [ -s "$data_file" ]; then
        local current_countries=$(awk -F'|' '{if($1!="") print $1}' "$data_file" 2>/dev/null | sort -u)
        if [ -f "$countries_file" ]; then
            new_countries=$(comm -23 <(echo "$current_countries") <(sort "$countries_file") 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        fi
        echo "$current_countries" > "$countries_file"
    fi
    if [ -n "$new_countries" ]; then
        local safe_new=$(escape_md "$new_countries")
        msg+=$'\n'"🆕 New countries: ${safe_new}"
    fi

    telegram_send "$msg"
}

format_bytes() {
    local bytes=$1
    [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null && echo "0 B" && return
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

build_report() {
    local count=${CONTAINER_COUNT:-1}
    local report="📊 *Torware Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'

    local running=0 total_read=0 total_written=0 total_circuits=0 total_conns=0
    local earliest_start=""

    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            running=$((running + 1))
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -n "$started" ]; then
                local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
                    earliest_start=$se
                fi
            fi
            # Traffic via ControlPort
            local cport=$((9051 + i - 1))
            local cp_out=$(timeout 5 docker exec "$cname" sh -c "printf 'AUTHENTICATE\r\nGETINFO traffic/read\r\nGETINFO traffic/written\r\nQUIT\r\n' | nc 127.0.0.1 9051" 2>/dev/null)
            local rb=$(echo "$cp_out" | sed -n 's/.*traffic\/read=\([0-9]*\).*/\1/p' | head -1); rb=${rb:-0}
            local wb=$(echo "$cp_out" | sed -n 's/.*traffic\/written=\([0-9]*\).*/\1/p' | head -1); wb=${wb:-0}
            total_read=$((total_read + rb))
            total_written=$((total_written + wb))
            # Circuits
            local circ_out=$(timeout 5 docker exec "$cname" sh -c "printf 'AUTHENTICATE\r\nGETINFO circuit-status\r\nQUIT\r\n' | nc 127.0.0.1 9051" 2>/dev/null)
            local circ=$(echo "$circ_out" | grep -cE '^[0-9]+ (BUILT|EXTENDED|LAUNCHED)' 2>/dev/null || echo 0)
            circ=${circ//[^0-9]/}; circ=${circ:-0}
            total_circuits=$((total_circuits + circ))
            # Connections
            local conn_out=$(timeout 5 docker exec "$cname" sh -c "printf 'AUTHENTICATE\r\nGETINFO orconn-status\r\nQUIT\r\n' | nc 127.0.0.1 9051" 2>/dev/null)
            local conn=$(echo "$conn_out" | grep -c '\$' 2>/dev/null || echo 0)
            conn=${conn//[^0-9]/}; conn=${conn:-0}
            total_conns=$((total_conns + conn))
        fi
    done

    # Include snowflake
    local total_containers=$count
    local total_running=$running
    local sf_conns=0 sf_in=0 sf_out=0
    if [ "${SNOWFLAKE_ENABLED:-false}" = "true" ]; then
        total_containers=$((total_containers + 1))
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^snowflake-proxy$"; then
            total_running=$((total_running + 1))
            local sf_metrics=$(curl -s --max-time 3 "http://127.0.0.1:${SNOWFLAKE_METRICS_PORT:-9999}/internal/metrics" 2>/dev/null)
            [ -n "$sf_metrics" ] && sf_conns=$(echo "$sf_metrics" | awk '/^tor_snowflake_proxy_connections_total[{ ]/ { sum += $NF } END { printf "%.0f", sum }' 2>/dev/null)
            sf_conns=${sf_conns:-0}
            local sf_log=$(docker logs snowflake-proxy 2>&1 | grep "Traffic Relayed" 2>/dev/null)
            if [ -n "$sf_log" ]; then
                sf_in=$(echo "$sf_log" | awk -F'[↓↑]' '{ split($2, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1] } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
                sf_out=$(echo "$sf_log" | awk -F'[↓↑]' '{ split($3, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1] } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
            fi
            sf_in=${sf_in:-0}; sf_out=${sf_out:-0}
            total_read=$((total_read + sf_in))
            total_written=$((total_written + sf_out))
        fi
    fi

    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        local now=$(date +%s) up=$(($(date +%s) - earliest_start))
        local days=$((up / 86400)) hours=$(( (up % 86400) / 3600 )) mins=$(( (up % 3600) / 60 ))
        if [ "$days" -gt 0 ]; then
            report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
        else
            report+="⏱ Uptime: ${hours}h ${mins}m"
        fi
        report+=$'\n'
    fi

    report+="📦 Containers: ${total_running}/${total_containers} running"
    report+=$'\n'
    report+="🔗 Circuits: ${total_circuits} | Connections: ${total_conns}"
    report+=$'\n'
    report+="📊 Traffic: ↓ $(format_bytes $total_read) ↑ $(format_bytes $total_written)"
    report+=$'\n'

    # Snowflake detail line
    if [ "${SNOWFLAKE_ENABLED:-false}" = "true" ] && [ "$sf_conns" -gt 0 ] 2>/dev/null; then
        local sf_total=$((sf_in + sf_out))
        report+="❄ Snowflake: ${sf_conns} conns | $(format_bytes $sf_total) transferred"
        report+=$'\n'
    fi

    # Uptime %
    local uptime_pct=$(calc_uptime_pct 86400)
    [ "${uptime_pct}" != "0" ] && report+="📈 Availability: ${uptime_pct}% (24h)"$'\n'

    # CPU / RAM
    local names=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        names+=" $(get_container_name $i)"
    done
    [ "${SNOWFLAKE_ENABLED:-false}" = "true" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^snowflake-proxy$" && names+=" snowflake-proxy"
    local stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $names 2>/dev/null | head -1)
    if [ -n "$stats" ]; then
        local raw_cpu=$(echo "$stats" | awk '{print $1}')
        local cores=$(get_cpu_cores)
        local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
        local sys_ram=""
        if command -v free &>/dev/null; then
            local free_out=$(free -m 2>/dev/null)
            local ram_used=$(echo "$free_out" | awk '/^Mem:/{if ($3>=1024) printf "%.1fGiB",$3/1024; else printf "%dMiB",$3}')
            local ram_total=$(echo "$free_out" | awk '/^Mem:/{if ($2>=1024) printf "%.1fGiB",$2/1024; else printf "%dMiB",$2}')
            sys_ram="${ram_used} / ${ram_total}"
        fi
        if [ -n "$sys_ram" ]; then
            report+="🖥 CPU: ${cpu} | RAM: ${sys_ram}"
        else
            local ram=$(echo "$stats" | awk '{print $2, $3, $4}')
            report+="🖥 CPU: ${cpu} | RAM: ${ram}"
        fi
        report+=$'\n'
    fi

    printf '%s' "$report"
}

process_commands() {
    local offset_file="$INSTALL_DIR/relay_stats/tg_offset"
    local offset=0
    [ -f "$offset_file" ] && offset=$(cat "$offset_file" 2>/dev/null)
    offset=${offset:-0}
    [ "$offset" -eq "$offset" ] 2>/dev/null || offset=0

    local _cfg
    _cfg=$(mktemp "${TMPDIR:-/tmp}/.tg_curl.XXXXXX") || return
    chmod 600 "$_cfg"
    printf 'url = "https://api.telegram.org/bot%s/getUpdates?offset=%s&timeout=0"\n' "$TELEGRAM_BOT_TOKEN" "$((offset + 1))" > "$_cfg"
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -K "$_cfg" 2>/dev/null)
    rm -f "$_cfg"
    [ -z "$response" ] && return

    if ! command -v python3 &>/dev/null; then
        return
    fi

    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('ok'): sys.exit(0)
    results = data.get('result', [])
    if not results: sys.exit(0)
    for r in results:
        uid = r.get('update_id', 0)
        msg = r.get('message', {})
        chat_id = msg.get('chat', {}).get('id', 0)
        text = msg.get('text', '')
        if str(chat_id) == '$TELEGRAM_CHAT_ID' and text.startswith('/tor_'):
            print(f'{uid}|{text}')
        else:
            print(f'{uid}|')
except Exception:
    try:
        data = json.loads(sys.argv[1])
        results = data.get('result', [])
        if results:
            max_uid = max(r.get('update_id', 0) for r in results)
            if max_uid > 0:
                print(f'{max_uid}|')
    except Exception:
        pass
" "$response" 2>/dev/null)

    [ -z "$parsed" ] && return

    local max_id=$offset
    while IFS='|' read -r uid cmd; do
        [ -z "$uid" ] && continue
        [ "$uid" -gt "$max_id" ] 2>/dev/null && max_id=$uid
        case "$cmd" in
            /tor_status|/tor_status@*)
                local report=$(build_report)
                telegram_send "$report"
                ;;
            /tor_peers|/tor_peers@*)
                local total_circuits=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local circ=$(timeout 5 docker exec "$cname" sh -c 'echo "GETINFO circuit-status" | nc 127.0.0.1 9051 2>/dev/null | grep -c BUILT' 2>/dev/null || echo 0)
                    total_circuits=$((total_circuits + ${circ:-0}))
                done
                telegram_send "🔗 Active circuits: ${total_circuits}"
                ;;
            /tor_uptime|/tor_uptime@*)
                local ut_msg="⏱ *Uptime Report*"
                ut_msg+="\n"
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local is_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^${cname}$" || true)
                    if [ "${is_running:-0}" -gt 0 ]; then
                        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
                        if [ -n "$started" ]; then
                            local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                            local diff=$(( $(date +%s) - se ))
                            local d=$((diff / 86400)) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
                            ut_msg+="\n📦 Container ${i}: ${d}d ${h}h ${m}m"
                        else
                            ut_msg+="\n📦 Container ${i}: ⚠ unknown"
                        fi
                    else
                        ut_msg+="\n📦 Container ${i}: 🔴 stopped"
                    fi
                done
                local avail=$(calc_uptime_pct 86400)
                ut_msg+="\n\n📈 Availability: ${avail}% (24h)"
                telegram_send "$ut_msg"
                ;;
            /tor_containers|/tor_containers@*)
                local ct_msg="📦 *Container Status*"
                ct_msg+="\n"
                local docker_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    ct_msg+="\n"
                    if echo "$docker_names" | grep -q "^${cname}$"; then
                        local safe_cname=$(escape_md "$cname")
                        ct_msg+="C${i} (${safe_cname}): 🟢 Running"
                        local circ=$(timeout 5 docker exec "$cname" sh -c 'echo "GETINFO circuit-status" | nc 127.0.0.1 9051 2>/dev/null | grep -c BUILT' 2>/dev/null || echo 0)
                        ct_msg+="\n  🔗 Circuits: ${circ:-0}"
                    else
                        local safe_cname=$(escape_md "$cname")
                        ct_msg+="C${i} (${safe_cname}): 🔴 Stopped"
                    fi
                    ct_msg+="\n"
                done
                ct_msg+="\n/tor\_restart\_N  /tor\_stop\_N  /tor\_start\_N — manage containers"
                telegram_send "$ct_msg"
                ;;
            /tor_restart_*|/tor_stop_*|/tor_start_*)
                local action="${cmd%%_*}"     # /tor_restart, /tor_stop, or /tor_start
                # Remove the /tor_ prefix to get restart, stop, start
                action="${action#/tor_}"
                local num="${cmd##*_}"
                num="${num%%@*}"              # strip @botname suffix
                if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${CONTAINER_COUNT:-1}" ]; then
                    telegram_send "❌ Invalid container number: ${num}. Use 1-${CONTAINER_COUNT:-1}."
                else
                    local cname=$(get_container_name "$num")
                    if docker "$action" "$cname" >/dev/null 2>&1; then
                        local emoji="✅"
                        [ "$action" = "stop" ] && emoji="🛑"
                        [ "$action" = "start" ] && emoji="🟢"
                        local safe_cname=$(escape_md "$cname")
                        telegram_send "${emoji} Container ${num} (${safe_cname}): ${action} successful"
                    else
                        local safe_cname=$(escape_md "$cname")
                        telegram_send "❌ Failed to ${action} container ${num} (${safe_cname})"
                    fi
                fi
                ;;
            /tor_snowflake|/tor_snowflake@*)
                if [ "${SNOWFLAKE_ENABLED:-false}" != "true" ]; then
                    telegram_send "❄ Snowflake proxy is not enabled."
                elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^snowflake-proxy$"; then
                    telegram_send "❄ *Snowflake Proxy*
🔴 Status: Stopped"
                else
                    local sf_metrics=$(curl -s --max-time 3 "http://127.0.0.1:${SNOWFLAKE_METRICS_PORT:-9999}/internal/metrics" 2>/dev/null)
                    local sf_total_conns=0
                    [ -n "$sf_metrics" ] && sf_total_conns=$(echo "$sf_metrics" | awk '/^tor_snowflake_proxy_connections_total[{ ]/ { sum += $NF } END { printf "%.0f", sum }' 2>/dev/null)
                    sf_total_conns=${sf_total_conns:-0}
                    local sf_log=$(docker logs snowflake-proxy 2>&1 | grep "Traffic Relayed" 2>/dev/null)
                    local sf_in=0 sf_out=0
                    if [ -n "$sf_log" ]; then
                        sf_in=$(echo "$sf_log" | awk -F'[↓↑]' '{ split($2, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1] } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
                        sf_out=$(echo "$sf_log" | awk -F'[↓↑]' '{ split($3, a, " "); gsub(/[^0-9.]/, "", a[1]); sum += a[1] } END { printf "%.0f", sum * 1024 }' 2>/dev/null)
                    fi
                    sf_in=${sf_in:-0}; sf_out=${sf_out:-0}
                    local sf_total=$((sf_in + sf_out))
                    local sf_started=$(docker inspect --format='{{.State.StartedAt}}' snowflake-proxy 2>/dev/null | cut -d'.' -f1)
                    local sf_uptime="unknown"
                    if [ -n "$sf_started" ]; then
                        local sf_se=$(date -d "$sf_started" +%s 2>/dev/null || echo 0)
                        if [ "$sf_se" -gt 0 ] 2>/dev/null; then
                            local sf_diff=$(( $(date +%s) - sf_se ))
                            local sf_d=$((sf_diff / 86400)) sf_h=$(( (sf_diff % 86400) / 3600 )) sf_m=$(( (sf_diff % 3600) / 60 ))
                            [ "$sf_d" -gt 0 ] && sf_uptime="${sf_d}d ${sf_h}h ${sf_m}m" || sf_uptime="${sf_h}h ${sf_m}m"
                        fi
                    fi
                    # Top countries
                    local sf_countries=""
                    if [ -n "$sf_metrics" ]; then
                        sf_countries=$(echo "$sf_metrics" | awk '
                            /^tor_snowflake_proxy_connections_total\{/ {
                                val = $NF + 0; country = ""
                                s = $0; idx = index(s, "country=\"")
                                if (idx > 0) { s = substr(s, idx + 9); end = index(s, "\""); if (end > 0) country = substr(s, 1, end - 1) }
                                if (country != "" && val > 0) counts[country] += val
                            }
                            END { for (c in counts) print counts[c] "|" c }
                        ' 2>/dev/null | sort -t'|' -k1 -nr | head -5)
                    fi
                    local sf_msg="❄ *Snowflake Proxy*
🟢 Status: Running
⏱ Uptime: ${sf_uptime}
👥 Total connections: ${sf_total_conns}
📊 Traffic: ↓ $(format_bytes $sf_in) ↑ $(format_bytes $sf_out)
💾 Total transferred: $(format_bytes $sf_total)"
                    if [ -n "$sf_countries" ]; then
                        sf_msg+=$'\n'"🗺 Top countries:"
                        while IFS='|' read -r cnt cc; do
                            [ -z "$cc" ] && continue
                            sf_msg+=$'\n'"  ${cc}: ${cnt}"
                        done <<< "$sf_countries"
                    fi
                    telegram_send "$sf_msg"
                fi
                ;;
            /tor_help|/tor_help@*)
                telegram_send "📖 *Available Commands*
/tor\_status — Full status report
/tor\_peers — Current circuit count
/tor\_uptime — Per-container uptime + 24h availability
/tor\_containers — Per-container status
/tor\_snowflake — Snowflake proxy details
/tor\_restart\_N — Restart container N
/tor\_stop\_N — Stop container N
/tor\_start\_N — Start container N
/tor\_help — Show this help"
                ;;
        esac
    done <<< "$parsed"

    [ "$max_id" -gt "$offset" ] 2>/dev/null && echo "$max_id" > "$offset_file"
}

# State variables
cpu_breach=0
ram_breach=0
zero_peers_since=0
last_alert_cpu=0
last_alert_ram=0
last_alert_down=0
last_alert_peers=0
last_rotation_ts=0

# Ensure data directory exists
mkdir -p "$INSTALL_DIR/relay_stats"

# Persist daily/weekly timestamps across restarts
_ts_dir="$INSTALL_DIR/relay_stats"
last_daily_ts=$(cat "$_ts_dir/.last_daily_ts" 2>/dev/null || echo 0)
[ "$last_daily_ts" -eq "$last_daily_ts" ] 2>/dev/null || last_daily_ts=0
last_weekly_ts=$(cat "$_ts_dir/.last_weekly_ts" 2>/dev/null || echo 0)
[ "$last_weekly_ts" -eq "$last_weekly_ts" ] 2>/dev/null || last_weekly_ts=0
last_report_ts=$(cat "$_ts_dir/.last_report_ts" 2>/dev/null || echo 0)
[ "$last_report_ts" -eq "$last_report_ts" ] 2>/dev/null || last_report_ts=0

while true; do
    sleep 60

    # Re-read settings
    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    # Exit if disabled
    [ "$TELEGRAM_ENABLED" != "true" ] && exit 0
    [ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0

    # Core per-minute tasks
    process_commands
    track_uptime
    check_alerts

    # Daily rotation check
    now_ts=$(date +%s)
    if [ $((now_ts - last_rotation_ts)) -ge 86400 ] 2>/dev/null; then
        rotate_cumulative_data
        last_rotation_ts=$now_ts
    fi

    # Daily summary
    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_daily_ts)) -ge 86400 ] 2>/dev/null; then
        build_summary "Daily" 86400
        last_daily_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_daily_ts"
    fi

    # Weekly summary
    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_weekly_ts)) -ge 604800 ] 2>/dev/null; then
        build_summary "Weekly" 604800
        last_weekly_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_weekly_ts"
    fi

    # Regular periodic report (wall-clock aligned to start hour)
    interval_hours=${TELEGRAM_INTERVAL:-6}
    start_hour=${TELEGRAM_START_HOUR:-0}
    interval_secs=$((interval_hours * 3600))
    current_hour=$(date +%-H)
    hour_diff=$(( (current_hour - start_hour + 24) % 24 ))
    if [ "$interval_hours" -gt 0 ] && [ $((hour_diff % interval_hours)) -eq 0 ] 2>/dev/null; then
        if [ $((now_ts - last_report_ts)) -ge $((interval_secs - 120)) ] 2>/dev/null; then
            report=$(build_report)
            telegram_send "$report"
            record_snapshot
            last_report_ts=$now_ts
            echo "$now_ts" > "$_ts_dir/.last_report_ts"
        fi
    fi
done
TGEOF

    local escaped_dir=$(printf '%s\n' "$INSTALL_DIR" | sed 's/[&\\]/\\&/g')
    sed "s#REPLACE_INSTALL_DIR#${escaped_dir}#g" "$INSTALL_DIR/torware-telegram.sh" > "$INSTALL_DIR/torware-telegram.sh.tmp" && mv "$INSTALL_DIR/torware-telegram.sh.tmp" "$INSTALL_DIR/torware-telegram.sh"
    chmod 700 "$INSTALL_DIR/torware-telegram.sh"
}

setup_telegram_service() {
    telegram_generate_notify_script
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/torware-telegram.service << EOF
[Unit]
Description=Torware Telegram Notifications
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/torware-telegram.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable torware-telegram.service 2>/dev/null || true
        systemctl restart torware-telegram.service 2>/dev/null || true
    fi
}

telegram_stop_notify() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/torware-telegram.service ]; then
        systemctl stop torware-telegram.service 2>/dev/null || true
    fi
    # Clean up legacy PID-based loop if present
    if [ -f "$INSTALL_DIR/telegram_notify.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/telegram_notify.pid" 2>/dev/null)
        if echo "$pid" | grep -qE '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$INSTALL_DIR/telegram_notify.pid"
    fi
    pkill -f "torware-telegram.sh" 2>/dev/null || true
}

telegram_start_notify() {
    telegram_stop_notify
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        setup_telegram_service
    fi
}

telegram_disable_service() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/torware-telegram.service ]; then
        systemctl stop torware-telegram.service 2>/dev/null || true
        systemctl disable torware-telegram.service 2>/dev/null || true
    fi
    pkill -f "torware-telegram.sh" 2>/dev/null || true
}

show_telegram_menu() {
    while true; do
        # Reload settings from disk to reflect any changes
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        clear
        print_header
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Already configured — show management menu
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            local _sh="${TELEGRAM_START_HOUR:-0}"
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${_sh}:00)"
            echo ""
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed. Check your token/chat ID.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    echo ""
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || true
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) echo -e "  ${RED}Invalid choice${NC}"; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; continue ;;
                    esac
                    echo ""
                    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
                    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
                    read -p "  Start hour [0-23] (default ${TELEGRAM_START_HOUR:-0}): " shchoice < /dev/tty || true
                    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
                        TELEGRAM_START_HOUR=$shchoice
                    fi
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR:-0}:00${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Telegram notifications disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                        echo -e "  ${RED}✗ Alerts disabled${NC}"
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                        echo -e "  ${GREEN}✓ Alerts enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                        echo -e "  ${RED}✗ Daily summary disabled${NC}"
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Daily summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                        echo -e "  ${RED}✗ Weekly summary disabled${NC}"
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Weekly summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  Current label: ${CYAN}${cur_label}${NC}"
                    echo -e "  This label appears in all Telegram messages to identify the server."
                    echo -e "  Leave blank to use hostname ($(hostname 2>/dev/null || echo 'unknown'))"
                    echo ""
                    read -p "  New label: " new_label < /dev/tty || true
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    local display_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  ${GREEN}✓ Server label set to: ${display_label}${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Disabled but credentials exist — offer re-enable
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${RED}✗ Disabled${NC} (credentials saved)"
            echo ""
            echo -e "  1. ✅ Re-enable notifications (every ${TELEGRAM_INTERVAL:-6}h)"
            echo -e "  2. 🔄 Reconfigure (new bot/chat)"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    TELEGRAM_ENABLED=true
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Telegram notifications re-enabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    telegram_setup_wizard
                    ;;
                0) return ;;
            esac
        else
            # Not configured — run wizard
            telegram_setup_wizard
            return
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════
# Fingerprint & Bridge Line Display
#═══════════════════════════════════════════════════════════════════════

show_fingerprint() {
    load_settings
    local count=${CONTAINER_COUNT:-1}

    echo ""
    echo -e "${CYAN}  Relay Fingerprints:${NC}"
    echo ""
    for i in $(seq 1 $count); do
        local fp=$(get_tor_fingerprint $i)
        local cname=$(get_container_name $i)
        local c_rtype=$(get_container_relay_type $i)
        if [ -n "$fp" ]; then
            echo -e "    ${BOLD}$cname${NC} [${c_rtype}]: $fp"
        else
            echo -e "    ${BOLD}$cname${NC} [${c_rtype}]: ${DIM}(not yet generated)${NC}"
        fi
    done
    echo ""
}

show_bridge_line() {
    load_settings

    # Check if any container is a bridge
    local count=${CONTAINER_COUNT:-1}
    local any_bridge=false
    for i in $(seq 1 $count); do
        [ "$(get_container_relay_type $i)" = "bridge" ] && any_bridge=true
    done
    if [ "$any_bridge" = "false" ]; then
        log_warn "Bridge lines are only available for bridge relays. No bridge containers configured."
        return 1
    fi

    echo ""
    echo -e "${CYAN}  Bridge Lines (share these with users who need to bypass censorship):${NC}"
    echo ""
    for i in $(seq 1 $count); do
        # Skip non-bridge containers
        [ "$(get_container_relay_type $i)" != "bridge" ] && continue
        local bl=$(get_bridge_line $i)
        local cname=$(get_container_name $i)
        if [ -n "$bl" ]; then
            echo -e "    ${BOLD}$cname:${NC}"
            echo -e "    ${GREEN}$bl${NC}"
            echo ""
            # QR code if available
            if command -v qrencode &>/dev/null; then
                echo -e "    ${DIM}QR Code:${NC}"
                echo "$bl" | qrencode -t ANSIUTF8 2>/dev/null | sed 's/^/      /'
                echo ""
            fi
        else
            echo -e "    ${BOLD}$cname:${NC} ${DIM}(not yet available - relay may still be bootstrapping)${NC}"
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    UNINSTALL TORWARE                    ║${NC}"
    echo -e "${RED}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                   ║${NC}"
    echo -e "${RED}║  This will remove:                                                ║${NC}"
    echo -e "${RED}║  • All Tor relay containers (and Snowflake proxy)                  ║${NC}"
    echo -e "${RED}║  • All Docker volumes (relay data & keys)                         ║${NC}"
    echo -e "${RED}║  • Systemd/OpenRC services                                        ║${NC}"
    echo -e "${RED}║  • Configuration files in /opt/torware                           ║${NC}"
    echo -e "${RED}║  • Management CLI (/usr/local/bin/torware)                       ║${NC}"
    echo -e "${RED}║                                                                   ║${NC}"
    echo -e "${RED}║  Docker itself will NOT be removed.                                ║${NC}"
    echo -e "${RED}║                                                                   ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -p "  Type 'yes' to confirm uninstall: " confirm < /dev/tty || true
    if [ "$confirm" != "yes" ]; then
        log_info "Uninstall cancelled."
        return 0
    fi

    # Offer to keep backups
    local keep_backups=false
    if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/tor_keys_*.tar.gz &>/dev/null; then
        echo ""
        read -p "  Keep backup files? [Y/n] " keep_choice < /dev/tty || true
        if [[ ! "$keep_choice" =~ ^[Nn]$ ]]; then
            keep_backups=true
        fi
    fi

    echo ""
    log_info "Uninstalling Torware..."

    # Stop services
    if [ "$HAS_SYSTEMD" = "true" ]; then
        systemctl stop torware 2>/dev/null || true
        systemctl disable torware 2>/dev/null || true
        rm -f /etc/systemd/system/torware.service
        systemctl stop torware-tracker 2>/dev/null || true
        systemctl disable torware-tracker 2>/dev/null || true
        rm -f /etc/systemd/system/torware-tracker.service
        systemctl stop torware-telegram 2>/dev/null || true
        systemctl disable torware-telegram 2>/dev/null || true
        rm -f /etc/systemd/system/torware-telegram.service
        systemctl daemon-reload 2>/dev/null || true
    elif command -v rc-update &>/dev/null; then
        rc-service torware stop 2>/dev/null || true
        rc-update del torware 2>/dev/null || true
        rm -f /etc/init.d/torware
    elif [ -f /etc/init.d/torware ]; then
        service torware stop 2>/dev/null || true
        if command -v update-rc.d &>/dev/null; then
            update-rc.d torware remove 2>/dev/null || true
        fi
        rm -f /etc/init.d/torware
    fi

    # Stop and remove containers (always check 1-5 to catch orphaned containers)
    for i in $(seq 1 5); do
        local cname=$(get_container_name $i)
        docker stop --timeout 30 "$cname" 2>/dev/null || true
        docker rm -f "$cname" 2>/dev/null || true
    done

    # Remove volumes
    for i in $(seq 1 5); do
        local vname=$(get_volume_name $i)
        docker volume rm "$vname" 2>/dev/null || true
    done

    # Stop and remove Snowflake
    docker stop --timeout 10 "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
    docker rm -f "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
    docker volume rm "$SNOWFLAKE_VOLUME" 2>/dev/null || true

    # Remove images
    docker rmi "$BRIDGE_IMAGE" 2>/dev/null || true
    docker rmi "$RELAY_IMAGE" 2>/dev/null || true
    docker rmi "$SNOWFLAKE_IMAGE" 2>/dev/null || true

    # Remove files
    if [ "$keep_backups" = "true" ]; then
        # Remove everything except backups
        find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} + 2>/dev/null || true
        log_info "Backups preserved in $BACKUP_DIR"
    else
        rm -rf "$INSTALL_DIR"
    fi

    rm -f /usr/local/bin/torware

    # Clean up cookie cache and generated scripts
    rm -f /tmp/.tor_cookie_cache_* "${TMPDIR:-/tmp}"/.tor_cookie_cache_* 2>/dev/null || true
    rm -f /usr/local/bin/torware-tracker.sh /usr/local/bin/torware-telegram.sh 2>/dev/null || true

    echo ""
    log_success "Torware has been uninstalled."
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# CLI Logs
#═══════════════════════════════════════════════════════════════════════

show_logs() {
    load_settings
    local count=${CONTAINER_COUNT:-1}

    echo ""
    echo -e "  ${BOLD}View Logs:${NC}"
    echo ""
    local _opt=1
    for i in $(seq 1 $count); do
        local _cn=$(get_container_name $i)
        local _rt=$(get_container_relay_type $i)
        echo -e "    ${GREEN}${_opt}.${NC} ${_cn} (${_rt})"
        _opt=$((_opt + 1))
    done
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo -e "    ${GREEN}${_opt}.${NC} snowflake (WebRTC proxy)"
    fi
    echo -e "    ${GREEN}0.${NC} ← Back"
    echo ""
    read -p "  choice: " choice < /dev/tty || return

    [ "$choice" = "0" ] && return

    local cname=""
    if [ "$SNOWFLAKE_ENABLED" = "true" ] && [ "$choice" = "$_opt" ]; then
        cname="$SNOWFLAKE_CONTAINER"
    elif [[ "$choice" =~ ^[1-9]$ ]] && [ "$choice" -le "$count" ]; then
        cname=$(get_container_name $choice)
    else
        log_warn "Invalid choice"
        return
    fi

    log_info "Streaming logs for $cname (Ctrl+C to return to menu)..."
    # Trap SIGINT so it doesn't propagate to the parent menu
    trap 'true' INT
    docker logs -f --tail 50 "$cname" 2>&1 || true
    trap - INT
    echo ""
    log_info "Log stream ended."
}

#═══════════════════════════════════════════════════════════════════════
# Version & Help
#═══════════════════════════════════════════════════════════════════════

show_version() {
    load_settings
    echo -e "  Torware v${VERSION}"
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local image=$(get_docker_image $i)
        local digest
        digest=$(docker inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "unknown")
        local rtype=$(get_container_relay_type $i)
        echo -e "  Container $i ($rtype): $image"
        echo -e "    Digest: ${digest}"
    done
}

show_help() {
    echo ""
    echo -e "${CYAN}  Torware v${VERSION}${NC}"
    echo ""
    echo -e "  ${BOLD}Usage:${NC} torware <command>"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${GREEN}menu${NC}          Open interactive management menu"
    echo -e "    ${GREEN}status${NC}        Show relay status"
    echo -e "    ${GREEN}dashboard${NC}     Live TUI dashboard (auto-refresh)"
    echo -e "    ${GREEN}stats${NC}         Advanced stats with country charts"
    echo -e "    ${GREEN}peers${NC}         Live circuits by country"
    echo -e "    ${GREEN}start${NC}         Start all relay containers"
    echo -e "    ${GREEN}stop${NC}          Stop all relay containers"
    echo -e "    ${GREEN}restart${NC}       Restart all relay containers"
    echo -e "    ${GREEN}logs${NC}          Stream container logs"
    echo -e "    ${GREEN}health${NC}        Run health diagnostics"
    echo -e "    ${GREEN}fingerprint${NC}   Show relay fingerprint(s)"
    echo -e "    ${GREEN}bridge-line${NC}   Show bridge line(s) for sharing"
    echo -e "    ${GREEN}backup${NC}        Backup relay identity keys"
    echo -e "    ${GREEN}restore${NC}       Restore relay keys from backup"
    echo -e "    ${GREEN}snowflake${NC}     Toggle/manage Snowflake proxy"
    echo -e "    ${GREEN}version${NC}       Show version info"
    echo -e "    ${GREEN}uninstall${NC}     Remove Torware"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Menu
#═══════════════════════════════════════════════════════════════════════

show_about() {
    local _back=false
    while [ "$_back" = "false" ]; do
        clear
        echo -e "${CYAN}"
        echo "═══════════════════════════════════════════════════════════════"
        echo "                    ABOUT & LEARN"
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${NC}"
        echo -e "    ${GREEN}1.${NC} 🧅 What is Tor?"
        echo -e "    ${GREEN}2.${NC} 🌉 Bridge Relays (obfs4)"
        echo -e "    ${GREEN}3.${NC} 🔁 Middle Relays"
        echo -e "    ${GREEN}4.${NC} 🚪 Exit Relays"
        echo -e "    ${GREEN}5.${NC} ❄  Snowflake Proxy"
        echo -e "    ${GREEN}6.${NC} 🔒 How Tor Circuits Work"
        echo -e "    ${GREEN}7.${NC} 📊 Understanding Your Dashboard"
        echo -e "    ${GREEN}8.${NC} ⚖  Legal & Safety Considerations"
        echo -e "    ${GREEN}9.${NC} 📖 About Torware"
        echo -e "    ${GREEN}0.${NC} ← Back"
        echo ""
        read -p "  Choose a topic: " _topic < /dev/tty || { _back=true; continue; }

        echo ""
        case "$_topic" in
            1)
                echo -e "${CYAN}═══ What is Tor? ═══${NC}"
                echo ""
                echo -e "  Tor (The Onion Router) is free, open-source software that enables"
                echo -e "  anonymous communication over the internet. It works by encrypting"
                echo -e "  your traffic in multiple layers (like an onion) and routing it"
                echo -e "  through a series of volunteer-operated servers called relays."
                echo ""
                echo -e "  ${BOLD}How it protects users:${NC}"
                echo -e "  • Each relay only knows the previous and next hop, never the full path"
                echo -e "  • The entry relay knows your IP but not your destination"
                echo -e "  • The exit relay knows the destination but not your IP"
                echo -e "  • No single relay can link you to your activity"
                echo ""
                echo -e "  ${BOLD}Who uses Tor:${NC}"
                echo -e "  • Journalists protecting sources in authoritarian countries"
                echo -e "  • Activists and dissidents communicating safely"
                echo -e "  • Whistleblowers submitting sensitive information"
                echo -e "  • Ordinary people who value their privacy"
                echo -e "  • Researchers studying censorship and surveillance"
                echo ""
                echo -e "  ${BOLD}The Tor network consists of ~7,000 relays run by volunteers"
                echo -e "  worldwide. By running Torware, you are one of them.${NC}"
                ;;
            2)
                echo -e "${CYAN}═══ Bridge Relays (obfs4) ═══${NC}"
                echo ""
                echo -e "  Bridges are special Tor relays that are ${BOLD}not listed${NC} in the"
                echo -e "  public Tor directory. They serve as secret entry points for"
                echo -e "  users in countries that block access to known Tor relays."
                echo ""
                echo -e "  ${BOLD}How bridges work:${NC}"
                echo -e "  • Bridge addresses are distributed privately via BridgeDB"
                echo -e "  • Users request bridges via bridges.torproject.org or email"
                echo -e "  • The obfs4 pluggable transport disguises Tor traffic to look"
                echo -e "    like random data, making it hard to detect and block"
                echo ""
                echo -e "  ${BOLD}What happens when you run a bridge:${NC}"
                echo -e "  • Your IP is NOT published in the public Tor consensus"
                echo -e "  • BridgeDB distributes your bridge line to users who need it"
                echo -e "  • It can take ${YELLOW}hours to days${NC} for clients to find your bridge"
                echo -e "  • You help users in censored regions bypass internet blocks"
                echo ""
                echo -e "  ${BOLD}Bridge is the safest relay type to run.${NC} Your IP stays"
                echo -e "  unlisted and you only serve as an entry point, never an exit."
                echo ""
                echo ""
                echo -e "  ${BOLD}🏠 Running from home? Port forwarding required:${NC}"
                echo -e "  Your router blocks incoming connections by default. You must"
                echo -e "  forward these ports in your router settings:"
                echo ""
                echo -e "    ${GREEN}ORPort (9001 TCP)${NC}  → your server's local IP"
                echo -e "    ${GREEN}obfs4  (9002 TCP)${NC}  → your server's local IP"
                echo ""
                echo -e "  How: Log into your router (usually 192.168.1.1 or 10.0.0.1),"
                echo -e "  find 'Port Forwarding' and add both TCP port forwards."
                echo -e "  Without this, Tor cannot confirm reachability and your bridge"
                echo -e "  will NOT be published or receive clients."
                echo ""
                echo -e "  ${DIM}Snowflake does NOT need port forwarding — WebRTC handles"
                echo -e "  NAT traversal automatically.${NC}"
                echo ""
                echo -e "  ${BOLD}🕐 Bridge line availability:${NC}"
                echo -e "  After starting, your bridge line (option 'b' in the menu) will"
                echo -e "  show 'not yet available' until Tor completes these steps:"
                echo -e "  1. Bootstrap to 100% and self-test ORPort reachability"
                echo -e "  2. Publish descriptor to bridge authority"
                echo -e "  3. Get included in BridgeDB for distribution"
                echo -e "  This process takes ${YELLOW}a few hours to 1-2 days${NC}. You can verify"
                echo -e "  progress with Health Check (option 8) — look for a valid"
                echo -e "  fingerprint and 'ORPort reachable' in your Tor logs."
                echo -e "  Once the bridge line appears, share it with users who need"
                echo -e "  to bypass censorship — or let BridgeDB distribute it."
                echo ""
                echo -e "  ${DIM}Docker image: thetorproject/obfs4-bridge${NC}"
                ;;
            3)
                echo -e "${CYAN}═══ Middle Relays ═══${NC}"
                echo ""
                echo -e "  Middle relays are the backbone of the Tor network. They sit"
                echo -e "  between the entry (guard) and exit relays in a Tor circuit."
                echo ""
                echo -e "  ${BOLD}What middle relays do:${NC}"
                echo -e "  • Receive encrypted traffic from one relay and pass it to the next"
                echo -e "  • Cannot see the original source or final destination"
                echo -e "  • Cannot decrypt the traffic content"
                echo -e "  • Add hops to increase anonymity for users"
                echo ""
                echo -e "  ${BOLD}Running a middle relay:${NC}"
                echo -e "  • Your IP IS listed in the public Tor consensus"
                echo -e "  • This is generally safe — you only relay encrypted traffic"
                echo -e "  • No abuse complaints since you're not an exit"
                echo -e "  • The ExitPolicy is set to 'reject *:*' (no exit traffic)"
                echo ""
                echo -e "  ${BOLD}Guard status:${NC} After running reliably for ~2 months, your"
                echo -e "  relay may earn the 'Guard' flag, meaning Tor clients trust it"
                echo -e "  enough to use as their entry relay. This is a sign of good"
                echo -e "  reputation in the network."
                ;;
            4)
                echo -e "${CYAN}═══ Exit Relays ═══${NC}"
                echo ""
                echo -e "  Exit relays are the ${BOLD}final hop${NC} in a Tor circuit. They"
                echo -e "  decrypt the outermost layer of encryption and forward the"
                echo -e "  traffic to its final destination on the regular internet."
                echo ""
                echo -e "  ${BOLD}What exit relays do:${NC}"
                echo -e "  • Connect to the destination website/service on behalf of the user"
                echo -e "  • Can see the destination (but NOT who is connecting)"
                echo -e "  • Handle the 'last mile' of the anonymized connection"
                echo ""
                echo -e "  ${RED}${BOLD}⚠ Important considerations:${NC}"
                echo -e "  ${RED}• Your IP appears as the source of all traffic exiting through you${NC}"
                echo -e "  ${RED}• You may receive abuse complaints (DMCA, hacking reports, etc.)${NC}"
                echo -e "  ${RED}• Some ISPs and hosting providers prohibit exit relays${NC}"
                echo -e "  ${RED}• Legal implications vary by jurisdiction${NC}"
                echo ""
                echo -e "  ${BOLD}Exit policies:${NC}"
                echo -e "  • ${GREEN}Reduced${NC} — Only allows common ports (80, 443, etc.)"
                echo -e "  • ${YELLOW}Default${NC} — Tor's standard exit policy"
                echo -e "  • ${RED}Full${NC} — Allows all traffic (most complaints)"
                echo ""
                echo -e "  ${BOLD}Only run an exit relay if you understand the legal risks${NC}"
                echo -e "  ${BOLD}and your hosting provider explicitly permits it.${NC}"
                ;;
            5)
                echo -e "${CYAN}═══ Snowflake Proxy (WebRTC) ═══${NC}"
                echo ""
                echo -e "  Snowflake is a pluggable transport that uses ${BOLD}WebRTC${NC} to help"
                echo -e "  censored users connect to the Tor network. It's different from"
                echo -e "  running a Tor relay."
                echo ""
                echo -e "  ${BOLD}How Snowflake works:${NC}"
                echo -e "  1. A censored user's Tor client contacts a ${CYAN}broker${NC}"
                echo -e "  2. The broker matches them with an available proxy (${GREEN}you${NC})"
                echo -e "  3. A WebRTC peer-to-peer connection is established"
                echo -e "  4. Your proxy forwards their traffic to a Tor bridge"
                echo -e "  5. The bridge connects them to the Tor network"
                echo ""
                echo -e "  ${BOLD}You are NOT an exit point.${NC} You're a temporary relay between"
                echo -e "  the censored user and a Tor bridge. The traffic is encrypted"
                echo -e "  end-to-end — you cannot see what the user is doing."
                echo ""
                echo -e "  ${BOLD}NAT types (from your logs):${NC}"
                echo -e "  • ${GREEN}unrestricted${NC} — Best. Direct peer connections. Most clients."
                echo -e "  • ${YELLOW}restricted${NC}   — OK. Uses TURN relay for some connections."
                echo -e "  • ${RED}unknown${NC}      — May have connectivity issues."
                echo ""
                echo -e "  ${BOLD}Resource usage:${NC} Very lightweight (0.5 CPU, 128MB RAM)."
                echo -e "  Can run safely alongside any relay type."
                ;;
            6)
                echo -e "${CYAN}═══ How Tor Circuits Work ═══${NC}"
                echo ""
                echo -e "  A Tor circuit is a path through 3 relays:"
                echo ""
                echo -e "  ${GREEN}You${NC} → [${CYAN}Guard/Bridge${NC}] → [${YELLOW}Middle${NC}] → [${RED}Exit${NC}] → ${BOLD}Destination${NC}"
                echo ""
                echo -e "  ${BOLD}Each layer of encryption:${NC}"
                echo -e "  ┌──────────────────────────────────────────────┐"
                echo -e "  │ Layer 3 (Guard key):                         │"
                echo -e "  │  ┌──────────────────────────────────────┐    │"
                echo -e "  │  │ Layer 2 (Middle key):                │    │"
                echo -e "  │  │  ┌──────────────────────────────┐    │    │"
                echo -e "  │  │  │ Layer 1 (Exit key):          │    │    │"
                echo -e "  │  │  │  ┌──────────────────────┐    │    │    │"
                echo -e "  │  │  │  │ Your actual data     │    │    │    │"
                echo -e "  │  │  │  └──────────────────────┘    │    │    │"
                echo -e "  │  │  └──────────────────────────────┘    │    │"
                echo -e "  │  └──────────────────────────────────────┘    │"
                echo -e "  └──────────────────────────────────────────────┘"
                echo ""
                echo -e "  • The Guard peels Layer 3, sees the Middle address"
                echo -e "  • The Middle peels Layer 2, sees the Exit address"
                echo -e "  • The Exit peels Layer 1, sees the destination"
                echo -e "  • ${BOLD}No single relay knows both source and destination${NC}"
                echo ""
                echo -e "  Circuits are rebuilt every ~10 minutes for extra security."
                ;;
            7)
                echo -e "${CYAN}═══ Understanding Your Dashboard ═══${NC}"
                echo ""
                echo -e "  ${BOLD}Circuits:${NC}"
                echo -e "  Active Tor circuits passing through your relay right now."
                echo -e "  Each circuit is a 3-hop encrypted path. One user can have"
                echo -e "  multiple circuits open (Tor rotates every ~10 minutes),"
                echo -e "  so circuits ≠ users. 9 circuits might be 3-5 users."
                echo ""
                echo -e "  ${BOLD}Connections:${NC}"
                echo -e "  Number of OR (Onion Router) connections to other relays."
                echo -e "  These are connections to Tor infrastructure (directory"
                echo -e "  authorities, other relays), not direct user connections."
                echo -e "  A new bridge with 15 connections is normal — most are"
                echo -e "  Tor network overhead, not individual users."
                echo ""
                echo -e "  ${BOLD}Traffic (Downloaded/Uploaded):${NC}"
                echo -e "  Total bytes relayed since the container started."
                echo -e "  Includes both user traffic and Tor protocol overhead"
                echo -e "  (consensus downloads, descriptor fetches, etc.)."
                echo -e "  Low traffic (KB range) in the first hours is normal."
                echo ""
                echo -e "  ${BOLD}App CPU / RAM:${NC}"
                echo -e "  Resource usage of your Tor container(s). CPU is normalized"
                echo -e "  per-core (e.g. 0.33% of one core), with total vCPU usage"
                echo -e "  shown in parentheses (e.g. 3.95% across all cores)."
                echo ""
                echo -e "  ${BOLD}Snowflake section:${NC}"
                echo -e "  Connections: total clients matched to your proxy by the"
                echo -e "  Snowflake broker (cumulative, not concurrent)."
                echo -e "  Traffic: WebRTC data relayed to Tor bridges."
                echo ""
                echo -e "  ${BOLD}Country breakdown (CLIENTS BY COUNTRY):${NC}"
                echo -e "  ${YELLOW}Important: This is NOT real-time connected users.${NC}"
                echo -e "  For bridges, this shows unique clients seen in the ${BOLD}last 24"
                echo -e "  hours${NC} (from Tor's CLIENTS_SEEN). So '8 from Estonia' means"
                echo -e "  8 unique clients from Estonia used your bridge in the past"
                echo -e "  day, not 8 people connected right now."
                echo -e "  For relays: countries of peer relays you're connected to."
                echo -e "  For Snowflake: countries of users you've proxied for."
                echo ""
                echo -e "  ${BOLD}Data Cap:${NC}"
                echo -e "  If configured, shows Tor's AccountingMax usage. Tor will"
                echo -e "  hibernate automatically when the cap is reached and resume"
                echo -e "  at the start of the next accounting period."
                echo ""
                echo -e "  ${BOLD}What's normal for a new bridge?${NC}"
                echo -e "  • First few minutes: 0 circuits, low KB traffic (just Tor overhead)"
                echo -e "  • After 1-3 hours: a few circuits, some client countries appear"
                echo -e "  • After 24 hours: steady circuits, growing country list"
                echo -e "  • After days/weeks: stable traffic as BridgeDB distributes you"
                ;;
            8)
                echo -e "${CYAN}═══ Legal & Safety Considerations ═══${NC}"
                echo ""
                echo -e "  ${BOLD}Bridges (safest):${NC}"
                echo -e "  • IP not publicly listed. Minimal legal risk."
                echo -e "  • No abuse complaints. You're an unlisted entry point."
                echo -e "  • Recommended for home connections and most hosting."
                echo ""
                echo -e "  ${BOLD}Middle relays (safe):${NC}"
                echo -e "  • IP is publicly listed as a Tor relay."
                echo -e "  • Very rarely generates complaints — you're not an exit."
                echo -e "  • Some organizations may flag Tor relay IPs."
                echo ""
                echo -e "  ${BOLD}Exit relays (requires caution):${NC}"
                echo -e "  • Your IP is the apparent source of users' traffic."
                echo -e "  • You WILL receive abuse complaints."
                echo -e "  • Check with your ISP/hosting provider first."
                echo -e "  • Consider running a reduced exit policy."
                echo -e "  • The Tor Project provides a legal FAQ:"
                echo -e "    ${CYAN}https://community.torproject.org/relay/community-resources/eff-tor-legal-faq/${NC}"
                echo ""
                echo -e "  ${BOLD}Snowflake (very safe):${NC}"
                echo -e "  • You're a temporary WebRTC proxy, not an exit."
                echo -e "  • Traffic is encrypted end-to-end."
                echo -e "  • Very low legal risk."
                echo ""
                echo -e "  ${BOLD}General tips:${NC}"
                echo -e "  • Run on a VPS/dedicated server rather than home if possible"
                echo -e "  • Use a separate IP from your personal services"
                echo -e "  • Set a contact email so Tor directory authorities can reach you"
                echo -e "  • Keep your relay updated (Torware handles Docker image updates)"
                ;;
            9)
                echo -e "${CYAN}═══ About Torware ═══${NC}"
                echo ""
                echo -e "  ${BOLD}Torware v${VERSION}${NC}"
                echo -e "  An all-in-one tool for running Tor relays with Docker."
                echo ""
                echo -e "  ${BOLD}Features:${NC}"
                echo -e "  • Setup wizard — Bridge, Middle, or Exit relay in minutes"
                echo -e "  • Multi-container — Run up to 5 relays on one host"
                echo -e "  • Mixed types — Different relay types per container"
                echo -e "  • Snowflake — Run a WebRTC proxy alongside your relay"
                echo -e "  • Live dashboard — Real-time stats from Tor's ControlPort"
                echo -e "  • Country tracking — See where your traffic goes"
                echo -e "  • Telegram alerts — Get notified about your relay"
                echo -e "  • Backup/restore — Preserve your relay identity keys"
                echo -e "  • Health checks — 15-point diagnostic system"
                echo -e "  • Auto-start — Systemd service for boot persistence"
                echo ""
                echo -e "  ${BOLD}How it works:${NC}"
                echo -e "  Torware manages Docker containers running official Tor images."
                echo -e "  Each container gets a generated torrc config, unique ports,"
                echo -e "  and resource limits. Stats are collected via Tor's ControlPort"
                echo -e "  protocol (port 9051+) using cookie authentication."
                echo ""
                echo -e "  ${BOLD}Open source:${NC}"
                echo -e "  ${CYAN}https://github.com/ssmirr/torware${NC}"
                ;;
            0)
                _back=true
                continue
                ;;
            *)
                echo -e "  ${RED}Invalid choice${NC}"
                ;;
        esac

        if [ "$_back" = "false" ]; then
            echo ""
            read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
        fi
    done
}

show_menu() {
    load_settings
    local redraw=true

    while true; do
        if [ "$redraw" = "true" ]; then
            clear
            print_header
        fi
        redraw=true

        echo -e "  ${BOLD}Main Menu:${NC}"
        echo ""
        echo -e "    ${GREEN}1.${NC} 📊 Live Dashboard"
        echo -e "    ${GREEN}2.${NC} 📈 Advanced Stats"
        echo -e "    ${GREEN}3.${NC} 🌍 Live Peers by Country"
        echo -e "    ${GREEN}4.${NC} 📜 View Logs"
        echo -e "    ${GREEN}5.${NC} ▶  Start Relay"
        echo -e "    ${GREEN}6.${NC} ⏹  Stop Relay"
        echo -e "    ${GREEN}7.${NC} 🔄 Restart Relay"
        echo -e "    ${GREEN}8.${NC} 🔍 Health Check"
        echo -e "    ${GREEN}9.${NC} ⚙  Settings & Tools"
        echo -e "    ${GREEN}f.${NC} 🔑 Show Fingerprint(s)"
        # Show bridge option if any container is a bridge
        local _any_bridge=false
        for _mi in $(seq 1 ${CONTAINER_COUNT:-1}); do
            [ "$(get_container_relay_type $_mi)" = "bridge" ] && _any_bridge=true
        done
        if [ "$_any_bridge" = "true" ]; then
            echo -e "    ${GREEN}b.${NC} 🌉 Show Bridge Line(s)"
        fi
        # Show Snowflake status
        if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
            local _sf_label="${GREEN}Running${NC}"
            is_snowflake_running || _sf_label="${RED}Stopped${NC}"
            echo -e "    ${GREEN}s.${NC} ❄  Snowflake Proxy [${_sf_label}]"
        else
            echo -e "    ${GREEN}s.${NC} ❄  Enable Snowflake Proxy"
        fi
        echo -e "    ${GREEN}t.${NC} 💬 Telegram Notifications"
        echo -e "    ${GREEN}a.${NC} 📖 About & Learn"
        echo -e "    ${GREEN}0.${NC} 🚪 Exit"
        echo ""

        read -p "  Enter choice: " choice < /dev/tty || { echo ""; break; }

        case "$choice" in
            1)
                show_dashboard
                ;;
            2)
                show_advanced_stats
                ;;
            3)
                show_peers
                ;;
            4)
                show_logs
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            5)
                start_relay
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            6)
                stop_relay
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            7)
                restart_relay
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            8)
                health_check
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            9)
                show_settings_menu
                ;;
            f|F)
                show_fingerprint
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            b|B)
                if [ "$_any_bridge" = "true" ]; then
                    show_bridge_line
                    read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                else
                    echo -e "  ${RED}Invalid choice${NC}"
                    redraw=false
                fi
                ;;
            s|S)
                if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                    echo ""
                    echo -e "  Snowflake is currently ${GREEN}enabled${NC}."
                    echo -e "  Resources: CPU: ${CYAN}${SNOWFLAKE_CPUS:-1.0}${NC}  RAM: ${CYAN}${SNOWFLAKE_MEMORY:-256m}${NC}"
                    echo ""
                    echo -e "    1. Restart Snowflake proxy"
                    echo -e "    2. Stop Snowflake proxy"
                    echo -e "    3. Disable Snowflake"
                    echo -e "    4. Change resource limits"
                    echo -e "    0. Back"
                    read -p "  choice: " sf_choice < /dev/tty || true
                    case "${sf_choice:-0}" in
                        1) restart_snowflake_container ;;
                        2)
                            stop_snowflake_container
                            log_warn "Snowflake stopped but still enabled. It will restart on next 'torware start'. Use option 3 to disable permanently."
                            ;;
                        3)
                            SNOWFLAKE_ENABLED="false"
                            stop_snowflake_container
                            save_settings
                            log_success "Snowflake disabled"
                            ;;
                        4)
                            echo ""
                            echo -e "  ${BOLD}Current limits:${NC} CPU: ${SNOWFLAKE_CPUS:-1.0}, RAM: ${SNOWFLAKE_MEMORY:-256m}"
                            echo ""
                            echo -e "  ${DIM}CPU: number of cores (e.g. 0.5, 1.0, 2.0)${NC}"
                            echo -e "  ${DIM}RAM: amount with unit (e.g. 128m, 256m, 512m, 1g)${NC}"
                            echo ""
                            read -p "  CPU cores [${SNOWFLAKE_CPUS:-1.0}]: " _sf_cpu < /dev/tty || true
                            read -p "  RAM limit [${SNOWFLAKE_MEMORY:-256m}]: " _sf_mem < /dev/tty || true
                            # Validate CPU (must be a number)
                            if [ -n "$_sf_cpu" ]; then
                                if [[ "$_sf_cpu" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                                    SNOWFLAKE_CPUS="$_sf_cpu"
                                else
                                    log_warn "Invalid CPU value, keeping ${SNOWFLAKE_CPUS:-1.0}"
                                fi
                            fi
                            # Validate RAM (must be number + m or g)
                            if [ -n "$_sf_mem" ]; then
                                if [[ "$_sf_mem" =~ ^[0-9]+[mMgG]$ ]]; then
                                    SNOWFLAKE_MEMORY=$(echo "$_sf_mem" | tr '[:upper:]' '[:lower:]')
                                else
                                    log_warn "Invalid RAM value, keeping ${SNOWFLAKE_MEMORY:-256m}"
                                fi
                            fi
                            save_settings
                            log_success "Snowflake limits updated: CPU=${SNOWFLAKE_CPUS}, RAM=${SNOWFLAKE_MEMORY}"
                            echo ""
                            read -p "  Restart Snowflake to apply? [Y/n] " _sf_rs < /dev/tty || true
                            if [[ ! "$_sf_rs" =~ ^[Nn]$ ]]; then
                                restart_snowflake_container
                            fi
                            ;;
                    esac
                else
                    echo ""
                    echo -e "  Snowflake is a WebRTC proxy that helps censored users"
                    echo -e "  connect to Tor. Runs as a lightweight separate container."
                    read -p "  Enable Snowflake proxy? [y/N] " sf_en < /dev/tty || true
                    if [[ "$sf_en" =~ ^[Yy]$ ]]; then
                        SNOWFLAKE_ENABLED="true"
                        save_settings
                        run_snowflake_container
                    fi
                fi
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            t|T)
                show_telegram_menu
                ;;
            a|A)
                show_about
                ;;
            0|q|Q)
                echo "  Goodbye!"
                exit 0
                ;;
            "")
                redraw=false
                ;;
            *)
                echo -e "  ${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                redraw=false
                ;;
        esac
    done
}

manage_containers() {
    load_settings
    local redraw=true

    while true; do
        if [ "$redraw" = "true" ]; then
            clear
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${CYAN}                   MANAGE CONTAINERS                            ${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        fi
        redraw=true

        echo ""
        echo -e "  ${BOLD}Current containers: ${GREEN}${CONTAINER_COUNT:-1}${NC}"
        echo ""
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local _rt=$(get_container_relay_type $i)
            local _cn=$(get_container_name $i)
            local _or=$(get_container_orport $i)
            local _pt=$(get_container_ptport $i)
            local _st="${RED}stopped${NC}"
            docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_cn}$" && _st="${GREEN}running${NC}"
            echo -e "    ${GREEN}${i}.${NC} ${_cn} — type: ${BOLD}${_rt}${NC}, ORPort: ${_or}, PTPort: ${_pt} [${_st}]"
        done

        echo ""
        echo -e "    ${GREEN}a.${NC} ➕ Add container"
        if [ "${CONTAINER_COUNT:-1}" -gt 1 ]; then
            echo -e "    ${GREEN}r.${NC} ➖ Remove last container"
        fi
        echo -e "    ${GREEN}c.${NC} 🔄 Change container type"
        echo -e "    ${GREEN}0.${NC} ← Back"
        echo ""
        read -p "  choice: " _mc < /dev/tty || { echo ""; break; }

        case "$_mc" in
            a|A)
                local _cur=${CONTAINER_COUNT:-1}
                if [ "$_cur" -ge 5 ]; then
                    log_warn "Maximum 5 containers supported"
                else
                    local _new=$((_cur + 1))
                    echo ""
                    echo -e "  ${BOLD}Select type for container ${_new}:${NC}"
                    echo ""
                    echo -e "    ${GREEN}1.${NC} 🌉 Bridge (obfs4)"
                    echo -e "       Secret entry point for censored users (Iran, China, etc.)"
                    echo -e "       IP stays ${GREEN}unlisted${NC}. Typical bandwidth: ${CYAN}1-10 Mbps${NC}"
                    echo ""
                    echo -e "    ${GREEN}2.${NC} 🔁 Middle Relay"
                    echo -e "       Backbone of the Tor network. Relays encrypted traffic."
                    echo -e "       IP is ${YELLOW}publicly listed${NC}. Typical bandwidth: ${CYAN}10-50+ Mbps${NC}"
                    echo ""
                    echo -e "    ${GREEN}3.${NC} 🚪 Exit Relay"
                    echo -e "       Final hop — traffic exits to the internet through you."
                    echo -e "       IP appears as ${RED}traffic source${NC}. Typical bandwidth: ${CYAN}20-100+ Mbps${NC}"
                    echo ""
                    read -p "  type [1-3]: " _type_choice < /dev/tty || continue
                    local _new_type=""

                    # Check if adding middle/exit alongside existing bridges
                    local _has_bridge=false
                    for _ci in $(seq 1 $_cur); do
                        [ "$(get_container_relay_type $_ci)" = "bridge" ] && _has_bridge=true
                    done

                    case "$_type_choice" in
                        1) _new_type="bridge" ;;
                        2)
                            _new_type="middle"
                            if [ "$_has_bridge" = "true" ]; then
                                echo ""
                                echo -e "  ${YELLOW}${BOLD}⚠  Note: You are currently running a bridge.${NC}"
                                echo -e "  ${YELLOW}Adding a middle relay will make your IP ${BOLD}publicly visible${NC}"
                                echo -e "  ${YELLOW}in the Tor consensus. This partly defeats the purpose of${NC}"
                                echo -e "  ${YELLOW}running a bridge (keeping your IP unlisted).${NC}"
                                echo ""
                                echo -e "  ${YELLOW}If you're on a home connection, consider running multiple${NC}"
                                echo -e "  ${YELLOW}bridges instead, or using a separate VPS for the middle relay.${NC}"
                                echo ""
                                read -p "  Continue anyway? [y/N] " _mconf < /dev/tty || continue
                                if [[ ! "$_mconf" =~ ^[Yy]$ ]]; then
                                    log_info "Cancelled."
                                    continue
                                fi
                            fi
                            ;;
                        3)
                            if [ "$_has_bridge" = "true" ]; then
                                echo ""
                                echo -e "  ${YELLOW}${BOLD}⚠  You are running a bridge — adding an exit relay will${NC}"
                                echo -e "  ${YELLOW}make your IP publicly visible AND the source of exit traffic.${NC}"
                            fi
                            echo ""
                            echo -e "  ${RED}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
                            echo -e "  ${RED}${BOLD}║              ⚠  EXIT RELAY WARNING  ⚠                   ║${NC}"
                            echo -e "  ${RED}${BOLD}╠═══════════════════════════════════════════════════════════╣${NC}"
                            echo -e "  ${RED}║ Your IP will appear as the source of ALL traffic         ║${NC}"
                            echo -e "  ${RED}║ exiting through this relay. This means:                  ║${NC}"
                            echo -e "  ${RED}║                                                          ║${NC}"
                            echo -e "  ${RED}║ • You WILL receive abuse complaints (DMCA, hacking, etc) ║${NC}"
                            echo -e "  ${RED}║ • Law enforcement may contact you about user traffic     ║${NC}"
                            echo -e "  ${RED}║ • Some ISPs/hosts explicitly prohibit exit relays        ║${NC}"
                            echo -e "  ${RED}║ • Your IP may be blacklisted by some services            ║${NC}"
                            echo -e "  ${RED}║                                                          ║${NC}"
                            echo -e "  ${RED}║ Only run an exit relay if:                               ║${NC}"
                            echo -e "  ${RED}║ • Your ISP/hosting provider explicitly allows it         ║${NC}"
                            echo -e "  ${RED}║ • You understand the legal implications                  ║${NC}"
                            echo -e "  ${RED}║ • You use a dedicated IP (not your personal one)         ║${NC}"
                            echo -e "  ${RED}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
                            echo ""
                            read -p "  Type 'I UNDERSTAND' to proceed (or anything else to cancel): " _confirm < /dev/tty || continue
                            if [ "$_confirm" = "I UNDERSTAND" ]; then
                                _new_type="exit"
                                echo ""
                                echo -e "  ${BOLD}Exit policy:${NC}"
                                echo -e "    ${GREEN}1.${NC} Reduced — web only (ports 80, 443) ${DIM}(recommended)${NC}"
                                echo -e "    ${GREEN}2.${NC} Default — Tor's standard exit policy"
                                echo -e "    ${GREEN}3.${NC} Full    — all traffic ${RED}(most abuse complaints)${NC}"
                                read -p "  policy [1-3, default=1]: " _pol < /dev/tty || true
                                case "${_pol:-1}" in
                                    2) EXIT_POLICY="default" ;;
                                    3) EXIT_POLICY="full" ;;
                                    *) EXIT_POLICY="reduced" ;;
                                esac
                            else
                                log_info "Exit relay cancelled."
                                continue
                            fi
                            ;;
                        *) log_warn "Invalid choice"; continue ;;
                    esac

                    CONTAINER_COUNT=$_new
                    eval "RELAY_TYPE_${_new}='${_new_type}'"
                    save_settings
                    generate_torrc $_new

                    local _new_or=$(get_container_orport $_new)
                    local _new_pt=$(get_container_ptport $_new)
                    echo ""
                    log_success "Container ${_new} added (type: ${_new_type})"
                    echo -e "  ORPort: ${_new_or}, PTPort: ${_new_pt}"
                    echo ""
                    echo -e "  ${YELLOW}⚠ Ports to forward (if running from home):${NC}"
                    echo -e "    ${GREEN}${_new_or} TCP${NC} (ORPort)"
                    [ "$_new_type" = "bridge" ] && echo -e "    ${GREEN}${_new_pt} TCP${NC} (obfs4)"
                    echo ""
                    read -p "  Start container now? [Y/n] " _start < /dev/tty || true
                    if [[ ! "$_start" =~ ^[Nn]$ ]]; then
                        local _img=$(get_docker_image $_new)
                        log_info "Pulling image (${_img})..."
                        docker pull "$_img" || { log_error "Failed to pull image"; continue; }
                        run_relay_container $_new
                        # Restart tracker to pick up new container
                        stop_tracker_service
                        setup_tracker_service
                    fi
                fi
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            r|R)
                if [ "${CONTAINER_COUNT:-1}" -le 1 ]; then
                    log_warn "Cannot remove the last container"
                else
                    local _last=${CONTAINER_COUNT}
                    local _lname=$(get_container_name $_last)
                    local _ltype=$(get_container_relay_type $_last)
                    echo ""
                    echo -e "  Remove container ${_last} (${_lname}, type: ${_ltype})?"
                    read -p "  Confirm [y/N]: " _rc < /dev/tty || true
                    if [[ "$_rc" =~ ^[Yy]$ ]]; then
                        # Stop and remove the container
                        docker stop --timeout 30 "$_lname" 2>/dev/null || true
                        docker rm "$_lname" 2>/dev/null || true
                        # Clear per-container vars
                        eval "unset RELAY_TYPE_${_last}"
                        eval "unset BANDWIDTH_${_last}"
                        eval "unset ORPORT_${_last}"
                        eval "unset PT_PORT_${_last}"
                        CONTAINER_COUNT=$((_last - 1))
                        save_settings
                        # Restart tracker
                        stop_tracker_service
                        setup_tracker_service
                        log_success "Container ${_last} removed"
                    fi
                fi
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            c|C)
                echo ""
                read -p "  Which container to change? [1-${CONTAINER_COUNT:-1}]: " _ci < /dev/tty || continue
                if ! [[ "$_ci" =~ ^[1-5]$ ]] || [ "$_ci" -gt "${CONTAINER_COUNT:-1}" ]; then
                    log_warn "Invalid container number"
                    continue
                fi
                local _old_rt=$(get_container_relay_type $_ci)
                echo ""
                echo -e "  Container ${_ci} is currently: ${BOLD}${_old_rt}${NC}"
                echo ""
                echo -e "    ${GREEN}1.${NC} 🌉 Bridge  — IP unlisted, ${CYAN}1-10 Mbps${NC}"
                echo -e "    ${GREEN}2.${NC} 🔁 Middle  — IP public, ${CYAN}10-50+ Mbps${NC}"
                echo -e "    ${GREEN}3.${NC} 🚪 Exit    — IP is traffic source, ${CYAN}20-100+ Mbps${NC}"
                echo ""
                read -p "  new type [1-3]: " _nt < /dev/tty || continue
                local _change_type=""

                # Check if other containers are bridges
                local _other_bridge=false
                for _oi in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    [ "$_oi" = "$_ci" ] && continue
                    [ "$(get_container_relay_type $_oi)" = "bridge" ] && _other_bridge=true
                done

                case "$_nt" in
                    1) _change_type="bridge" ;;
                    2)
                        _change_type="middle"
                        if [ "$_old_rt" = "bridge" ] || [ "$_other_bridge" = "true" ]; then
                            echo ""
                            echo -e "  ${YELLOW}${BOLD}⚠  Warning: This will make your IP publicly visible${NC}"
                            echo -e "  ${YELLOW}in the Tor consensus. If you also run a bridge on this${NC}"
                            echo -e "  ${YELLOW}IP, the bridge's unlisted status is compromised.${NC}"
                            echo ""
                            read -p "  Continue? [y/N] " _mwarn < /dev/tty || continue
                            if [[ ! "$_mwarn" =~ ^[Yy]$ ]]; then
                                log_info "Cancelled."
                                continue
                            fi
                        fi
                        ;;
                    3)
                        if [ "$_old_rt" = "bridge" ] || [ "$_other_bridge" = "true" ]; then
                            echo ""
                            echo -e "  ${YELLOW}${BOLD}⚠  You have a bridge on this IP — an exit relay will${NC}"
                            echo -e "  ${YELLOW}expose your IP publicly AND attract abuse complaints.${NC}"
                        fi
                        echo ""
                        echo -e "  ${RED}${BOLD}⚠  EXIT RELAY WARNING${NC}"
                        echo -e "  ${RED}Your IP will be the apparent source of all exiting traffic.${NC}"
                        echo -e "  ${RED}You WILL receive abuse complaints. Your IP may be blacklisted.${NC}"
                        echo -e "  ${RED}Only proceed if your ISP/host allows it and you understand the risks.${NC}"
                        echo ""
                        read -p "  Type 'I UNDERSTAND' to proceed: " _ec < /dev/tty || continue
                        if [ "$_ec" = "I UNDERSTAND" ]; then
                            _change_type="exit"
                            echo ""
                            echo -e "  ${BOLD}Exit policy:${NC}"
                            echo -e "    ${GREEN}1.${NC} Reduced — web only (80, 443) ${DIM}(recommended)${NC}"
                            echo -e "    ${GREEN}2.${NC} Default — Tor standard"
                            echo -e "    ${GREEN}3.${NC} Full    — all traffic ${RED}(most complaints)${NC}"
                            read -p "  policy [1-3, default=1]: " _ep < /dev/tty || true
                            case "${_ep:-1}" in
                                2) EXIT_POLICY="default" ;;
                                3) EXIT_POLICY="full" ;;
                                *) EXIT_POLICY="reduced" ;;
                            esac
                        else
                            log_info "Cancelled."
                            continue
                        fi
                        ;;
                    *) log_warn "Invalid choice"; continue ;;
                esac

                if [ "$_change_type" = "$_old_rt" ]; then
                    log_info "Type unchanged"
                else
                    eval "RELAY_TYPE_${_ci}='${_change_type}'"
                    # Also update global RELAY_TYPE if container 1
                    [ "$_ci" = "1" ] && RELAY_TYPE="$_change_type"
                    save_settings
                    generate_torrc $_ci
                    log_success "Container ${_ci} changed to: ${_change_type}"
                    echo ""
                    local _cn=$(get_container_name $_ci)
                    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_cn}$"; then
                        read -p "  Restart container to apply? [Y/n] " _rs < /dev/tty || true
                        if [[ ! "$_rs" =~ ^[Nn]$ ]]; then
                            docker stop --timeout 30 "$_cn" 2>/dev/null || true
                            docker rm "$_cn" 2>/dev/null || true
                            local _img=$(get_docker_image $_ci)
                            log_info "Pulling image (${_img})..."
                            docker pull "$_img" || { log_error "Failed to pull image"; continue; }
                            run_relay_container $_ci
                            stop_tracker_service
                            setup_tracker_service
                        fi
                    fi
                fi
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            0|q|Q)
                return
                ;;
            "")
                redraw=false
                ;;
            *)
                echo -e "  ${RED}Invalid choice${NC}"
                redraw=false
                ;;
        esac
    done
}

show_settings_menu() {
    local redraw=true

    while true; do
        if [ "$redraw" = "true" ]; then
            clear
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${CYAN}                    SETTINGS & TOOLS                           ${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        fi
        redraw=true

        echo ""
        echo -e "    ${GREEN}1.${NC} 📋 View Status"
        echo -e "    ${GREEN}2.${NC} 💾 Backup Relay Keys"
        echo -e "    ${GREEN}3.${NC} 📥 Restore Relay Keys"
        echo -e "    ${GREEN}4.${NC} 🔄 Restart Tracker Service"
        echo -e "    ${GREEN}5.${NC} ℹ  Version Info"
        echo -e "    ${GREEN}6.${NC} 🐳 Manage Containers"
        echo -e "    ${GREEN}7.${NC} 🗑  Uninstall"
        echo -e "    ${GREEN}0.${NC} ← Back"
        echo ""

        read -p "  Enter choice: " choice < /dev/tty || { echo ""; break; }

        case "$choice" in
            1)
                show_status
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            2)
                backup_keys
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            3)
                restore_keys
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            4)
                stop_tracker_service
                setup_tracker_service
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            5)
                show_version
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty
                ;;
            6)
                manage_containers
                ;;
            7)
                uninstall
                exit 0
                ;;
            0|q|Q)
                return
                ;;
            "")
                redraw=false
                ;;
            *)
                echo -e "  ${RED}Invalid choice${NC}"
                redraw=false
                ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# Management Script Generation
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    log_info "Creating management script..."

    # Copy the entire script as the management tool
    if [ -f "$0" ] && [ -r "$0" ]; then
        if ! cp "$0" "$INSTALL_DIR/torware"; then
            log_error "Failed to copy management script"
        fi
    else
        # Running from pipe - try to download
        local script_url="https://raw.githubusercontent.com/SamNet-dev/torware/main/torware.sh"
        if ! curl -sL "$script_url" -o "$INSTALL_DIR/torware" 2>/dev/null; then
            log_error "Could not download management script. Run installer again from file (not pipe) to fix."
        fi
    fi

    chmod +x "$INSTALL_DIR/torware"
    ln -sf "$INSTALL_DIR/torware" /usr/local/bin/torware

    # Verify symlink
    if [ ! -x /usr/local/bin/torware ]; then
        log_warn "Symlink creation may have failed — try running 'torware' from $INSTALL_DIR/torware directly"
    fi

    log_success "Management CLI installed: /usr/local/bin/torware"
}

#═══════════════════════════════════════════════════════════════════════
# Installation Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}║         🧅 TORWARE INSTALLED SUCCESSFULLY!              ║${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}║  Your Tor relay is now running!                                    ║${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}║  Commands:                                                        ║${NC}"
    echo -e "${GREEN}║    torware menu        - Interactive management menu             ║${NC}"
    echo -e "${GREEN}║    torware status       - View relay status                      ║${NC}"
    echo -e "${GREEN}║    torware health       - Run health diagnostics                 ║${NC}"
    echo -e "${GREEN}║    torware fingerprint  - Show relay fingerprint                 ║${NC}"
    local _s_any_bridge=false
    for _si in $(seq 1 ${CONTAINER_COUNT:-1}); do
        [ "$(get_container_relay_type $_si)" = "bridge" ] && _s_any_bridge=true
    done
    if [ "$_s_any_bridge" = "true" ]; then
    echo -e "${GREEN}║    torware bridge-line  - Show bridge line for sharing           ║${NC}"
    fi
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
    echo -e "${GREEN}║    torware snowflake    - Snowflake proxy status                 ║${NC}"
    fi
    echo -e "${GREEN}║    torware logs         - Stream container logs                  ║${NC}"
    echo -e "${GREEN}║    torware --help       - Full command reference                 ║${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}║  Note: It may take a few minutes for your relay to bootstrap       ║${NC}"
    echo -e "${GREEN}║  and appear in the Tor consensus.                                  ║${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Show firewall reminder
    local count=${CONTAINER_COUNT:-1}
    echo -e "${YELLOW}  ⚠ If you have a firewall enabled, make sure these ports are open:${NC}"
    for i in $(seq 1 $count); do
        local orport=$(get_container_orport $i)
        local _rt=$(get_container_relay_type $i)
        if [ "$_rt" = "bridge" ]; then
            local ptport=$(get_container_ptport $i)
            echo -e "    Relay $i (bridge): ORPort ${GREEN}${orport}/tcp${NC}, obfs4 ${GREEN}${ptport}/tcp${NC}"
        else
            echo -e "    Relay $i ($_rt): ORPort ${GREEN}${orport}/tcp${NC}"
        fi
    done
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo -e "    Snowflake: Uses ephemeral UDP ports (${GREEN}${SNOWFLAKE_PORT_RANGE}${NC}) — typically auto-traversed via WebRTC"
    fi
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# CLI Entry Point
#═══════════════════════════════════════════════════════════════════════

cli_main() {
    load_settings

    case "${1:-}" in
        start)
            start_relay
            ;;
        stop)
            stop_relay
            ;;
        restart)
            restart_relay
            ;;
        status)
            show_status
            ;;
        dashboard|dash)
            show_dashboard
            ;;
        stats)
            show_advanced_stats
            ;;
        peers)
            show_peers
            ;;
        menu)
            show_menu
            ;;
        logs)
            show_logs
            ;;
        health)
            health_check
            ;;
        fingerprint)
            show_fingerprint
            ;;
        bridge-line|bridgeline)
            show_bridge_line
            ;;
        backup)
            backup_keys
            ;;
        restore)
            restore_keys
            ;;
        snowflake)
            if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                echo -e "  Snowflake proxy: ${GREEN}enabled${NC}"
                if is_snowflake_running; then
                    echo -e "  Status: ${GREEN}running${NC}"
                    local sf_s=$(get_snowflake_stats 2>/dev/null)
                    echo -e "  Connections: $(echo "$sf_s" | awk '{print $1}')"
                    echo -e "  Traffic: ↓ $(format_bytes $(echo "$sf_s" | awk '{print $2}'))  ↑ $(format_bytes $(echo "$sf_s" | awk '{print $3}'))"
                else
                    echo -e "  Status: ${RED}stopped${NC}"
                    echo -e "  Run 'torware start' to start all containers"
                fi
            else
                echo -e "  Snowflake proxy: ${DIM}disabled${NC}"
                echo -e "  Enable via 'torware menu' > Snowflake option"
            fi
            ;;
        version|--version|-v)
            show_version
            ;;
        uninstall)
            uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# Main Installer
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Usage: $0 [--force]"
    echo ""
    echo "Options:"
    echo "  --force    Force reinstall even if already installed"
    echo "  --help     Show this help message"
}

main() {
    # Parse arguments — extract flags first, then dispatch commands
    local _args=()
    for _arg in "$@"; do
        case "$_arg" in
            --force) FORCE_REINSTALL=true ;;
            --help|-h) show_usage; exit 0 ;;
            *) _args+=("$_arg") ;;
        esac
    done

    # Dispatch CLI commands if any non-flag args remain
    if [ ${#_args[@]} -gt 0 ]; then
        case "${_args[0]}" in
            start|stop|restart|status|dashboard|dash|stats|peers|menu|logs|health|fingerprint|bridge-line|bridgeline|backup|restore|snowflake|version|--version|-v|uninstall|help)
                cli_main "${_args[@]}"
                exit $?
                ;;
        esac
    fi

    # If we get here, we're in installer mode
    check_root
    print_header
    detect_os

    echo ""

    # Check if already installed
    if [ -f "$INSTALL_DIR/settings.conf" ] && [ "$FORCE_REINSTALL" != "true" ]; then
        echo -e "${CYAN}  Torware is already installed.${NC}"
        echo ""
        echo "  What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || { echo -e "\n  ${RED}Input error.${NC}"; exit 1; }

        case "$choice" in
            1)
                echo -e "${CYAN}Opening management menu...${NC}"
                create_management_script
                exec "$INSTALL_DIR/torware" menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice.${NC}"
                exit 1
                ;;
        esac
    fi

    # Check dependencies
    log_info "Checking dependencies..."
    check_dependencies

    echo ""

    # Interactive settings
    prompt_relay_settings

    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""

    #───────────────────────────────────────────────────────────────
    # Installation Steps
    #───────────────────────────────────────────────────────────────

    # Step 1: Install Docker
    log_info "Step 1/5: Installing Docker..."
    if ! install_docker; then
        log_error "Docker installation failed. Cannot continue."
        exit 1
    fi

    echo ""

    # Step 2: Check for backup restore
    log_info "Step 2/5: Checking for previous relay identity..."
    check_and_offer_backup_restore || true

    echo ""

    # Step 3: Start relay containers
    log_info "Step 3/5: Starting Torware..."
    # Clean up any existing containers (including Snowflake)
    for i in $(seq 1 5); do
        local cname=$(get_container_name $i)
        docker stop --timeout 30 "$cname" 2>/dev/null || true
        docker rm -f "$cname" 2>/dev/null || true
    done
    docker stop --timeout 10 "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
    docker rm -f "$SNOWFLAKE_CONTAINER" 2>/dev/null || true
    run_all_containers

    echo ""

    # Step 4: Save settings and auto-start
    log_info "Step 4/5: Setting up auto-start & tracker..."
    if ! save_settings; then
        log_error "Failed to save settings."
        exit 1
    fi
    setup_autostart
    setup_tracker_service 2>/dev/null || true

    echo ""

    # Step 5: Create management CLI
    log_info "Step 5/5: Creating management script..."
    create_management_script

    # Create stats directory
    mkdir -p "$STATS_DIR"

    print_summary

    read -p "Open management menu now? [Y/n] " open_menu < /dev/tty || true
    if [[ ! "$open_menu" =~ ^[Nn]$ ]]; then
        "$INSTALL_DIR/torware" menu
    fi
}

main "$@"
