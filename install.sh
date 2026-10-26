#!/usr/bin/env bash

set -Eeuo pipefail

##################################################
# Constants
##################################################

SCRIPT_NAME="Proxmox-over-WiFi Installer"

TMP_DIR="/tmp/proxmox-over-wifi"

TMP_INTERFACES="${TMP_DIR}/interfaces"
TMP_WPA="${TMP_DIR}/wpa_supplicant.conf"
TMP_DNSMASQ="${TMP_DIR}/dnsmasq.conf"

BACKUP_DIR="/root/proxmox-over-wifi-backup"

##################################################
# Helpers
##################################################

info() {
    echo "[INFO] $*"
}

success() {
    echo "[ OK ] $*"
}

error() {
    echo "[ERR ] $*"
}

ask_yes_no() {
    local prompt="$1"

    while true; do
        read -rp "$prompt [Y/n]: " answer

        case "${answer,,}" in
            ""|y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

##################################################
# Checks
##################################################

check_root() {
    [[ $EUID -eq 0 ]] || {
        error "Run this script as root."
        exit 1
    }
}

check_proxmox() {
    command -v pveversion >/dev/null 2>&1 || {
        error "Proxmox VE not detected."
        exit 1
    }
}

##################################################
# Packages
##################################################

ensure_package() {

    local pkg="$1"

    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        error "Missing $pkg ..."
        exit 1
    fi
}

##################################################
# WiFi Detection
##################################################

detect_wifi_interface() {

    WIFI_INTERFACES=()

    for path in /sys/class/net/*; do
        iface="$(basename "$path")"

        if [[ -d "$path/wireless" ]]; then
            WIFI_INTERFACES+=("$iface")
        fi
    done

    [[ ${#WIFI_INTERFACES[@]} -gt 0 ]] || {
        error "No WiFi interface detected."
        exit 1
    }

    if [[ ${#WIFI_INTERFACES[@]} -eq 1 ]]; then
        WIFI_IF="${WIFI_INTERFACES[0]}"
        return
    fi

    echo
    echo "Detected WiFi interfaces:"
    echo

    for i in "${!WIFI_INTERFACES[@]}"; do
        echo "$((i+1))) ${WIFI_INTERFACES[$i]}"
    done

    echo

    while true; do
        read -rp "Select interface: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 )) &&
           (( choice <= ${#WIFI_INTERFACES[@]} ))
        then
            WIFI_IF="${WIFI_INTERFACES[$((choice-1))]}"
            break
        fi
    done
}

##################################################
# User Questions
##################################################

collect_wifi_information() {

    echo
    echo "WiFi Configuration"
    echo "------------------"

    read -rp "SSID: " WIFI_SSID

    while [[ -z "$WIFI_SSID" ]]; do
        read -rp "SSID: " WIFI_SSID
    done

    read -rsp "Password: " WIFI_PASSWORD
    echo
}

select_mode() {
    echo
    echo "Connectivity Mode"
    echo "-----------------"
    echo
    echo "1) Internet access only"
    echo "   VMs can access the Internet."
    echo "   Home LAN cannot directly access VMs."
    echo
    echo "2) Internet + LAN access"
    echo "   VMs can access the Internet."
    echo "   Home LAN can access VMs."
    echo

    while true; do
        read -rp "Selection [1-2]: " choice

        case "$choice" in
            1)
                MODE="phase3"
                return
                ;;
            2)
                MODE="phase4"
                return
                ;;
        esac
    done
}

collect_network_settings() {
    echo
    echo "VM Network Configuration"
    echo "------------------------"

    read -rp "Bridge name [vmbr0]: " VM_BRIDGE
    VM_BRIDGE="${VM_BRIDGE:-vmbr0}"

    read -rp "Bridge address CIDR (Proxmox IP in NAT) [10.10.1.1/24]: " VM_CIDR
    VM_CIDR="${VM_CIDR:-10.10.1.1/24}"

    read -rp "VM network CIDR [10.10.1.0/24]: " VM_NETWORK
    VM_NETWORK="${VM_NETWORK:-10.10.1.0/24}"

    if [[ "$MODE" == "phase4" ]]; then
        echo
        echo "Home LAN Configuration"
        echo "----------------------"

        read -rp "Home network CIDR reserved for Proxmox [192.168.1.0/24]: " HOME_NETWORK
        HOME_NETWORK="${HOME_NETWORK:-192.168.1.0/24}"
    fi
}

configure_dhcp() {
    echo

    if ask_yes_no "Enable DHCP server for VMs?"; then
        ENABLE_DHCP="true"

        ensure_package dnsmasq

        read -rp "DHCP range start: " DHCP_START
        read -rp "DHCP range end: " DHCP_END
    else
        ENABLE_DHCP="false"
    fi
}

configure_dns() {
    echo

    if ask_yes_no "Use specific DNS for Proxmox host ?"; then
        ENABLE_DNS="true"

        read -rp "IP of the DNS to use: " DNS_IP
    else
        ENABLE_DNS="false"
    fi
}

##################################################
# Config Generation
##################################################

generate_wpa_config() {
    mkdir -p "$TMP_DIR"

    cat > "$TMP_WPA" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASSWORD"
}
EOF
}

generate_interfaces_file() {
    cat > "$TMP_INTERFACES" <<EOF
auto lo
iface lo inet loopback

auto $WIFI_IF
iface $WIFI_IF inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto $VM_BRIDGE
iface $VM_BRIDGE inet static
    address $VM_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
EOF

    if [[ "$ENABLE_DNS" == "true" ]]; then
        cat >> "$TMP_INTERFACES" <<EOF

    post-up   echo 'nameserver $DNS_IP' > /etc/resolv.conf

EOF
    fi

    if [[ "$MODE" == "phase4" ]]; then
    # TODO: Add SNAT and DNAT lines
        cat >> "$TMP_INTERFACES" <<EOF

    post-up   iptables -t nat -A POSTROUTING -s '$VM_NETWORK' -o $WIFI_IF -j NETMAP --to '$HOME_NETWORK'
    post-up   iptables -t nat -A PREROUTING  -d '$HOME_NETWORK' -j NETMAP --to '$VM_NETWORK'
    post-up   iptables -t nat -A OUTPUT -d '$HOME_NETWORK' -j NETMAP --to '$VM_NETWORK'
    post-up   iptables -t nat -A POSTROUTING -s '$VM_NETWORK' -d '$VM_NETWORK' -j MASQUERADE
    post-up   ip route add local '$HOME_NETWORK' dev $WIFI_IF
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1

    post-down iptables -t nat -D PREROUTING  -d '$HOME_NETWORK' -j NETMAP --to '$VM_NETWORK'
    post-down iptables -t nat -D POSTROUTING -s '$VM_NETWORK' -o $WIFI_IF -j NETMAP --to '$VM_NETWORK'
    post-down iptables -t nat -D OUTPUT -d '$HOME_NETWORK' -j NETMAP --to '$VM_NETWORK'
    post-down iptables -t nat -D POSTROUTING -s '$VM_NETWORK' -d '$VM_NETWORK' -j MASQUERADE
    post-down ip route del local '$HOME_NETWORK' dev $WIFI_IF
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1

EOF
    else
        cat >> "$TMP_INTERFACES" <<EOF

    post-up iptables -t nat -A POSTROUTING -s '$VM_NETWORK' -o $WIFI_IF -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$VM_NETWORK' -o $WIFI_IF -j MASQUERADE

EOF
    fi
cat >> "$TMP_INTERFACES" <<EOF

source /etc/network/interfaces.d/*

EOF

}

generate_dnsmasq_config() {
    [[ "$ENABLE_DHCP" == "true" ]] || return

    BRIDGE_IP="${VM_CIDR%/*}"

    cat > "$TMP_DNSMASQ" <<EOF
interface=$VM_BRIDGE
bind-interfaces

dhcp-range=$DHCP_START,$DHCP_END,12h
dhcp-option=3,$BRIDGE_IP
dhcp-option=6,$BRIDGE_IP

conf-dir=/etc/dnsmasq.d,*.conf

EOF
}

##################################################
# Review
##################################################

review_configuration() {
    clear

    echo
    echo "=========================================="
    echo "Configuration Summary"
    echo "=========================================="
    echo

    echo "Mode        : $MODE"
    echo "WiFi        : $WIFI_IF"
    echo "SSID        : $WIFI_SSID"
    echo "Bridge      : $VM_BRIDGE"
    echo "Bridge CIDR : $VM_CIDR"
    echo "VM Network  : $VM_NETWORK"

    if [[ "$MODE" == "phase4" ]]; then
        echo "Home LAN    : $HOME_NETWORK"
    fi

    echo

    if [[ "$ENABLE_DHCP" == "true" ]]; then
        echo "DHCP        : $DHCP_START -> $DHCP_END"
    else
        echo "DHCP        : Disabled"
    fi

    echo
    echo "=========================================="
    echo "Generated /etc/network/interfaces"
    echo "=========================================="
    echo

    cat "$TMP_INTERFACES"

    echo

    if [[ "$ENABLE_DHCP" == "true" ]]; then
        echo
        echo "=========================================="
        echo "Generated dnsmasq configuration"
        echo "=========================================="
        echo

        cat "$TMP_DNSMASQ"
        echo
    fi
}

##################################################
# Apply
##################################################

apply_configuration() {
    ask_yes_no "Apply configuration?" || exit 0

    mkdir -p "$BACKUP_DIR"

    cp /etc/network/interfaces \
       "$BACKUP_DIR/interfaces.bak"

    if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
        cp /etc/wpa_supplicant/wpa_supplicant.conf \
           "$BACKUP_DIR/wpa_supplicant.conf.bak"
    fi

    mkdir -p /etc/wpa_supplicant

    cp "$TMP_INTERFACES" /etc/network/interfaces
    cp "$TMP_WPA" /etc/wpa_supplicant/wpa_supplicant.conf

    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

    if [[ "$ENABLE_DHCP" == "true" ]]; then
        cp "$TMP_DNSMASQ" /etc/dnsmasq.d/proxmox-over-wifi.conf

        systemctl restart dnsmasq
    fi

    if command -v ifreload >/dev/null 2>&1; then
        ifreload -a
    else
        systemctl restart networking
    fi

    success "Configuration applied."
}

##################################################
# Main
##################################################

main() {
    clear

    echo "======================================="
    echo "$SCRIPT_NAME"
    echo "======================================="
    echo

    check_root
    check_proxmox

    ensure_package wpasupplicant

    detect_wifi_interface

    collect_wifi_information
    select_mode
    collect_network_settings
    configure_dhcp
    configure_dns

    generate_wpa_config
    generate_interfaces_file
    generate_dnsmasq_config

    review_configuration
    apply_configuration
}

main "$@"
