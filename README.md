# Setting up Proxmox over wifi

This repository will explain how to configure Proxmox with only Wifi.
Nevertheless,
**ethernet is required to download necessary packages to workwith Wifi**.

## Setup prerequisites

In this phase ethernet connexion is required.

```sh
apt update
apt -y install wpasupplicant
```

Ethernet is no longer required !

## Connect to wifi

To connect to the Wifi, some configuration is required:

1. First, restrict permissions to allow write only for administrators.

```sh
chmod 0644 /etc/network/interfaces
```

2. Setup wpa_supplicant configuration using your Wifi SSID and password.
        The SSID (or Service Set IDentifier) is your Wifi name.
        Basically it is the name that appears on your computer / phone when
        you connect to it.

```sh
# Replace *[myssid]* with your box/router SSID and
# *[my_very_secret_passphrase]* with the password to connect to the Wifi.
wpa_passphrase [myssid] [my_very_secret_passphrase] > /etc/wpa_supplicant/wpa_supplicant.conf
```

3. Some additional configuration is required on the file
        `/etc/wpa_supplicant/wpa_supplicant.conf`. So you need to open the file:

```sh
nano /etc/wpa_supplicant/wpa_supplicant.conf
```

4. You shall add the following parts:

```sh
# At the beginning of the file:
ctrl_interface=/run/wpa_supplicant
update_config=1
country=[your_country_tag] # Maybe not mandatory

# Inside of the network object:
        proto=WPA RSN # Or whatever proto you are using
        key_mgmt=WPA-PSK # Or whatever key managment you are using
```

To have something like:
```sh
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

```sh
ping www.google.com
```

Your **PVE** is now connected to internet ! 🎉

The sad news is that it is only PVE...
VMs and LXCs containers can not access internet.

For that, a NAT (or Network Address Translation) shall be configured.

*Note*: It is not the only solution but it covers my need so only this solution
will be detailed.

## Configure the NAT

First get all the interfaces available on your machine:
```sh
ip a | grep -E "^[^ ]" | cut -d ':' -f2
```

The Wifi interfaces usually starts with a **w**.
Mine is **wlo1** for instance but it can start with something like **wlp**
(this is not a full list, you can have something else on your side).

To configure a NAT, the file `/etc/network/interfaces` shall be edited to look
like:

```sh
auto lo
iface lo inet loopback

# Configure the wifi interface identified just above with the wpa_supplicant
# configuration
auto [wifi_interface]
iface [wifi_interface] inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

# Create a bridge to trick Proxmox into thinking it is connected through
# ethernet
auto vmbr0
iface vmbr0 inet static
        # Configure the VMs and containers gateway. Usually, this IP ends
        # with a 1. Note that this IP shall be a private IP, it is not an IP
        # provided by your router /box. For instance, if you have IPs like
        # 192.168.X.X on your normal equipments, you may want to go with a
        # 10.10.X.1 gateway (and the other way around)
        address [IP_of_the_VMs_and_container_gateway]/[mask]
        # For instance:
        # address 10.10.1.1/24
        # This IP is only seen in the proxmox server

        bridge-ports none
        bridge-stp off
        bridge-fd 0

        # Enable ipv4 forwarding
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
```

Edit its configuration file:

```sh
nano /etc/dnsmasq.conf
```

To have something like:

```sh
# Add the proxmox as a domain
address=/proxmox/[ip_that_can_be_reached_by_the_box]


# Hosts dnsmasq on vmbr0, the bridge created just before
interface=vmbr0

# The IP-adress range that should be used for the clients
# (virtual machines/containers):
dhcp-range=[first_available_ip],[last_available_ip],[net_mask],[lease_time]
# lease_time looks like: <number>h (5h for instance) to have a lease time in
# hours
# Full example:
# dhcp-range=10.10.1.2,10.10.1.254,255.255.255.0,24h


# Just making sure dnsmasq knows the routers IP-Address
dhcp-option=3,[vmbr0_ip]
# Example:
# dhcp-option=3,192.168.1.30
```


## Add static IP

Add a static ip for a mac address:
```sh
nano /etc/dnsmasq.d/static-ips.conf
```

And put:

```sh
dhcp-host=[MAC],[IP_without_mask],[hostname]
# Example
# dhcp-host=1:22:33:44:55:66,192.168.0.60,my-awseme-vm
# Note that you can also have stuff like:
# dhcp-host=[hostname],[IP_without_mask]
# dhcp-host=[hostname],[IP_without_mask],[lease_time]
# And more ! You can check on the net if you have other needs.
```

VMs and LXCs containers shall now obtain IP throught DHCP.

# Special thanks 🎉

- [hotswapster](https://github.com/hotswapster) for spoting an issue with the interfaces file permissions !
