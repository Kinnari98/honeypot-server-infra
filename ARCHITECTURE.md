# Tekninen arkkitehtuuri – honeypot-server-infra

## Tarkoitus

Tämä projekti rakentaa korkean vuorovaikutuksen (high-interaction) honeypot-palvelimen, joka:

- Näyttää hyökkääjälle aidolta tuotantopalvelimelta
- Kirjaa kaiken toiminnan syscall-tasolla auditd:llä
- Välittää lokit automaattisesti Microsoft Sentineliin
- Ei käytä simuloituja ympäristöjä (ei Cowrieta, ei Dionaeaa)

Palvelin on tarkoituksella **houkutteleva kohde** – se ei torju hyökkäyksiä (ei fail2ban), vaan kerää mahdollisimman paljon dataa hyökkääjien toiminnasta.

---

## Teknologiapino

| Kerros | Teknologia |
|---|---|
| Käyttöjärjestelmä | RHEL (Red Hat Enterprise Linux) |
| Provisionointi | Ansible |
| Palomuuri | firewalld (drop-zone oletuksena) |
| Syscall-lokitus | auditd + audispd-plugins |
| Lokikuljetus | rsyslog → AMA |
| SIEM | Microsoft Sentinel / Log Analytics |
| Tietokanta (lure) | PostgreSQL |

---

## Ansible-roolit

### `common` – peruskovennukset

Ajetaan kaikille palvelimille. Sisältää:

- Pakettipäivitykset ja peruspaketit
- firewalld: drop-zone oletuksena, vain `honeypot_open_ports` sallittu sisään
- iptables: ulospäin sallitaan vain DNS (53), HTTP (80), HTTPS (443)
- SSH: PermitRootLogin no
- auditd: kattavat syscall-säännöt (`audit.rules.j2`)
- audisp-syslog: audit-lokit → syslog-ketju
- Aikavyöhyke: UTC

### `high-interaction` – honeypot-identiteetti

Tekee palvelimesta uskottavan tuotantoympäristön:

- **issue.net** – pre-login varoitusbanneri (näkyy ennen autentikointia)
- **MOTD** – post-login operatiivinen tieto (palvelintyyppi, backup-status, maintenance-ikkuna)
- **system-status.sh** – dynaaminen järjestelmätieto kirjautuessa (uptime, CPU, muisti, levy)
- RHEL:n oletusviestit poistettu (`/etc/motd.d/insights-client`)

Banneristrategia: palvelin esittäytyy PostgreSQL-tietokantapalvelimena tuotantoympäristössä. Backup-tiedot ja vanha maintenance-päivämäärä luovat vaikutelman hoidetusta mutta ei täysin ajantasaisesta palvelimesta.

### `psql` – PostgreSQL

- Asennus ja initialisointi (`postgresql-setup --initdb`)
- Palvelun käynnistys ja autostart
- Kantojen ja käyttäjien konfiguraatio

### `users` – fake-käyttäjät

Luo uskottavan käyttäjärakenteen:

| Käyttäjä | Shell | Ryhmät | Tarkoitus |
|---|---|---|---|
| `psqladmin` | `/bin/bash` | – | PostgreSQL admin-tunnus |
| `psqluser` | `/sbin/nologin` | – | Palvelutili, ei kirjautumista |
| `mimu` | `/bin/bash` | `wheel` | Ylläpitäjä (sudo + kanta) |
| `pela` | `/bin/bash` | `wheel` | Ylläpitäjä (sudo + kanta) |

---

## Lokiketju

```
Palvelin
┌─────────────────────────────────────────┐
│  Hyökkääjän toiminto (komento, yhteys)  │
│              ↓                          │
│  Linux kernel syscall                   │
│              ↓                          │
│  auditd – kirjaa /var/log/audit/        │
│              ↓                          │
│  audisp-syslog (audispd-plugins)        │
│              ↓                          │
│  rsyslog                                │
└─────────────────────────────────────────┘
              ↓
Azure
┌─────────────────────────────────────────┐
│  AMA (Azure Monitor Agent)              │
│  ← asennetaan DCR:n kautta automaatt.  │
│              ↓                          │
│  Log Analytics Workspace                │
│              ↓                          │
│  Microsoft Sentinel                     │
└─────────────────────────────────────────┘
```

AMA:ta ei asenneta Ansiblella – se asennetaan automaattisesti kun Data Collection Rule (DCR) liitetään VM:ään Azure-portaalista tai Terraformilla.

---

## Palomuuristrategia

**Sisäänpäin (inbound):** kaikki estetty oletuksena (firewalld drop-zone). Vain `honeypot_open_ports`-listassa määritellyt portit sallitaan. Pääsy hallintaan hoidetaan Azure NSG:llä.

**Ulospäin (outbound):** rajoitettu iptables-säännöillä:
- DNS (UDP 53) – nimenresoluutio
- HTTP (TCP 80) – pakettirepot
- HTTPS (TCP 443) – Sentinel/AMA + pakettirepot
- Kaikki muu estetty

Tämä estää honepotin käyttämisen hyökkäysalustana edelleen (pivot/lateral movement).

---

## Auditd-säännöt

Säännöt on jaettu kategorioihin (`audit.rules.j2`):

| Kategoria | Tagi Sentinelissä | Mitä valvotaan |
|---|---|---|
| Prosessien suoritus | `process_execution` | Kaikki `execve`-syscallit – jokainen ajettu komento |
| Oikeuksien eskalointi | `priv_escalation` | setuid/setgid, sudo, su, pkexec |
| Käyttäjähallinta | `user_management` | /etc/passwd, /etc/shadow, useradd/del/mod |
| SSH-avaimet | `ssh_key_injection` | /root/.ssh, authorized_keys-muutokset |
| Autentikaatio | `auth_log` | PAM, wtmp, btmp, utmp |
| Verkkokonfiguraatio | `network_config` | /etc/hosts, resolv.conf |
| Verkkoaktiviteetti | `network_activity` | socket, connect, accept, bind syscallit |
| Kernel-moduulit | `kernel_modules` | insmod, rmmod, modprobe – rootkit-havaitseminen |
| Persistenssi | `persistence_cron` | cron, systemd timers |
| LD_PRELOAD | `ld_preload_rootkit` | kirjastohyökkäykset |
| Binääritamperointi | `binary_tampering` | /bin, /sbin, /usr/bin muutokset |
| Lokien tuhoaminen | `log_tampering` | /var/log muutokset |
| Tiedosto-oikeudet | `file_permissions` | chmod, chown syscallit |
| Tiedostojen poisto | `file_deletion` | unlink, rename syscallit |

Säännöt lukitaan `-e 2`:lla – hyökkääjä ei voi poistaa auditia käytöstä ilman rebootia.

---

## Turvallisuushuomiot

- `inventory/group_vars/all.yml` ja `inventory/host_vars/*.yml` ovat gitignored – eivät sisällä arkaluontoisia tietoja repossa
- Esimerkitiedostot (`.example`) ovat repossa pohjaksi
- fail2ban on **tarkoituksella poistettu** – honeypotilla ei blokata hyökkääjiä, enemmän yrityksiä = enemmän dataa
- Pääsynhallinta hoidetaan Azure NSG:llä, ei palvelimella
