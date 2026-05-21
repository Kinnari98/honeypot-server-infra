# honeypot-server-infra

> **WORK IN PROGRESS**
> Tämä projekti on aktiivisessa kehitysvaiheessa. Konfiguraatiot, roolit ja rakenne voivat muuttua merkittävästi. Älä käytä tuotannossa ilman omaa arviointia.

Ansible-pohjainen infrastruktuuri honeypot-palvelimelle. Palvelin on oikea RHEL-ympäristö (ei simulaatio) joka lokittaa kaiken toiminnan Azure Sentineliin AMA:n kautta.

Tekninen kuvaus: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Vaatimukset (lokaalikone)

```bash
pip install ansible
ansible --version   # vähintään 2.14
```

---

## Konfiguraatio

### 1. Palvelimen yhteystiedot

Kopioi esimerkki ja täytä arvot:

```bash
cp inventory/host_vars/napoleon.yml.example inventory/host_vars/<hostname>.yml
```

Lisää hostin alias `inventory/hosts.yml`:iin:

```yaml
all:
  children:
    machines:
      hosts:
        hannibal:
```

### 2. Globaalit muuttujat

```bash
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
```

Täytä `all.yml`:ään vähintään `lure_hostname` ja `honeypot_open_ports`. Azure- ja Sentinel-muuttujat tarvitaan lokikeräystä varten.

Molemmat tiedostot ovat gitignored – ne eivät mene repoon.

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

### Deploy

```bash
ansible-playbook playbooks/deploy.yml
```

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
│   │   ├── all.yml                      # Globaalit muuttujat (gitignored)
│   │   └── all.yml.example              # Pohja all.yml:lle
│   └── host_vars/
│       ├── hannibal.yml                 # Hannibalin yhteystiedot (gitignored)
│       └── napoleon.yml.example         # Pohja host_vars-tiedostolle
├── playbooks/
│   ├── deploy.yml                       # Pääplaybook
│   ├── harden.yml                       # Kovennukset erikseen ajettavaksi
│   └── update.yml                       # Pakettipäivitykset
└── roles/
    ├── common/                          # Peruskovennukset kaikille palvelimille
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
    ├── psql/                            # PostgreSQL-asennus ja konfiguraatio
    │   ├── tasks/main.yml
    │   └── handlers/main.yml
    └── users/                           # Fake-käyttäjät
        └── tasks/main.yml
```
