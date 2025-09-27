# Raspberry Pi: Pi-hole + NordVPN Gateway

Norwegian · [English](README.en.md)

This project sets up a Raspberry Pi as a combined DNS filtering server (Pi-hole) and NordVPN gateway with selective routing based on IP and/or ports.  
It includes robust startup and monitoring via MQTT and systemd.

---

## 🧭 Goals

- Raspberry Pi with static IP address.
- Pi-hole for local DNS blocking on the whole network.
- NordVPN connection for traffic from selected devices and/or ports.
- Automatic recovery of VPN connection in case of router/network failure.
- (Optional) Integration with Home Assistant via MQTT for monitoring.

---

## 📦 Requirements

- Raspberry Pi 3, 4 or 5 (wired network strongly recommended).
- Raspberry Pi OS Lite (64-bit), Bookworm or newer.
- NordVPN account.
- MQTT broker (optional, only for Home Assistant integration).

---

## ⚠️ Important before you start

- **IPv6**: The setup is IPv4-based. If you have IPv6 active in your network, traffic may leak outside of VPN.  
  **It is strongly recommended to disable IPv6** on the Pi and/or your clients to avoid security holes and leaks.

- **CORRECT_GATEWAY**: In `nordvpn-gateway.sh` you must set the variable `CORRECT_GATEWAY` to the IP address of your own router (e.g. `192.168.1.1`).

- **CPU temp**: Publishing CPU temperature to MQTT is **off by default** (`ENABLE_CPU_TEMP=false`). Enable if you want to use it.

---

## 🔧 Step-by-step setup

### 0. System setup

1. Install Raspberry Pi OS Lite (64-bit).  
2. Connect via SSH.  
3. Update the system:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

   *After reboot, connect via SSH again.*

4. **Set static IP address, gateway and DNS**

   We use `nmcli` (default in newer Raspberry Pi OS):

```bash
# 1) Find the correct connection name (use the one that shows up for TYPE=ethernet)
nmcli -t -f NAME,TYPE con show   # Example: "Wired connection 1"
CONN_NAME="Wired connection 1"

# 2) Set values
RPIS_IP="192.168.1.102/24"
RTR_IP="192.168.1.1"
NET_IFACE="eth0"

# 3) Configure static IPv4 on the connection
sudo nmcli con mod "$CONN_NAME"   ipv4.method manual   ipv4.addresses "$RPIS_IP"   ipv4.gateway "$RTR_IP"   ipv4.dns "1.1.1.1,8.8.8.8"   ipv4.ignore-auto-dns yes   ipv4.ignore-auto-routes yes   ipv4.dhcp-hostname ""   ipv4.dhcp-client-id ""   ipv4.dhcp-timeout 0

# 4) Restart the connection (NOTE: SSH may drop for a few seconds while it comes back up)
echo "Restarting network connection..."
sudo nmcli con down "$CONN_NAME"
sleep 2
sudo nmcli con up "$CONN_NAME"
echo "Network connection restarted."

# 5) Verify
ip addr show dev "$NET_IFACE"
ip route
```

---

### 1. Install Pi-hole

```bash
curl -sSL https://install.pi-hole.net | bash
```

Follow the wizard (choose IPv4, web interface, logging, etc.).  
Note the admin password after installation.

---

### 2. Install iptables-persistent and enable IP forwarding

```bash
sudo apt install iptables-persistent -y
```

- IPv4: Choose `Yes`  
- IPv6: Choose `No`

Edit `/etc/sysctl.conf`:

```bash
sudo nano /etc/sysctl.conf
```

Uncomment or add:
```bash
net.ipv4.ip_forward=1
```

Activate:

```bash
sudo sysctl -p
```

---

### 3. Install and configure NordVPN

Install:

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
sudo usermod -aG nordvpn $USER
sudo reboot
```

After reboot → log in:

Start the login on Raspberry Pi:

```bash
nordvpn login
```
The terminal will give you a long link starting with https://api.nordvpn.com/....

Open the link on PC/Mac, log in with your NordVPN user.

---

After login you will get a page with the text "Great - you're in!" and a Continue button.

Do not click the button.

Right-click on Continue and choose Copy link address.

Go back to Raspberry Pi and complete the login:

```bash
# Copy the callback link:
nordvpn login --callback "nordvpn://login?...your-link..."
```
You should now get a confirmation in the terminal that the login was successful.

Set settings:

```bash
nordvpn set killswitch disabled
nordvpn set dns off
nordvpn set autoconnect disabled
nordvpn set firewall disabled
nordvpn set routing disabled
nordvpn set technology NordLynx
nordvpn set analytics disabled
```

---

### 4. Create own routing table

```bash
grep -qE '^\s*200\s+nordvpntabell' /etc/iproute2/rt_tables ||   echo "200 nordvpntabell" | sudo tee -a /etc/iproute2/rt_tables
```

---

### 5. iptables rules (Secure and selective routing)

This section configures the firewall rules to allow necessary traffic to the Pi, set up selective routing for VPN traffic, and finally tighten security.  
We do this step by step to avoid locking ourselves out.

> **Important:** Confirm you have SSH access to your Pi and that the NordVPN client is installed and configured (Step 3).  
> Make sure you have noted your local network CIDR (e.g. `192.168.1.0/24`), your local network interface (`eth0` or `wlan0`), and that `nordlynx` is the VPN interface.

#### 5.1 Flush existing rules

```bash
echo "--- STEP 5.1: Flushing existing iptables rules ---"
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X
```

#### 5.2 Set temporary, softer default policies

```bash
echo "--- STEP 5.2: Setting temporary ACCEPT policies for debugging ---"
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

#### 5.3 Basic INPUT ACCEPT rules

```bash
echo "--- STEP 5.3: Setting critical INPUT ACCEPT rules ---"
sudo iptables -I INPUT 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I INPUT 2 -i lo -j ACCEPT
sudo iptables -I INPUT 3 -p icmp -j ACCEPT
sudo iptables -I INPUT 4 -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT
```

#### 5.4 The rest of the INPUT rules (DNS + Pi-hole web)

```bash
echo "--- STEP 5.4: Adding the rest of the INPUT rules ---"
sudo iptables -A INPUT -s 192.168.1.0/24 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 80 -j ACCEPT
```

#### 5.5 MANGLE / MARK rules (for selective routing)

```bash
echo "--- STEP 5.5: Setting MANGLE / MARK rules ---"
# Example – replace with the IPs of your clients
CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130 192.168.1.131"  
# Example – replace with your port
PORT_TO_ROUTE_VIA_VPN=8080 
PROTOCOL="tcp"

for ip in $CLIENT_IPS_TO_VPN; do
  echo "Adding MARK rule for $ip (only $PROTOCOL port $PORT_TO_ROUTE_VIA_VPN)"
  sudo iptables -t mangle -A PREROUTING -s "$ip" -p $PROTOCOL --dport $PORT_TO_ROUTE_VIA_VPN -j MARK --set-mark 1
done
```

#### 5.6 FORWARD rules (allow traffic)

```bash
echo "--- STEP 5.6: Setting FORWARD rules ---"
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

LAN_IFACE="eth0"
VPN_IFACE="nordlynx"
sudo iptables -A FORWARD -i $LAN_IFACE -o $VPN_IFACE -m mark --mark 1 -j ACCEPT
```

#### 5.7 NAT rules

```bash
echo "--- STEP 5.7: Setting NAT rules ---"
VPN_IFACE="nordlynx"
LAN_IFACE="eth0"

sudo iptables -t nat -A POSTROUTING -o $VPN_IFACE -j MASQUERADE
# optionally also via LAN:
# sudo iptables -t nat -A POSTROUTING -o $LAN_IFACE -j MASQUERADE
```

#### 5.8 Save all rules permanently

```bash
echo "--- STEP 5.8: Saving rules permanently ---"
sudo netfilter-persistent save
```

> ⚠️ **Note:** After you save the rules (5.8), SSH connection may drop if the INPUT rules are not correct. Double-check you still have access before proceeding.

#### 5.9 Set final, strict policies to DROP

```bash
echo "--- STEP 5.9: Setting FINAL strict policies ---"
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT
```

After these steps:  
1. Start NordVPN manually:  

```bash
nordvpn connect
```

2. Confirm connection:  

```bash
nordvpn status
```

---

### 6. Download and customize the main script

```bash
sudo wget -O /usr/local/bin/nordvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/nordvpn-gateway.sh
sudo chmod +x /usr/local/bin/nordvpn-gateway.sh
sudo nano /usr/local/bin/nordvpn-gateway.sh
```

---

### 7. Create systemd service

```bash
sudo nano /etc/systemd/system/nordvpn-gateway.service
```

Paste the content below:

```ini
[Unit]
Description=NordVPN Gateway Service
Wants=network-online.target NetworkManager-wait-online.service
After=network-online.target NetworkManager-wait-online.service nordvpnd.service

[Service]
Type=simple
User=root
Environment=LANG=C LC_ALL=C
ExecStart=/usr/local/bin/nordvpn-gateway.sh
Restart=always
RestartSec=15
# (Optional hardening – test in your environment first)
# CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
# AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
# NoNewPrivileges=yes
# ProtectSystem=full
# ProtectHome=true
# PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable nordvpn-gateway.service
sudo systemctl start nordvpn-gateway.service
```

---

### 8. Configure the router

- Set **Default Gateway** to Raspberry Pi (e.g. `192.168.1.102`).
- Set **DNS server** to the same address.
- Restart the clients.

---

### 9. Testing and verification

**Service + routing on Pi**

```bash
sudo systemctl status nordvpn-gateway.service
journalctl -u nordvpn-gateway.service -n 30 -f   # Ctrl+C to stop
ip rule show | grep fwmark
ip route show table nordvpntabell                 # (same as: ip route show table 200)
```

Install tcpdump:

```bash
sudo apt update
sudo apt install -y tcpdump
```

Run verification script:

```bash
wget -O verify_traffic.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/verify_traffic.sh
chmod +x verify_traffic.sh
sudo ./verify_traffic.sh
```

Customize at the top of the script:

```bash
PORT=8080
IFACE="nordlynx"
PROTO="tcp"
```

Quick extra checks (optional)

Counters on the mangle rules increase:
```bash
sudo iptables -t mangle -L PREROUTING -v -n | grep 8080
```

---

## 💾 Backup and Maintenance

* Back up `/etc/iptables/rules.v4`, `nordvpn-gateway.sh`, and the systemd unit file.
* Set up logrotate if you use file logging.
* When the setup works, you should take a simple backup of the most important files.  
  Then you can quickly restore the system if you lose the Pi or need to reinstall.

```bash
cp /etc/iptables/rules.v4 ~/rules.v4.backup
cp /usr/local/bin/nordvpn-gateway.sh ~/nordvpn-gateway.sh.backup
sudo cp /etc/systemd/system/nordvpn-gateway.service ~/nordvpn-gateway.service.backup
```
These files can later be copied back to the same places if you reinstall the system.  
Remember to run `sudo netfilter-persistent reload` after restoring rules.v4.

---

## 📨 MQTT and Home Assistant

The script can publish status and sensors to MQTT, so Home Assistant can automatically discover them.  
MQTT is **off** by default (`MQTT_ENABLED=false`).

### Activation

1. **Install MQTT client on Pi**  
   This is needed to send messages (`mosquitto_pub`):

```bash
sudo apt update
sudo apt install mosquitto-clients -y
```

2. **Edit `nordvpn-gateway.sh`**  
   Find the lines at the top of the script and change:

```bash
MQTT_ENABLED=true
MQTT_BROKER="192.168.1.100"   # IP of your MQTT broker (often Home Assistant)
MQTT_USER="username"          # can be left empty if not used
MQTT_PASS="password"          # can be left empty if not used
MQTT_CLIENT_ID="nordvpn_gateway_pi"
HA_DISCOVERY_PREFIX="homeassistant"
```

3. **Restart the service**

```bash
sudo systemctl restart nordvpn-gateway.service
```

### Published topics

When enabled, the following MQTT topics are published (retained):

- `nordvpn/gateway/status` → Connection status (`VPN OK`, `VPN Disconnected`, `VPN Connected`)
- `nordvpn/gateway/last_seen` → Last check time (timestamp)
- `nordvpn/gateway/cpu_temp` → CPU temperature on Pi

### Home Assistant auto-discovery

If the MQTT integration in Home Assistant is configured, the sensors are discovered automatically:

- `sensor.nordvpn_status`
- `sensor.nordvpn_last_seen`
- `sensor.nordvpn_cpu_temp`

---

## 🙌 Acknowledgements

The project is written and maintained by @Howard0000. An AI assistant has helped simplify explanations, clean up the README and polish scripts. All suggestions have been manually reviewed before inclusion, and all configuration and testing have been done by me.

---

## 📝 License

MIT — see LICENSE.
