# honeypot-server-infra

> **WORK IN PROGRESS**
> Tämä projekti on aktiivisessa kehitysvaiheessa. Konfiguraatiot, roolit ja rakenne voivat muuttua merkittävästi. Älä käytä tuotannossa ilman omaa arviointia.

Ansible-pohjainen infrastruktuuri honeypot-palvelimelle. Palvelin on oikea RHEL-ympäristö (ei simulaatio) joka esiintyy tuotannon PostgreSQL-tietokantapalvelimena ja lokittaa kaiken toiminnan Microsoft Sentineliin AMA:n kautta.

Tekninen kuvaus: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Nykytila ja rajoitukset

Lue tämä ennen kuin oletat palvelimen keräävän hyökkäysdataa.

**Palvelimeen ei tällä hetkellä pääse sisään.** `users`-rooli luo houkutintunnukset
(`psqladmin`, `psqluser`, `mimu`, `pela`) ilman salasanaa, jolloin tilit ovat
lukittuja, eikä `PasswordAuthentication`-asetusta kytketä päälle missään roolissa.
Ainoa avoin portti on 22. Palvelin on siis **lokitusalusta valmiina**, ei vielä auki
hyökkääjille: auditd, Sysmon ja lokiketju Sentineliin toimivat, mutta niillä ei ole
vielä mitään kirjattavaa hyökkääjän toiminnasta.

Tämä on tietoinen järjestys. Sisäänpääsyn avaaminen (`PasswordAuthentication yes` +
heikot salasanat houkutintunnuksille) tehdään omana muutoksenaan vasta kun
outbound-lukitus ja lokiketju on **todennettu palvelimella toimiviksi** – muuten
internetissä olisi avoin RHEL-palvelin ilman toimivaa pivot-estoa.

Muuta keskeneräistä:

| Asia | Tila |
|------|------|
| **AMA / DCR** | **Ei asennettu.** Lokiketju päättyy tällä hetkellä palvelimen rsyslogiin – mitään ei siirry Log Analyticsiin eikä Sentineliin. Kaikki telemetria (auditd, Sysmon, PostgreSQL) on siis tallessa vain `/var/log/`-hakemistossa, jonne hyökkääjällä olisi root-oikeuksilla pääsy. Tämän korjaaminen on koko projektin arvon kannalta tärkein yksittäinen puuttuva pala. |
| **Outbound-egress** | **Auki väliaikaisesti.** NSG:hen on lisätty Azuren endpointeille Allow-säännöt prioriteetilla alle 4010, jotta RHUI (ja siten `dnf`) toimii. Tämä on tietoinen väliaikainen tila: koneessa ei ole vielä ketään, joten riskiä ei ole. **Egress suljetaan ennen honeypotin avaamista** – ks. avaamisen tarkistuslista alla. |
| **Sysmon** (`monitoring`-rooli) | **Pois käytöstä** (`monitoring_enabled: false`). NSG-sääntö `DenyInternetOut` estää pääsyn `packages.microsoft.com`iin, joten pakettia ei voi asentaa. `common` siivoaa tavoittamattoman repon pois – muuten se kaataa `dnf update` -taskin. Prosessi- ja verkkotelemetria tulee toistaiseksi pelkältä auditd:ltä. |
| `playbooks/harden.yml` / `defender`-rooli | `roles/defender/tasks/main.yml` on tyhjä – playbook ei tee mitään |
| PostgreSQL-portti 5432 | Ei avattu ulos; kanta on vain paikallinen houkutin, jonka hyökkääjä löytää vasta shellin saatuaan |
| `.env` / `.env.example` | **Vanhentuneet.** Yksikään rooli ei lue niitä – kaikki konfiguraatio tulee `group_vars`- ja `host_vars`-tiedostoista. Älä täytä `.env`:ää ja ihmettele miksi mikään ei muutu. |
| `azure_*`- ja `log_analytics_*`-muuttujat | Dokumentaatiota ympäristöstä; yksikään rooli ei lue niitä (Azure-provisiointi tehdään portaalista, AMA tulee DCR:n kautta) |

### Honeypotin avaamisen tarkistuslista

Nämä on tehtävä kaikki, ja tässä järjestyksessä. Yksikin väliin jäänyt kohta
tekee joko honeypotista hyödyttömän (ei dataa) tai vaarallisen (ei kontrollia).

**Ennen avaamista – varmista että lokitus toimii:**

1. AMA asennettu ja DCR liitetty; `Syslog`-taulussa näkyy dataa `local6`- ja `local0`-facilityistä
2. Perustason ingestiovolyymi mitattu (`Usage | where DataType == "Syslog"`), jotta kustannusmuutos on myöhemmin tulkittavissa
3. Levytila ja logrotate tarkistettu – täysi levy pysäyttää lokituksen hiljaisesti

**Sulje ulospääsy:**

4. NSG:n Azure-endpoint-poikkeukset poistetaan tai siirretään prioriteetiltaan `DenyInternetOut`-säännön (4010) jälkeen. `AllowAzureMonitorOut` (4000) **jää** – ilman sitä telemetria ei kulje.
5. Varmista sulkeminen: `curl -m 10 https://www.microsoft.com` palvelimelta pitää aikakatkaista, mutta Sentineliin on yhä tultava dataa
6. Huomaa että tämän jälkeen `dnf` ei enää toimi. Päätä samalla päivitysstrategia: huoltoikkuna, pysyvä RHUI-poikkeus, vai tietoinen päättämättömyys.

**Avaa sisäänpääsy:**

7. Houkutintunnuksille (`mimu`, `pela`, `psqladmin`) asetetaan heikot salasanat vaultista
8. `PasswordAuthentication yes` sshd:hen
9. NSG:ssä portti 22 avataan internetiin – nyt se on rajattu kahteen ylläpitäjän IP:hen, joten pelkkä sshd-muutos ei riitä
10. Ylläpitäjien oma pääsy varmistetaan ennen tätä: WireGuard toimintaan, tai admin-tunnukset rajataan erikseen

**Avaamisen jälkeen:**

11. Seuraa ingestiovolyymia ensimmäiset vuorokaudet – auditd `execve` + `connect` internetiin altistetulla koneella on merkittävä kustannuserä
12. Varmista ettei kone lähetä liikennettä ulos: NSG flow logit tai Sentinel-hälytys lähtevistä yhteyksistä

---

## Vaatimukset (lokaalikone)

```bash
pip install ansible
ansible --version   # vähintään 2.14
```

Roolit käyttävät kahta kokoelmaa. Asenna molemmat:

```bash
ansible-galaxy collection install community.postgresql   # psql-rooli
ansible-galaxy collection install community.general      # common-rooli (ini_file)
```

> Kohdepalvelimelle tarvittava `python3-psycopg2` asennetaan automaattisesti `common`-roolissa – sitä ei tarvitse asentaa lokaalisti.

---

## Konfiguraatio

### 1. Palvelimen yhteystiedot

Kopioi esimerkki ja täytä arvot:

```bash
cp inventory/host_vars/server-name.yml.example inventory/host_vars/<hostname>.yml
```

Tiedostoon täytetään `ansible_host` (palvelimen IP), `ansible_user` ja `ansible_ssh_private_key_file`.

Lisää hostin alias `inventory/hosts.yml`:iin:

```yaml
all:
  children:
    machines:
      hosts:
        hannibal:
```

### 2. Globaalit muuttujat (`group_vars/all/`)

Globaali konfiguraatio on jaettu kahtia salaisuuksien suojaamiseksi:

| Tiedosto | Sisältö | Versionhallinnassa |
|----------|---------|--------------------|
| `vars.yml` | Ei-arka konfiguraatio (portit, Azure-alue, VM-koko) | Selkokielisenä |
| `vault.yml` | Salaisuudet + arat arvot (salasanat, workspace key, hostname, subscription id) | **Ansible-vaultilla salattuna** |

`vars.yml` viittaa salaisuuksiin `vault_`-etuliitteellä (esim. `psqladmin_password: "{{ vault_psqladmin_password }}"`), joten näet mitkä arvot ovat arkoja ilman että ne ovat selkokielisinä repossa.

Kopioi mallit ja täytä arvot:

```bash
cp inventory/group_vars/all/vars.yml.example  inventory/group_vars/all/vars.yml
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
```

Täytä salaisuudet `vault.yml`:ään ja **salaa se ennen committia**:

```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

> Salattuna `vault.yml` on turvallista pushata julkiseenkin repoon – tiimin jäsenet tarvitsevat vain jaetun vault-salasanan. Tarkista aina ennen committia että ekalla rivillä lukee `$ANSIBLE_VAULT`, ei `---`.

`host_vars/<hostname>.yml` on gitignored (palvelinkohtaiset yhteystiedot). `vars.yml` ja `vault.yml` sen sijaan **committoidaan** – näin tiimi jakaa saman konfiguraation gitin kautta. `vault.yml` menee repoon **salattuna**.

### 2b. Vault-salasana

Playbookit lataavat `vault.yml`:n, joten jokainen ajo tarvitsee vault-salasanan. Valitse jompikumpi:

```bash
# Vaihtoehto A – salasanatiedosto (ei tarvitse kirjoittaa joka ajolla)
echo "vault-salasanasi" > .vault_pass && chmod 600 .vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE=.vault_pass    # esim. .bashrc:hen

# Vaihtoehto B – kysy joka ajolla
ansible-playbook playbooks/deploy.yml --ask-vault-pass
```

`.vault_pass` on gitignored – se ei mene repoon. Jaa vault-salasana tiimin kesken turvallisesti (esim. salasananhallinta), ei Slackissa/sähköpostissa.

### 2c. Pre-commit-hook (estää vahingossa vuotavat salaisuudet)

Repossa on git-hook joka **estää salaamattoman `vault.yml`:n committaamisen**. Se on versionhallinnassa (`.githooks/`), mutta git ei ota sitä käyttöön automaattisesti – aktivoi kerran:

```bash
git config core.hooksPath .githooks
```

Tämän jälkeen jokainen `git commit` tarkistaa staged vault-tiedostot, ja jos jokin ei ala `$ANSIBLE_VAULT`-otsikolla, commit estyy. Suositellaan kaikille tiimin jäsenille.

### 2d. Vault-tiedostojen lukeminen ja muokkaus

Salattu tiedosto näkyy editorissa (VSCode ym.) pelkkänä salattuna möykkynä – se on normaalia. Sisältöön pääsee käsiksi `ansible-vault`-komennoilla (tarvitset vault-salasanan; jos `.vault_pass` on käytössä, salasanaa ei kysytä).

| Komento | Mitä tekee | Turvallinen gitille |
|---------|-----------|---------------------|
| `ansible-vault view <tiedosto>` | Näyttää sisällön – **tiedosto pysyy salattuna levyllä** | ✅ kyllä |
| `ansible-vault edit <tiedosto>` | Avaa editoriin, **salaa uudelleen** tallennettaessa | ✅ kyllä |
| `ansible-vault decrypt <tiedosto>` | **Purkaa pysyvästi** – jättää selkokielisen tiedoston levylle | ⚠️ **EI** |

```bash
# Lue salaisuudet (tiedosto ei muutu):
ansible-vault view inventory/group_vars/all/vault.yml

# Muokkaa salaisuuksia (salautuu automaattisesti tallennuksessa):
ansible-vault edit inventory/group_vars/all/vault.yml
```

> **Älä käytä `ansible-vault decrypt`** committoitaviin tiedostoihin – se jättää salaisuudet selkokielisenä levylle, ja seuraava commit vuotaisi ne. Käytä aina `view` (luku) tai `edit` (muokkaus). Pre-commit-hook (kohta 2c) toimii viimeisenä turvaverkkona, mutta älä luota pelkästään siihen.

Vaihtaaksesi salauksen salasanan (esim. jos vault-salasana vuotaa):

```bash
ansible-vault rekey inventory/group_vars/all/vault.yml
```

### 3. Admin-käyttäjät (ansible-vault)

Oikeat ylläpitäjät luodaan `admins`-roolissa, jonka task-tiedosto on **ansible-vaultilla salattu** ja sellaisena versionhallinnassa. Tiedosto sisältää ylläpitäjien Linux-tunnukset ja SSH-julkiavaimet.

Vaultatun tiedoston katselu / muokkaus:

```bash
ansible-vault view roles/admins/tasks/main.yml
ansible-vault edit roles/admins/tasks/main.yml
```

> **Forkkaajille:** repon `admins`-rooli sisältää tämän projektin ylläpitäjät. Tee oma vaultattu versio omilla tunnuksillasi ja avaimillasi – ja vaihda vault-salasana.

---

## Deploy

### Pääpalvelin (kaikki roolit paitsi admins)

```bash
ansible-playbook playbooks/deploy.yml
```

Ajaa järjestyksessä: `common` → `high-interaction` → `users` → `psql` → `crontab` → `monitoring`.

> Deploy lataa `group_vars/all/vault.yml`:n, joten se tarvitsee vault-salasanan (ks. kohta 2b). Jos et käytä `.vault_pass`-tiedostoa, lisää `--ask-vault-pass`.

#### Auditd-säännöt eivät päivity ilman rebootia

`audit.rules.j2` päättyy `-e 2`:een, joka lukitsee auditd-säännöt muuttumattomiksi
seuraavaan käynnistykseen asti. Hyökkääjä ei siis saa auditd:tä pois päältä – mutta
**lukitus koskee myös deployta**: jos muutat audit-sääntöjä, uusi tiedosto kirjoittuu
palvelimelle mutta säännöt astuvat voimaan vasta rebootissa. Playbook varoittaa tästä
ajon lopussa (`Warn that audit rules require a reboot`), eikä `augenrules --load`
-epäonnistumista lasketa virheeksi.

Kehityksessä, kun iteroit sääntöjä, ohita lukitus:

```bash
ansible-playbook playbooks/deploy.yml -e audit_immutable=false
```

Muista ajaa lopuksi ilman lippua ja bootata palvelin, jotta tuotannon lukitus palaa.

### Admin-käyttäjät (vaultattu, ajetaan erikseen)

```bash
ansible-playbook playbooks/admins.yml --ask-vault-pass
```

---

## Ansible-komennot

### Yhteyden testaus

```bash
ansible machines -m ping
```

### Syntaksitarkistus (ei ota yhteyttä palvelimeen)

```bash
ansible-playbook playbooks/deploy.yml --syntax-check
```

### Dry run – näyttää mitä tapahtuisi ilman muutoksia

```bash
ansible-playbook playbooks/deploy.yml --check --diff
```

- `--check` = simuloi, ei kirjoita palvelimelle
- `--diff` = näyttää tiedostomuutokset rivi riviltä

### Aja vain tietty rooli (tagilla)

```bash
ansible-playbook playbooks/deploy.yml --tags common
ansible-playbook playbooks/deploy.yml --tags high-interaction
ansible-playbook playbooks/deploy.yml --skip-tags psql
```

### Aja yksittäinen task nimen perusteella

```bash
ansible-playbook playbooks/deploy.yml --start-at-task "Configure auditd to monitor critical files"
```

### Verbose-tila (debuggaus)

```bash
# -v  = tehtävien tulokset
# -vv = myös moduuliargumentit
# -vvv = myös SSH-yhteyden debug
ansible-playbook playbooks/deploy.yml -vv
```

### Listaa kaikki taskit ilman ajoa

```bash
ansible-playbook playbooks/deploy.yml --list-tasks
```

### Aja vain yhdelle hostille

```bash
ansible-playbook playbooks/deploy.yml --limit hannibal
```

### Ad-hoc komennot suoraan palvelimelle

```bash
# Testaa yhteys
ansible machines -m ping

# Tarkista auditd:n tila
ansible machines -m shell -a "systemctl status auditd" --become

# Katso audit-säännöt
ansible machines -m shell -a "auditctl -l" --become

# Tarkista firewalld-säännöt (inbound)
ansible machines -m shell -a "firewall-cmd --list-all" --become

# Tarkista outbound-policy (pitää säilyä myös rebootin yli)
ansible machines -m shell -a "firewall-cmd --info-policy=egress" --become

# Tarkista käynnissä olevat palvelut
ansible machines -m shell -a "systemctl list-units --state=failed" --become

# Tarkista PostgreSQL:n tila
ansible machines -m shell -a "systemctl status postgresql" --become
```

---

## Käyttäjät

| Tunnus       | Shell          | Sudo (wheel) | Tarkoitus                                        |
|--------------|----------------|--------------|--------------------------------------------------|
| `psqladmin`  | `/bin/bash`    | ei           | DB-admin – pääsee kantaan, ei palvelimen säätöön |
| `psqluser`   | `/sbin/nologin`| ei           | DB-sovellustunnus                                |
| `mimu`       | `/bin/bash`    | kyllä        | Feikki "henkilö"-ylläpitäjä                      |
| `pela`       | `/bin/bash`    | kyllä        | Feikki "henkilö"-ylläpitäjä                      |

Nämä houkutintunnukset luodaan `users`-roolissa (deploy.yml). Oikeat ylläpitäjät luodaan erikseen vaultatussa `admins`-roolissa (admins.yml), eikä niitä dokumentoida tähän.

> Huom: tunnuksille ei aseteta salasanaa, joten ne ovat lukittuja eikä niillä voi kirjautua sisään. Ks. [Nykytila ja rajoitukset](#nykytila-ja-rajoitukset).

---

## Varmuuskopiointi

`crontab`-rooli asentaa `/usr/local/bin/backup_postgresql.sh` -skriptin ja ajastaa sen
cronilla **päivittäin klo 02:00** postgres-käyttäjänä. Skripti dumppaa `sales`-kannan
tiedostoon `/var/backups/sales-db/sales_<pvm>.sql`, poistaa `backup_retention_days`
(oletus 14) vuorokautta vanhemmat dumpit ja kirjaa ajon syslogiin tagilla `pg-backup`.

Varmuuskopiolla on kaksoisrooli: se on oikea backup (MOTD lupaa backupit, joten
niiden on myös oltava olemassa) ja samalla houkutin – selkokielinen SQL-dump
"tuotantokannasta" on uskottava palkinto hyökkääjälle. Siksi hakemiston oikeudet
ovat tarkoituksella `0755`.

Muuttujat: `roles/crontab/defaults/main.yml`. Aja käsin testiksi:

```bash
ansible machines -m shell -a "/usr/local/bin/backup_postgresql.sh && ls -l /var/backups/sales-db" --become
```

> MOTD:n "Backup status" -päivämäärä on erillinen muuttuja
> (`roles/high-interaction/defaults/main.yml` → `lure_last_backup`) eikä päivity
> itsestään. Pidä se ajan tasalla, muuten houkuttimen tarina rakoilee.

---

## Lokiketju

```
palvelin                                        Azure
──────────────────────────────────────────────────────────────────
auditd (syscall-lokit)
  └─→ audisp-syslog (audispd-plugins) ─┐
                                       │
Sysmon for Linux (prosessit, verkko) ──┤
                                       ├─→ rsyslog
PostgreSQL (log_destination=syslog) ───┘      └─→ AMA   ← DCR asentaa
  facility local0                                    └─→ Log Analytics
                                                          └─→ Sentinel
```

AMA asennetaan automaattisesti kun DCR (Data Collection Rule) liitetään VM:ään Azure-portaalista. Syslog-keräys konfiguroidaan DCR:ssä.

### Mitä DCR:n on kerättävä

Facilityt on jaettu tarkoituksella, jotta auditd-volyymia voi säätää erikseen
koskematta halpoihin ja arvokkaisiin lähteisiin:

| Facility | Lähde | Taso |
|---|---|---|
| `local6` | auditd (`roles/common/defaults/main.yml` → `audit_syslog_facility`) | LOG_DEBUG |
| `local0` | PostgreSQL (`roles/psql/defaults/main.yml`) | LOG_DEBUG |
| `authpriv` | sshd – kirjautumiset, epäonnistuneet salasanat | LOG_DEBUG |
| `auth` | su, PAM | LOG_DEBUG |
| `cron` | ajastetut tehtävät – persistenssin havaitseminen | LOG_DEBUG |
| `daemon` | järjestelmäpalvelut | LOG_DEBUG |
| `kern` | moduulien lataus, OOM, netfilter | LOG_INFO |
| `syslog` | rsyslogin omat viestit – lokien manipulointi | LOG_INFO |

> **Valitse taso Info tai Debug, älä Warning.** Tämä on se virhe joka tekee tyhjän
> `Syslog`-taulun. Audisp-syslog lähettää kaikki audit-tapahtumat prioriteetilla
> `LOG_INFO` – myös onnistuneen root-eskalaation ja SSH-avaimen istutuksen.
> Sama pätee `authpriv`:iin: sshd:n "Failed password" ja "Accepted publickey" ovat
> molemmat Info-tasoa. Hyökkäysindikaattorit eivät ole varoituksia, vaan normaalia
> lokia väärässä kontekstissa.

Sysmonin facility ei ole tiedossa – tarkista se palvelimelta ennen DCR:n luontia:
`grep -i sysmon /var/log/messages | head -3`

DCR on Azuren puolen konfiguraatio; Ansible ei hallitse sitä.

Auditd-tapahtumat päätyvät `Syslog`-tauluun, ja sääntöjen `-k`-tagi näkyy
`SyslogMessage`-kentässä muodossa `key="<tagi>"`. Esimerkkikyselyt: [kql.txt](kql.txt).

---

## Hakemistorakenne

```
.
├── ansible.cfg                          # roles_path, inventory, host_key_checking
├── ToDo.md                              # Työjono (gitignored – vain paikallinen)
├── kql.txt                              # Sentinel-kyselyluonnokset
├── .env / .env.example                  # VANHENTUNUT – ei yksikään rooli lue näitä
├── .githooks/pre-commit                 # Estää salaamattoman vault.yml:n commitin
├── inventory/
│   ├── hosts.yml                        # Palvelinaliakset (ei yhteystietoja)
│   ├── group_vars/
│   │   └── all/
│   │       ├── vars.yml                 # Ei-arka konfiguraatio (committoitu)
│   │       ├── vars.yml.example         # Pohja vars.yml:lle
│   │       ├── vault.yml                # Salaisuudet (committoitu SALATTUNA)
│   │       └── vault.yml.example        # Pohja vault.yml:lle
│   └── host_vars/
│       ├── hannibal.yml                 # Hannibalin yhteystiedot (gitignored)
│       └── server-name.yml.example      # Pohja host_vars-tiedostolle
├── playbooks/
│   ├── deploy.yml                       # Pääplaybook (common, high-interaction, users, psql, crontab, monitoring)
│   ├── admins.yml                       # Oikeat ylläpitäjät (vaultattu admins-rooli)
│   └── harden.yml                       # KESKENERÄINEN: defender-rooli on tyhjä
└── roles/
    ├── common/                          # Peruskovennukset: paketit, firewalld, SSH, auditd
    │   ├── defaults/main.yml            # honeypot_egress_allow, audit_immutable
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       ├── audit.rules.j2
    │       └── egress-policy.xml.j2     # firewalld policy: outbound-suodatus
    ├── high-interaction/                # Honeypot-identiteetti ja autenttisuus
    │   ├── defaults/main.yml            # MOTD:n huolto- ja backup-päivämäärät
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       ├── motd.j2
    │       ├── issue.net.j2
    │       └── system-status.sh.j2
    ├── users/                           # Houkutin-käyttäjät (psqladmin, psqluser, mimu, pela)
    │   └── tasks/main.yml
    ├── psql/                            # PostgreSQL-asennus, sales-kanta, feikkidata
    │   ├── defaults/main.yml            # pg_hba-säännöt + lokitusasetukset
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       └── pg_hba.conf.j2
    ├── crontab/                         # pg_dump-varmuuskopiointi (cron)
    │   ├── defaults/main.yml            # backup_dir, retention
    │   ├── tasks/main.yml
    │   └── templates/
    │       └── backup_postgresql.sh
    ├── monitoring/                      # Sysmon for Linux – telemetria syslogiin
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       └── sysmon-config.xml.j2
    ├── defender/                        # KESKENERÄINEN – tasks/main.yml on tyhjä
    │   └── tasks/main.yml
    └── admins/                          # Oikeat ylläpitäjät – ansible-vaultilla salattu
        └── tasks/main.yml
```
