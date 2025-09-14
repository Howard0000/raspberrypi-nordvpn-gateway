# Feilsøking og Manuell Re-autentisering av NordVPN

Denne guiden beskriver en "hard reset"-prosedyre for NordVPN på din Raspberry Pi Gateway.  
Bruk denne når VPN-en er nede og en enkel restart av tjenesten ikke fungerer, eller du mistenker at du har blitt logget ut og trenger å re-autentisere.

## Symptomer
Guiden er aktuell dersom:
- VPN-status er **"Disconnected"** eller **"Connecting..."** over lengre tid.
- Loggen viser feil som `VPN-grensesnittet 'nordlynx' er nede`.
- Manuelle `nordvpn connect`-kommandoer feiler med `You are not logged in.`

---

## Forutsetninger
- Du må ha tilgang til å koble deg til din Raspberry Pi via **SSH**.
- Du trenger en annen datamaskin (PC/Mac) med en nettleser på samme nettverk.

---

## Steg 1: Koble til Raspberry Pi
Koble til din Raspberry Pi med din foretrukne SSH-klient:
```bash
ssh pi@<din-pi-ip-adresse>
```

---

## Steg 2: Oppdater NordVPN-klienten
Det første og viktigste steget er å sørge for at du kjører den nyeste versjonen av NordVPN-programvaren.  
Dette løser de fleste kompatibilitets- og feilproblemer.

```bash
# Oppdater systemets pakkelister
sudo apt update

# Installer kun oppgraderingen for NordVPN-pakken
sudo apt install --only-upgrade nordvpn
```

---

## Steg 3: Manuell Innlogging (Callback-metoden)
Dette er den mest kritiske delen, og krever samhandling mellom Pi-en og PC-en din.

### 3.1 På Raspberry Pi: Start innloggingen
Kjør innloggingskommandoen for å generere en unik URL:
```bash
nordvpn login
```
Terminalen vil gi deg en lang lenke som starter med `https://api.nordvpn.com/...`.  
Kopier hele denne lenken.

---

### 3.2 På din PC/Mac: Logg inn i nettleseren
1. Åpne en nettleser på din PC/Mac.  
2. Lim inn lenken fra terminalen og trykk **Enter**.  
3. Logg inn med ditt NordVPN-brukernavn og passord.

---

### 3.3 På din PC/Mac: Hent Callback-URLen
Etter vellykket innlogging vil du se en side med teksten **"Great - you're in!"** og en **"Continue"**-knapp.

- **Ikke** klikk på knappen.  
- Høyreklikk på **"Continue"** og velg **"Kopier lenkeadresse"**.  

Du har nå kopiert den hemmelige `nordvpn://login?token=...`-lenken til utklippstavlen din.

---

### 3.4 På Raspberry Pi: Fullfør innloggingen
Gå tilbake til terminalen på din Raspberry Pi og kjør følgende kommando (lim inn lenken i anførselstegn):

```bash
nordvpn login --callback "LIM-INN-DEN-KOPIERTE-nordvpn://-LENKEN-HER"
```

Trykk **Enter**.  
Du skal nå få en velkomstmelding som bekrefter at innloggingen var vellykket.

---

## Steg 4: Verifiser Innlogging
For å være 100 % sikker på at du er logget inn, kjør:

```bash
nordvpn account
```

Eksempel på output:
```
Account Information:
Email Address: din.epost@gmail.com
VPN Service: Active (Expires on ...)
```

---

## Steg 5: Gjenopprett Normal Drift
Når programvaren er oppdatert og du er logget inn, restart den tilpassede gateway-tjenesten din:

```bash
sudo systemctl restart nordvpn-gateway.service
```

Vent i 30–60 sekunder og sjekk status:

```bash
# Sjekk tjenestens logg i sanntid
journalctl -u nordvpn-gateway -f

# Sjekk den generelle NordVPN-statusen
nordvpn status
```

Dersom `nordvpn status` viser:
```
Status: Connected
```
er prosessen fullført, og systemet er tilbake i normal drift.
