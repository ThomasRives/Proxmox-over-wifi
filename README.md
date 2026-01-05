# Setting up Proxmox over wifi

This repository will explain how to configure Proxmox with only Wifi.
Nevertheless,
**ethernet is required to download necessary packages to workwith Wifi**.

## Warning

Please do not forget that **Proxmox does not support WIFI**
**configuration**. You are strongly advised to follow Proxmox recommendation
for your production. This repo is made for people using Proxmox in their
homelab without the possibility to use recommended ethernet setup.

## Setup prerequisites

### If you have ethernet cable and port
In this phase ethernet connexion is required.

```sh
apt update
apt -y install wpasupplicant
```

Ethernet is no longer required !

### If you do not have ethernet cable or port

You will need:
- A machine with internet access
- A usb key with a filesystem compatible with linux.

We will create a package to install wpasupplicant.

Go to [Debian apt packages search page](https://packages.debian.org/index)
and search for **wpasupplicant**.

Then, on the *Exact hits* section, click on a version
(the latest stable if possible).
You will see the list of **wpasupplicant** dependencies. You have to download
them manually.

To know which one are already installed on Proxmox, you can use the command:
```sh
apt list --installed | grep "dependency_name"
```

If the command print the dependency name, it is already installed.

For instance, when I tested on Proxmox 9.1, the 4 of January 2026, I needed:
- libnl-genl-3-200
- libpcsclite1
- and of course wpasupplicant

Once you downloaded them, put them all on a usb key and plug it in your
Proxmox server.
Detect your USB key and mount it:
```sh
lsblk
# Look at the size to know which one is your key
# It looks like sdb1 for instance

mkdir /data_wpasupplicant
mount /dev/[XXX] # replace [XXX] with your usb key

apt install /data_wpasupplicant/[package_name].deb # Do this for each package !
```

And you are good to go !


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

Then get all the interfaces available on your machine:
```sh
ip a | grep -E "^[^ ]" | cut -d ':' -f2
```

The Wifi interfaces usually starts with a **w**.
Mine is **wlo1** for instance but it can start with something like **wlp**
(this is not a full list, you can have something else on your side).

And last but not least, edit `/etc/network/interfaces`, to add this:
```sh
# Configure the wifi interface identified just above with the wpa_supplicant
# configuration
auto [wifi_interface]
iface [wifi_interface] inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
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

**WARNING**: For this file, I advise you to **remove all comments and blank**
**lines**. As Proxmox parse this file for the UI, it needs to be in the
expected format !

## Configure DHCP for VMs and LXCs

### dnsmasq configuration

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
dhcp-option=3,[proxmox_server_ip]
# Example:
# dhcp-option=3,192.168.1.30
```


### Static IP

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

## Optionnal: Access VMs from local network

With the previous configuration, the VMs and LXCs where hidden in a private
network.
If you want, you can make all the VMs and LXCs accessible from your normal
network !

It needs some preparation though...

First, you need a range of IPs reserved to your machines. It means that these IP
addresses **can not be given by your DHCP server (your box)**. This shall be a
subnetwork like **192.168.1.192/26**. If you do not understand this notation and
what it implies, you can read [this article](https://michelburnett27.medium.com/understanding-cidr-notation-and-ip-address-range-3ad28194bc8d).

In simple terms, all IPs in the subnetwork will be reserved for the VMs and
LXCs. So do not take to much ips or your other equipments may be unable to
connect to the box... I strongly advise you to check the number of IPs that
can be attributed by your box and take a small part of them (1/4 max) for
the VMs and LXCs.

Then we will have to edit a few things:

`/etc/network/interfaces`:
```sh
auto vmbr0
iface vmbr0 inet static
        address 10.10.1.193/26
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        # Here, note that all the previous config was replaced
        post-up   iptables -t nat -A POSTROUTING -s '[nated_subnet]' -o [wifi_interface] -j NETMAP --to '[normal_subnet]'
        post-up   iptables -t nat -A PREROUTING  -d '[normal_subnet]' -j NETMAP --to '[nated_subnet]'
        post-up   ip r add local '[normal_subnet]' dev [wifi_interface]
        post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t nat -D PREROUTING  -d '[normal_subnet]' -j NETMAP --to '[nated_subnet]'
        post-down iptables -t nat -D POSTROUTING -s '[nated_subnet]' -o [wifi_interface] -j NETMAP --to '[normal_subnet]'
        # Anwer ARP requests that fall in the natted range
        post down ip r del local '[normal_subnet]' dev [wifi_interface]
        post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

**WARNING**: Same as before, for this file, I advise you to
**remove all comments and blank lines**. As Proxmox parse this file for the UI,
it needs to be in the expected format !

As an example, lets say your box provide ips on 192.168.1.0/24, we reserve the
subnet 192.168.1.192/26. To ease the mapping, we will use the 10.10.1.192/26
in our nat. We have:
```sh
auto vmbr0
iface vmbr0 inet static
        address 10.10.1.193/26
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        # Here, note that all the previous config was replaced
        post-up   iptables -t nat -A POSTROUTING -s '10.10.1.192/26' -o [wifi_interface] -j NETMAP --to '192.168.1.192/26
        post-up   iptables -t nat -A PREROUTING  -d '192.168.1.192/26 -j NETMAP --to '10.10.1.192/26'
        post-up   ip r add local '192.168.1.192/26 dev [wifi_interface]
        post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t nat -D PREROUTING  -d '192.168.1.192/26 -j NETMAP --to '10.10.1.192/26'
        post-down iptables -t nat -D POSTROUTING -s '10.10.1.192/26' -o [wifi_interface] -j NETMAP --to '192.168.1.192/26
        # Anwer ARP requests that fall in the natted range
        post down ip r del local '192.168.1.192/26 dev [wifi_interface]
        post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

This is just an exemple, feel free to adapt it to fit your needs.

`/etc/dnsmasq.conf`

Just to match the reserved newly reserved IPs.

For our exemple:
```sh
interface=vmbr0
# 10.10.1.192 is the subnet address, so the first address shall be 10.10.1.193
# 10.10.1.255 is the brodcast address, so the last address shall be 10.10.254
# /26 correspond to netmask 255.255.255.192
dhcp-range=10.10.1.193,10.10.1.254,255.255.255.192,24h


# Just making sure dnsmasq knows the routers IP-Address
dhcp-option=3,[ip_of_proxmox_server_in_normal_network]
```

With this configuration, your VMs and LXCs will be able to access internet and
your local network AND you can access the VMs and LXCs from your local network !



# Special thanks 🎉

- [hotswapster](https://github.com/hotswapster) for spoting an issue with the interfaces file permissions !
