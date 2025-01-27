# Setting up Proxmox over wifi

This repository will explain how to configure Proxmox with only Wifi.
Nevertheless, ethernet is required to download necessary  packages to work with Wifi.

## Connect to wifi
In this phase ethernet connexion is required.

Install the necessary packages:
```sh
apt update
apt -y install wpasupplicant
```
Ethernet is no longer required !

Connect to wifi:
```sh
# Restrict permissions to allow write only for administrators.
chmod 0644 /etc/network/interfaces
# Replace [myssid] with your box/router SSID
# Replace [my_very_secret_passphrase] with the password to connect to it
wpa_passphrase [myssid] [my_very_secret_passphrase] > /etc/wpa_supplicant/wpa_supplicant.conf
```

Further configuration:
```sh
nano /etc/wpa_supplicant/wpa_supplicant.conf
```

You shall had:
```
# At the beginning of the file:
ctrl_interface=/run/wpa_supplicant
update_config=1
country=[your_country_tag] # Maybe not mandatory

# In the network object:
        proto=WPA RSN # Or whatever proto you are using
        key_mgmt=WPA-PSK # Or whatever key managment you are using
```

To have something like:
```
ctrl_interface=/run/wpa_supplicant
update_config=1
country=FR

network={
        ssid="[myssid]"
#       psk="[my_very_secret_passphrase]"
        psk="random_stuff_that_corresponds_to_the_password_hash"
        proto=WPA RSN
        key_mgmt=WPA-PSK
}
```

Reboot your Proxmox:
```sh
reboot
```

You shall now be connected to internet.
Try to ping google to see if it is the case:
```
ping www.google.com
```

Your **PVE** is now connected to internet !
The sad news is that it is only PVE...
VMs and LXCs containers can not access internet.

For that, a NAT shall be configured.
*Note*: It is not the only solution but it covers my need so only this solution will be detailed.

## Configure the NAT

To configure a NAT, the file `/etc/network/interfaces` shall be edited to look like:
```
auto lo
iface lo inet loopback

auto [wifi_interface]
iface [wifi_interface] inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto vmbr0
iface vmbr0 inet static
        address [IP_of_the_VMs_and_container_gateway]/[mask]
        # For instance:
        # address 10.10.1.1/24
        # This IP is only seen in the proxmox server
        bridge-ports none
        bridge-stp off
        bridge-fd 0

        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        # Route from VM to internet
        post-up   iptables -t nat -A POSTROUTING -s '[IP_of_the_VMs_and_container_subnet]' -o [wifi_interface] -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '[IP_of_the_VMs_and_container_subnet]' -o [wifi_interface] -j MASQUERADE
        # For the example:
        # post-up   iptables -t nat -A POSTROUTING -s '10.10.1.0/24' -o [wifi_interface] -j MASQUERADE
        # post-down iptables -t nat -D POSTROUTING -s '10.10.1.0/24' -o [wifi_interface] -j MASQUERADE
        # To reach other device in network (for firewall reasons)
        post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

## Configure DHCP for VMs and LXCs

Install dnsmasq:

```sh
apt install dnsmasq
nano /etc/dnsmasq.conf
```


Put this in the file:
```
# Add the proxmox as a domain
address=/proxmox/ip_that_can_be_reached_by_the_box

# Hosts dnsmasq on vmbr0
interface=vmbr0

# The IP-adress range that should be used for the clients (virtual machines/containers):
dhcp-range=first_available_ip,last_available_ip,net_mask,lease_time(<number>h)

# Just making sure dnsmasq knows the routers IP-Address
dhcp-option=3,vmbr0_ip
```


## Add static IP

Add a static ip for a mac address:
```sh
nano /etc/dnsmasq.d/static-ips.conf
```

and put
```
dhcp-host=MAC,IP_without_mask,hostname
```

VMs and LXCs containers shall now obtain IP throught DHCP.

# Special thanks 🎉

- [hotswapster](https://github.com/hotswapster) for spoting an issue with the interfaces file permissions !
