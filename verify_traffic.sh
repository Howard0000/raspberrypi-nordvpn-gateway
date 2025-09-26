#!/bin/bash
# ==============================================================================
# verify_traffic.sh — Verifiser selektiv ruting via NordVPN (nordlynx)
# ==============================================================================
#  1) Viser relevante iptables-regler (mangle/FW-mark) for PROTO/PORT
#  2) Viser ip-rule og rutetabell for MARK 0x1
#  3) Lytter på VPN-grensesnittet med tcpdump for valgt PROTO/PORT
# ==============================================================================

set -euo pipefail

# --- Konfigurasjon (TILPASS) --------------------------------------------------
PORT=8080          # Porten du har merket i MANGLE for å gå via VPN
IFACE="nordlynx"   # VPN-grensesnittet (NordVPN NordLynx)
PROTO="tcp"        # "tcp" eller "udp"
DURATION=20        # Hvor lenge tcpdump skal lytte (sekunder)

# --- Interne innstillinger -----------------------------------------------------
MARK_HEX="0x1"     # vi bruker MARK 1 i oppskriftene
RT_TABLE_CANDIDATES=("nordvpntabell" "nordvpntable" "vpn_table")

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Dette skriptet må kjøres som root. Prøv: sudo $0" >&2
    exit 1
  fi
}

check_deps() {
  local missing=()
  # Viktig: sjekk 'ip' kun én gang (ikke 'rule'/'route' som egne binærfiler)
  for bin in ip iptables tcpdump timeout grep awk sed; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if (( ${#missing[@]} )); then
    echo "Mangler verktøy: ${missing[*]}" >&2
    echo "Installer f.eks.: sudo apt update && sudo apt install tcpdump -y" >&2
    exit 1
  fi
}

detect_rt_table() {
  for name in "${RT_TABLE_CANDIDATES[@]}"; do
    if grep -Eq "[[:space:]]${name}\$" /etc/iproute2/rt_tables 2>/dev/null; then
      echo "$name"; return 0
    fi
  done
  echo "${RT_TABLE_CANDIDATES[0]}"
}

print_header() {
  echo "=============================================================================="
  echo " Verifisering av selektiv ruting via VPN"
  echo "  - IFACE : $IFACE"
  echo "  - PROTO : $PROTO"
  echo "  - PORT  : $PORT"
  echo "  - LYTT  : ${DURATION}s med tcpdump"
  echo "=============================================================================="
}

show_rules() {
  echo
  echo "[1/3] Søker etter MANGLE-regler som merker ${PROTO^^} trafikk til port $PORT med MARK $MARK_HEX ..."
  # Bruk -e slik at '--dport ...' ikke tolkes som grep-flagg
  iptables -t mangle -S PREROUTING \
    | grep -iE "\-p[[:space:]]+$PROTO" \
    | grep -iE -e "--dport[[:space:]]+$PORT" \
    | grep -iE "MARK[[:space:]]+--set-mark[[:space:]]+(1|$MARK_HEX)" \
    || echo "⚠️  Fant ingen matchende mangle-regel for $PROTO/$PORT som setter MARK 1." >&2

  echo
  echo "[2/3] Viser ip-rule som sender MARK $MARK_HEX til egen rutetabell ..."
  ip rule show | grep -i "fwmark[[:space:]]\+0x1" || echo "⚠️  Fant ingen 'ip rule' for fwmark 0x1."

  local rt_table
  rt_table="$(detect_rt_table)"
  echo
  echo "[2b/3] Viser rutingtabell '${rt_table}' ..."
  ip route show table "$rt_table" || echo "⚠️  Fant ingen ruter i tabellen '$rt_table'."
}

run_tcpdump() {
  echo
  echo "[3/3] Starter tcpdump på $IFACE for $PROTO port $PORT i ${DURATION}s ..."
  echo "     (Generer trafikk fra en klient som er merket i MANGLE-reglene nå.)"
  echo

  local filter
  if [[ "$PROTO" == "tcp" ]]; then
    filter="tcp port $PORT"
  elif [[ "$PROTO" == "udp" ]]; then
    filter="udp port $PORT"
  else
    echo "Ukjent PROTO: $PROTO (må være 'tcp' eller 'udp')" >&2
    exit 1
  fi

  timeout "${DURATION}" tcpdump -ni "$IFACE" -vv "$filter" || true

  echo
  echo "Tips:"
  echo "  - Hvis du ikke så pakker: dobbeltsjekk at klient-IP er merket i MANGLE,"
  echo "    at du faktisk genererte $PROTO-trafikk til port $PORT, og at $IFACE er riktig."
}

# --- Kjør ----------------------------------------------------------------------
need_root
check_deps
print_header
show_rules
run_tcpdump

echo
echo "Ferdig. Hvis du så pakker på $IFACE for $PROTO/$PORT, fungerer selektiv ruting via VPN."
