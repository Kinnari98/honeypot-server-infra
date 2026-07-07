# honeypot-server-infra

> **WORK IN PROGRESS**
> Tämä projekti on aktiivisessa kehitysvaiheessa. Konfiguraatiot, roolit ja rakenne voivat muuttua merkittävästi. Älä käytä tuotannossa ilman omaa arviointia.

Ansible-pohjainen infrastruktuuri honeypot-palvelimelle. Palvelin on oikea RHEL-ympäristö (ei simulaatio) joka esiintyy tuotannon PostgreSQL-tietokantapalvelimena ja lokittaa kaiken toiminnan Microsoft Sentineliin AMA:n kautta.

Tekninen kuvaus: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Vaatimukset (lokaalikone)

```bash
pip install ansible
ansible --version   # vähintään 2.14
```

PostgreSQL-roolin tehtävät käyttävät `community.postgresql`-kokoelmaa. Asenna se:

```bash
ansible-galaxy collection install community.postgresql
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

# Tarkista firewalld-säännöt
ansible machines -m shell -a "firewall-cmd --list-all" --become

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

---

## Lokiketju

```
palvelin                              Azure
─────────────────────────────────────────────────────────
auditd (syscall-lokit)
  └─→ audisp-syslog (audispd-plugins)
        └─→ rsyslog
              └─→ AMA (Azure Monitor Agent)   ← asennetaan DCR:n kautta
                    └─→ Log Analytics Workspace
                          └─→ Microsoft Sentinel
```

AMA asennetaan automaattisesti kun DCR (Data Collection Rule) liitetään VM:ään Azure-portaalista. Syslog-keräys konfiguroidaan DCR:ssä.

---

## Hakemistorakenne

```
.
├── ansible.cfg                          # roles_path, inventory, host_key_checking
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
│   ├── harden.yml                       # WIP: defender-rooli
│   └── update.yml                       # WIP: pakettipäivitykset / huoltokatkot
└── roles/
    ├── common/                          # Peruskovennukset: paketit, firewalld, SSH, auditd
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       └── audit.rules.j2
    ├── high-interaction/                # Honeypot-identiteetti ja autenttisuus
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       ├── motd.j2
    │       ├── issue.net.j2
    │       └── system-status.sh.j2
    ├── users/                           # Houkutin-käyttäjät (psqladmin, psqluser, mimu, pela)
    │   └── tasks/main.yml
    ├── psql/                            # PostgreSQL-asennus, sales-kanta, feikkidata
    │   ├── tasks/main.yml
    │   └── handlers/main.yml
    ├── crontab/                         # pg_dump-varmuuskopiointi (cron)
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       └── backup_postgresql.sh
    ├── monitoring/                      # Sysmon for Linux – telemetria syslogiin
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/
    │       └── sysmon-config.xml.j2
    └── admins/                          # Oikeat ylläpitäjät – ansible-vaultilla salattu
        └── tasks/main.yml
```
