# 📶 Proxmox Wi-Fi Setup Guide (Homelab Workaround)

## ⚠️ Warnings and risks

Proxmox VE does not officially support Wi-Fi.
This guide is a personal workaround for homelab users who physically cannot run an Ethernet cable.

If you are running Proxmox on production, **please use a wired connectivity** as it is the only officially supported method !

Networking may break during system updates, kernel changes, or driver updates.
I have no control over so if you experience some incompatibilities, feel free to open an issue !
And if you find a fix, feel free to share it !


## 🛠️ Prerequisites

Before starting, ensure you have:
- Proxmox VE installed on your server (you shall also have screen and keyboard for that server to be able to type commands and edit files).
- Either:
    - Temporary Ethernet Access: A cable or USB-Ethernet adapter to install packages initially.
    - A PC with internet connectivity and a USB Flash Drive: To download the dependencies and pass them to the Proxmox server using the USB.

## 🚀 Phase 1: Installing Wi-Fi Drivers

You need wpasupplicant and wireless-tools to connect to Wi-Fi.

### You have temporary Ethernet access (easiest method for me)

Connect your server to the router via Ethernet, open the Proxmox Shell, and run:

```bash
apt update
apt install -y wpasupplicant wireless-tools
```
And that's it ! You can unplug the Ethernet cable !

That's why it is the easiest method.

### You have NO Ethernet access at all (hardest method but I tested it)

If you cannot plug in a cable, you must download the packages on another computer.

Download the .deb files for wpasupplicant and its dependencies.
For that:
1. Go to packages.debian.org and search for wpasupplicant.
2. Download the .deb file for your architecture (usually amd64). Tip: Use the command `apt install --download-only wpasupplicant` on a Linux PC to automatically grab dependencies(there will be stored in `/var/cache/apt/archives`).
3. Copy all downloaded .deb files to a USB drive.
4. Plug the USB drive into your Proxmox server.
5. Find and mount the drive:
```bash
# Find USB key
lsblk

#replace /dev/sd[X] with your actual USB device
mkdir /mnt/usb
mount /dev/sd[X] /mnt/usb
```
6. Install the packages:
```bash
dpkg -i /mnt/usb/*.deb
```
7. Unmount and remove the drive:
```bash
umount /mnt/usb
rmdir /mnt/usb
```

Whichever method you chose, you shall now have the necessary depedencies to connect your Proxmox server to Wi-Fi ! 🎉

## 📡 Phase 2: Connecting to Wi-Fi

Now that the tools are installed, let's connect your server to the network !
It is easy but make sure to not introduce typos here.
Typos are #1 sources of error here, so before looking for system failure or driver error, please think about the [Ockham's razor](https://en.wikipedia.org/wiki/Occam's_razor): "of two competing theories, the simpler explanation of an entity is to be preferred".

### Generate the Wi-Fi Configuration

Replace [YourSSID] and [YourPassword] with your actual credentials.
The SSID is basically the name of your Wi-Fi (you can see it on your phone or PC for instance, ususally, it something like "MyBox-123XYZ).

```bash
wpa_passphrase "[YourSSID]" "[YourPassword]" > /etc/wpa_supplicant/wpa_supplicant.conf
```

### Edit the Configuration File

Open the file to add necessary network parameters: `nano /etc/wpa_supplicant/wpa_supplicant.conf`.
Ensure the file looks like this (add ctrl_interface and update_config at the top):
```txt
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US  # Replace with your country code (e.g., FR, DE, US)

network={
    ssid="[YourSSID]"
    # psk="[YourPassword]"  <-- wpa_passphrase usually hashes this, but you can leave the raw password if preferred
    proto=RSN
    key_mgmt=WPA-PSK
    pairwise=CCMP
    group=CCMP
}
```

### Identify Your Wi-Fi Interface

Run the following to find your Wi-Fi interface name (usually starts with w like wlan0, wlp2s0, or wlx...): ` ip link show`.
Note the name of the interface.

### Configure Network Interfaces

Backup first! `cp /etc/network/interfaces /etc/network/interfaces.backup`.
Then edit the Proxmox network file: `nano /etc/network/interfaces`.
Replace the content with the following (adjust [wifi_interface] and address as needed):

```txt
auto lo
iface lo inet loopback

auto [wifi_interface]
iface [wifi_interface] inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
```
⚠️ Important: Do not include comments (#) or blank lines in /etc/network/interfaces if you plan to use the Proxmox Web UI to manage networking later. Proxmox's parser is strict.

### Reboot the server: `reboot now`

### Test connectivity: `ping -c 4 google.com`


If you get a reply, Proxmox itself is online! 🎉

## 🌐 Phase 3: Enabling Internet for VMs and Containers

By default, VMs and LXC containers cannot access the internet because the host is on Wi-Fi, which doesn't support bridging in the traditional way. We will use NAT (Network Address Translation) to create a virtual bridge.

### Configure the NAT Bridge

Edit `/etc/network/interfaces` again. We will create a virtual bridge vmbr0 that acts as a gateway for your VMs.

For the configuration, keep in mind that your Wi-Fi network will be different from your VMs network. I advise you to use 2 standard private network:
- 192.168.0.0/16
- 172.16/12
- 10.0.0.0/8


Of course, 1 will be taken by your Wi-Fi, so select one from the other 2.

For the rest of the tutorial, **home network** will refer to the network used by all your devices. The VMs /LXCs deployed won't be part of this network.
**VMs network** will refer to the NAT network where the VMs/LXCs lives.

For exemple:

Variables in the configuration:
| Variable | Description | Example |
| -------- | ----------- | ------- |
| [wifi_interface] | The Wi-Fi interface you configured previously | wlp2s0 |
| [Home_network] | The network used by all your *normal* devices | 192.168.1.0/24 |
| [VMs_network] | The network where the VMs lives. It is a private network that is not inclueded in the home network. | 10.10.1.0/24 |
| [Proxmox_host_IP] | The IP of the Proxmox host. It must be in the same network as your normal devices. | 192.168.1.34 |

The configuration shall look like:
```txt
auto lo
iface lo inet loopback

# Wi-Fi Interface
auto [wifi_interface]
iface [wifi_interface] inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

# NAT Bridge for VMs
auto vmbr0
iface vmbr0 inet static
    address [Proxmox_host_IP]/[VMs_network_netmask]
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Enable IP forwarding
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    # NAT rule to route VM traffic to the internet via Wi-Fi
    post-up iptables -t nat -A POSTROUTING -s '[VMs_network]' -o [wifi_interface] -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '[VMs_network]' -o [wifi_interface] -j MASQUERADE
```

### Install DHCP server (dnsmasq)

Dnsmasq will be used to give VMs automatic IP addresses:
`apt install dnsmasq` (you are connected to internet so no need to reuse one of the technique above).

### Edit the main config: `nano /etc/dnsmasq.conf`

Add or ensure these lines exist:
```txt
# Listen on the vmbr0 bridge
interface=vmbr0
# Disable default DHCP on other interfaces
except-interface=lo
except-interface=[wifi_interface]
# Do this for every unused interface
except-interface=[other_unused_interface]

# DHCP Range for VMs
dhcp-range=[first_ip_of_VM_in_vm_network],[last_ip_of_VM_in_vm_network],[netmask_in_dot_format_for_VM_network],[lease_time]
# Exemple:
# dhcp-range=10.10.1.194,10.10.1.222,255.255.255.224,24h

# Gateway and DNS for VMs (points to the Proxmox host)
dhcp-option=3,[Proxmox_host_IP]
dhcp-option=6,[Proxmox_host_IP]


conf-dir=/etc/dnsmasq.d,*.conf
```

### Optional, configure static IP

Create a separated file `/etc/dnsmasq.d/static-ips.conf` in the following format:
```txt
dhcp-host=[MAC_ADDRESS],[IP_ADDRESS],[HOSTNAME]
# Exemple:
# dhcp-host=52:54:00:12:34:56,10.10.1.50,my-ubuntu-vm
```

### Restart dnsmasq: `systemctl restart dnsmasq`

Result: Your VMs and containers can now access the internet, but they are on the VMs network and cannot be reached from your main home network.

## 🏠 Phase 4 (Advanced): Making VMs Accessible from Your Home Network

If you want your VMs to have IPs on your main home network so other devices can reach them, you must use NETMAP (a complex form of NAT) or a specific subnet reservation.

⚠️ **Complexity Warning**: This requires coordination with your Router's DHCP settings to avoid IP conflicts.

### Reserve a Subnet on Your Router

Log into your router.
Find your LAN subnet (ex: 192.168.1.0/24).
Reserve a block of IPs for Proxmox VMs (ex: 192.168.1.200 to 192.168.1.255).
**Important**: Ensure your router does not assign these IPs to other devices.

### Configure Proxmox for NETMAP

We will map an internal subnet (10.10.1.0/24) to your reserved home subnet (192.168.1.200/26).

Edit `/etc/network/interfaces`:

```txt
auto lo
iface lo inet loopback

auto [wifi_interface]
iface [wifi_interface] inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto vmbr0
iface vmbr0 inet static
    address [Proxmox_host_IP]/[VMs_network_netmask]
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward

    # Route default traffic to the Wi-Fi interface
    post-up ip route add default via $(ip route | grep [wifi_interface] | awk '{print $3}') dev [wifi_interface]

    # Map Internal 10.10.10.x to Home 192.168.1.200.x
    post-up iptables -t nat -A POSTROUTING -s '[VMs_network]' -o [wifi_interface] -j NETMAP --to '[reserved_home_network]'
    post-up iptables -t nat -A PREROUTING -d '[reserved_home_network]' -j NETMAP --to '[VMs_network]'

    # Handle ARP requests so the router sees the VMs
    post-up ip route add local '[reserved_home_network]' dev [wifi_interface]
    post-up iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1

    post-down ip route del default via $(ip route | grep [wifi_interface] | awk '{print $3}') dev [wifi_interface]
    post-down iptables -t nat -D POSTROUTING -s '[VMs_network]' -o [wifi_interface] -j NETMAP --to '[reserved_home_network]'
    post-down iptables -t nat -D PREROUTING -d '[reserved_home_network]' -j NETMAP --to '[VMs_network]'
    post-down ip route del local '[reserved_home_network]' dev [wifi_interface]
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

Exemple:
```txt
auto lo
iface lo inet loopback

auto wlp2s0
iface wlp2s0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward

    # Route default traffic to the Wi-Fi interface
    post-up ip route add default via $(ip route | grep wlp2s0 | awk '{print $3}') dev wlp2s0

    # Map Internal 10.10.10.x to Home 192.168.1.200.x
    post-up iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o wlp2s0 -j NETMAP --to '192.168.1.200/26'
    post-up iptables -t nat -A PREROUTING -d '192.168.1.200/26' -j NETMAP --to '10.10.10.0/24'

    # Handle ARP requests so the router sees the VMs
    post-up ip route add local '192.168.1.200/26' dev wlp2s0
    post-up iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1

    post-down ip route del default via $(ip route | grep wlp2s0 | awk '{print $3}') dev wlp2s0
    post-down iptables -t nat -D POSTROUTING -s '10.10.10.0/24' -o wlp2s0 -j NETMAP --to '192.168.1.200/26'
    post-down iptables -t nat -D PREROUTING -d '192.168.1.200/26' -j NETMAP --to '10.10.10.0/24'
    post-down ip route del local '192.168.1.200/26' dev wlp2s0
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

### Update dnsmasq (if necessary):

Update `/etc/dnsmasq.conf` to serve the internal IPs (which are then mapped).

### Configure VM Network Settings

For each VM:

Set the network device to Bridge: vmbr0.
Set the VM's internal IP to the mapped address (ex: if you want the VM to be 192.168.1.201, set the VM's internal IP to 10.10.10.1).
Note: This can be confusing. The VM thinks it is 10.10.10.x, but the network sees it as 192.168.1.200+.
Alternatively, set the VM to Static IP 10.10.10.x and let the NAT handle the mapping.

## 🛠️ Troubleshooting

### Cannot connect after reboot?
Check if wpa_supplicant is running: `systemctl status wpa_supplicant`. Check logs: `journalctl -u wpa_supplicant`.

### VMs have no internet?
Verify ip_forward is enabled: `cat /proc/sys/net/ipv4/ip_forward` (should be `1`). Check iptables rules: `iptables -t nat -L -n -v`.


# Special Thanks🎉

- [hotswapster](https://github.com/hotswapster) for spoting an issue with the interfaces file permissions !

# Final disclaimer

This guide is **NOT** for production. It is made for homelabs or non critic environments that cannot have ethernet. Use at your own risk.
