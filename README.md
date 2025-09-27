# Raspberry Pi: Pi-hole + NordVPN Gateway

Norsk · [English](README.en.md)

Dette prosjektet setter opp en Raspberry Pi som en kombinert DNS-filtreringsserver (Pi-hole) og NordVPN-gateway med selektiv ruting basert på IP og/eller porter.  
Det inkluderer robust oppstart og overvåkning via MQTT og systemd.

---

## 🧭 Mål

- Raspberry Pi med statisk IP-adresse.
- Pi-hole for lokal DNS-blokkering på hele nettverket.
- NordVPN-tilkobling for trafikk fra utvalgte enheter og/eller porter.
- Automatisk gjenoppretting av VPN-tilkobling ved ruter-/nettverksfeil.
- (Valgfritt) Integrasjon med Home Assistant via MQTT for overvåkning.

---

## 📦 Krav

- Raspberry Pi 3, 4 eller 5 (kablet nettverk er sterkt anbefalt).
- Raspberry Pi OS Lite (64-bit), Bookworm eller nyere.
- NordVPN-konto.
- MQTT-broker (valgfritt, kun for Home Assistant-integrasjon).

---

## ⚠️ Viktig før du starter

- **IPv6**: Oppsettet er IPv4-basert. Hvis du har IPv6 aktivt i nettverket ditt, kan trafikk lekke utenom VPN.  
  **Det anbefales sterkt å deaktivere IPv6** på Pi-en og/eller klientene dine for å unngå sikkerhetshull og lekkasjer.

- **CORRECT_GATEWAY**: I `nordvpn-gateway.sh` må du sette variabelen `CORRECT_GATEWAY` til IP-adressen til din egen ruter (f.eks. `192.168.1.1`).

- **CPU-temp**: Publisering av CPU-temperatur til MQTT er **av som standard** (`ENABLE_CPU_TEMP=false`). Skru på om du vil bruke den.

---

## 🔧 Steg-for-steg-oppsett

### 0. Systemoppsett

1. Installer Raspberry Pi OS Lite (64-bit).  
2. Koble til via SSH.  
3. Oppdater systemet:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

   *Etter omstart, koble til via SSH igjen.*

4. **Sett statisk IP-adresse, gateway og DNS**

   Vi bruker `nmcli` (standard i nyere Raspberry Pi OS):


  ```bash
  # 1) Finn riktig tilkoblingsnavn (bruk det som dukker opp for TYPE=ethernet)
  nmcli -t -f NAME,TYPE con show   # Eksempel: "Wired connection 1"
  CONN_NAME="Wired connection 1"

  # 2) Sett verdier
  RPIS_IP="192.168.1.102/24"
  RTR_IP="192.168.1.1"
  NET_IFACE="eth0"

  # 3) Konfigurer statisk IPv4 på tilkoblingen
  sudo nmcli con mod "$CONN_NAME" \
    ipv4.method manual \
    ipv4.addresses "$RPIS_IP" \
    ipv4.gateway "$RTR_IP" \
    ipv4.dns "1.1.1.1,8.8.8.8" \
    ipv4.ignore-auto-dns yes \
    ipv4.ignore-auto-routes yes \
    ipv4.dhcp-hostname "" \
    ipv4.dhcp-client-id "" \
    ipv4.dhcp-timeout 0

  # 4) Restart tilkoblingen (NB: SSH kan falle et par sekunder mens den kommer opp igjen)
  echo "Starter nettverkstilkobling på nytt..."
  sudo nmcli con down "$CONN_NAME"
  sleep 2
  sudo nmcli con up "$CONN_NAME"
  echo "Nettverkstilkobling restartet."

  # 5) Verifiser
  ip addr show dev "$NET_IFACE"
  ip route
  ```

---

### 1. Installer Pi-hole

```bash
curl -sSL https://install.pi-hole.net | bash
```

Følg veiviseren (velg IPv4, webgrensesnitt, logging, osv.).  
Noter admin-passordet etter installasjonen.

---

### 2. Installer iptables-persistent og aktiver IP forwarding

```bash
sudo apt install iptables-persistent -y
```

- IPv4: Velg `Yes`  
- IPv6: Velg `No`

Rediger `/etc/sysctl.conf`:

```bash
sudo nano /etc/sysctl.conf
```

Avkommenter eller legg til:
```bash
net.ipv4.ip_forward=1
```


Aktiver:

```bash
sudo sysctl -p
```

---

### 3. Installer og konfigurer NordVPN

Installer:

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
sudo usermod -aG nordvpn $USER
sudo reboot
```

Etter omstart → logg inn:

Start innloggingen på Raspberry Pi:

```bash
nordvpn login
```
Terminalen vil gi deg en lang lenke som starter med https://api.nordvpn.com/....

Åpne lenken på PC/Mac, logg inn med NordVPN-brukeren din.

---

Etter innlogging får du en side med teksten "Great - you're in!" og en Continue-knapp.

Ikke klikk på knappen.

Høyreklikk på Continue og velg Kopier lenkeadresse.

Gå tilbake til Raspberry Pi og fullfør innloggingen:

```bash
# Kopier callback-lenken:
nordvpn login --callback "nordvpn://login?...din-lenke..."
```
Du skal nå få en bekreftelse i terminalen på at innloggingen var vellykket.


Sett innstillinger:

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

### 4. Opprett egen routing-tabell

```bash
grep -qE '^\s*200\s+nordvpntabell' /etc/iproute2/rt_tables || \
  echo "200 nordvpntabell" | sudo tee -a /etc/iproute2/rt_tables
```

---

### 5. iptables-regler (Sikker og selektiv ruting)

Denne delen konfigurerer brannmurreglene for å tillate nødvendig trafikk til Pi-en, sette opp selektiv ruting for VPN-trafikk, og til slutt stramme inn sikkerheten.  
Vi gjør dette trinnvis for å unngå å låse oss ute.

> **Viktig:** Bekreft at du har SSH-tilgang til Pi-en din og at NordVPN-klienten er installert og konfigurert (Steg 3).  
> Sørg for at du har notert ditt lokale nettverks-CIDR (f.eks. `192.168.1.0/24`), ditt lokale nettverksgrensesnitt (`eth0` eller `wlan0`), og at `nordlynx` er VPN-grensesnittet.

#### 5.1 Tøm eksisterende regler

```bash
echo "--- STEG 5.1: Tømmer eksisterende iptables-regler ---"
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X
```

#### 5.2 Sett midlertidige, mykere standardpolicyer

```bash
echo "--- STEG 5.2: Setter midlertidige ACCEPT policyer for feilsøking ---"
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

#### 5.3 Grunnleggende INPUT ACCEPT-regler

```bash
echo "--- STEG 5.3: Setter kritiske INPUT ACCEPT-regler ---"
sudo iptables -I INPUT 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I INPUT 2 -i lo -j ACCEPT
sudo iptables -I INPUT 3 -p icmp -j ACCEPT
sudo iptables -I INPUT 4 -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT
```

#### 5.4 Resten av INPUT-reglene (DNS + Pi-hole web)

```bash
echo "--- STEG 5.4: Legger til resten av INPUT-regler ---"
sudo iptables -A INPUT -s 192.168.1.0/24 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 80 -j ACCEPT
```

#### 5.5 MANGLE / MARK-regler (for selektiv ruting)

```bash
echo "--- STEG 5.5: Setter MANGLE / MARK-regler ---"
# Eksempel – bytt til IP-ene til dine klienter
CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130 192.168.1.131"  
# Eksempel – bytt til din port
PORT_TO_ROUTE_VIA_VPN=8080 
PROTOCOL="tcp"

for ip in $CLIENT_IPS_TO_VPN; do
  echo "Legger til MARK-regel for $ip (kun $PROTOCOL port $PORT_TO_ROUTE_VIA_VPN)"
  sudo iptables -t mangle -A PREROUTING -s "$ip" -p $PROTOCOL --dport $PORT_TO_ROUTE_VIA_VPN -j MARK --set-mark 1
done
```

#### 5.6 FORWARD-regler (tillat trafikk)

```bash
echo "--- STEG 5.6: Setter FORWARD-regler ---"
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

LAN_IFACE="eth0"
VPN_IFACE="nordlynx"
sudo iptables -A FORWARD -i $LAN_IFACE -o $VPN_IFACE -m mark --mark 1 -j ACCEPT
```

#### 5.7 NAT-regler

```bash
echo "--- STEG 5.7: Setter NAT-regler ---"
VPN_IFACE="nordlynx"
LAN_IFACE="eth0"

sudo iptables -t nat -A POSTROUTING -o $VPN_IFACE -j MASQUERADE
# valgfritt også via LAN:
# sudo iptables -t nat -A POSTROUTING -o $LAN_IFACE -j MASQUERADE
```

#### 5.8 Lagre alle reglene permanent

```bash
echo "--- STEG 5.8: Lagrer reglene permanent ---"
sudo netfilter-persistent save
```

> ⚠️ **Merk:** Etter at du lagrer reglene (5.8), kan SSH-tilkoblingen falle dersom INPUT-reglene ikke er riktige. Dobbeltsjekk at du fremdeles har tilgang før du går videre.

#### 5.9 Sett endelige, strenge policyer til DROP

```bash
echo "--- STEG 5.9: Setter ENDELIG de strenge policyene ---"
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT
```

Etter disse stegene:  
1. Start NordVPN manuelt:  

```bash
nordvpn connect
```

2. Bekreft tilkobling:  

```bash
nordvpn status
```

---

### 6. Last ned og tilpass hovedskriptet

```bash
sudo wget -O /usr/local/bin/nordvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/nordvpn-gateway.sh
sudo chmod +x /usr/local/bin/nordvpn-gateway.sh
sudo nano /usr/local/bin/nordvpn-gateway.sh
```

---

### 7. Opprett systemd-tjeneste

```bash
sudo nano /etc/systemd/system/nordvpn-gateway.service
```

Lim inn innholdet under:

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
# (Valgfri herding – test i ditt miljø først)
# CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
# AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
# NoNewPrivileges=yes
# ProtectSystem=full
# ProtectHome=true
# PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Aktiver tjenesten:

```bash
sudo systemctl daemon-reload
sudo systemctl enable nordvpn-gateway.service
sudo systemctl start nordvpn-gateway.service
```
---

### 8. Konfigurer ruteren

- Sett **Default Gateway** til Raspberry Pi (eks. `192.168.1.102`).
- Sett **DNS-server** til samme adresse.
- Start klientene på nytt.

---

### 9. Testing og verifisering

**Tjeneste + ruting på Pi**


```bash
sudo systemctl status nordvpn-gateway.service
journalctl -u nordvpn-gateway.service -n 30 -f   # Ctrl+C for å stoppe
ip rule show | grep fwmark
ip route show table nordvpntabell                 # (samme som: ip route show table 200)
```

Installer tcpdump:

```bash
sudo apt update
sudo apt install -y tcpdump
```

Kjør verifiseringsskript:

```bash
wget -O verify_traffic.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/verify_traffic.sh
chmod +x verify_traffic.sh
sudo ./verify_traffic.sh
```

Tilpass i toppen av skriptet:

```bash
PORT=8080
IFACE="nordlynx"
PROTO="tcp"
```
Kjappe ekstra sjekker (valgfritt)

Tellere på mangle-reglene øker:
```bash
sudo iptables -t mangle -L PREROUTING -v -n | grep 8080
```


---

## 💾 Backup og Vedlikehold

* Ta backup av `/etc/iptables/rules.v4`, `nordvpn-gateway.sh`, og systemd-unit-filen.
* Sett opp logrotate om du bruker fil-logging.
* Når oppsettet fungerer, bør du ta en enkel backup av de viktigste filene.  
  Da kan du raskt gjenopprette systemet hvis du mister Pi-en eller må reinstallere.

```bash
cp /etc/iptables/rules.v4 ~/rules.v4.backup
cp /usr/local/bin/nordvpn-gateway.sh ~/nordvpn-gateway.sh.backup
sudo cp /etc/systemd/system/nordvpn-gateway.service ~/nordvpn-gateway.service.backup
```
Disse filene kan du senere kopiere tilbake til samme steder hvis du reinstallere systemet.
Husk å kjøre sudo netfilter-persistent reload etter å ha lagt tilbake rules.v4.

---

## 📨 MQTT og Home Assistant

Skriptet kan publisere status og sensorer til MQTT, slik at Home Assistant kan oppdage dem automatisk.  
MQTT er **av** som standard (`MQTT_ENABLED=false`).

### Aktivering

1. **Installer MQTT-klient på Pi**  
   Dette trengs for å sende meldinger (`mosquitto_pub`):

```bash
sudo apt update
sudo apt install mosquitto-clients -y
```

2. **Rediger `nordvpn-gateway.sh`**  
   Finn linjene øverst i skriptet og endre:

```bash
MQTT_ENABLED=true
MQTT_BROKER="192.168.1.100"   # IP til din MQTT-broker (ofte Home Assistant)
MQTT_USER="brukernavn"        # kan stå tom hvis ikke brukt
MQTT_PASS="passord"           # kan stå tom hvis ikke brukt
MQTT_CLIENT_ID="nordvpn_gateway_pi"
HA_DISCOVERY_PREFIX="homeassistant"
```

3. **Restart tjenesten**

```bash
sudo systemctl restart nordvpn-gateway.service
```

### Publiserte emner

Når aktivert, publiseres følgende MQTT-emner (retained):

- `nordvpn/gateway/status` → Tilkoblingsstatus (`VPN OK`, `VPN Frakoblet`, `VPN Tilkoblet`)
- `nordvpn/gateway/last_seen` → Siste tidssjekk (timestamp)
- `nordvpn/gateway/cpu_temp` → CPU-temperatur på Pi

### Home Assistant auto-discovery

Hvis MQTT-integrasjonen i Home Assistant er konfigurert, oppdages sensorene automatisk:

- `sensor.nordvpn_status`
- `sensor.nordvpn_sist_sett`
- `sensor.nordvpn_cpu_temp`

---

## 🙌 Anerkjennelser

Prosjektet er skrevet og vedlikeholdt av @Howard0000. En KI-assistent har hjulpet til med å forenkle forklaringer, rydde i README-en og pusse på skript. Alle forslag er manuelt vurdert før de ble tatt inn, og all konfigurasjon og testing er gjort av meg.

---

## 📝 Lisens

MIT — se LICENSE.
