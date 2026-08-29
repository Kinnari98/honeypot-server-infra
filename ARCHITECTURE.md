# Tekninen arkkitehtuuri – honeypot-server-infra

## Tarkoitus

Tämä projekti rakentaa korkean vuorovaikutuksen (high-interaction) honeypot-palvelimen, joka:

- Näyttää hyökkääjälle aidolta tuotantopalvelimelta
- Kirjaa kaiken toiminnan syscall-tasolla auditd:llä
- Välittää lokit automaattisesti Microsoft Sentineliin
- Ei käytä simuloituja ympäristöjä (ei Cowrieta, ei Dionaeaa)

Palvelin on tarkoituksella **houkutteleva kohde** – se ei torju hyökkäyksiä (ei fail2ban), vaan kerää mahdollisimman paljon dataa hyökkääjien toiminnasta.

> **Nykytila:** houkutintunnuksilla ei ole vielä salasanaa eikä `PasswordAuthentication` ole päällä, joten palvelimeen ei pääse sisään. Lokitusalusta on valmis, sisäänpääsyn avaus on erillinen vaihe. Ks. README, "Nykytila ja rajoitukset".

---

## Teknologiapino

| Kerros | Teknologia |
|---|---|
| Käyttöjärjestelmä | RHEL (Red Hat Enterprise Linux) |
| Provisionointi | Ansible |
| Palomuuri | firewalld – drop-zone sisään, policy object `egress` ulos |
| Syscall-lokitus | auditd + audispd-plugins |
| Prosessi-/verkkotelemetria | Sysmon for Linux *(pois käytöstä – ks. `monitoring`-rooli)* |
| Lokikuljetus | rsyslog → AMA |
| SIEM | Microsoft Sentinel / Log Analytics |
| Tietokanta (lure) | PostgreSQL |

---

## Ansible-roolit

### `common` – peruskovennukset

Ajetaan kaikille palvelimille. Sisältää:

- Pakettipäivitykset ja peruspaketit
- firewalld: drop-zone oletuksena, vain `honeypot_open_ports` sallittu sisään
- firewalld policy object `egress`: ulospäin sallitaan vain DNS, HTTP, HTTPS
- SSH: PermitRootLogin no
- auditd: kattavat syscall-säännöt (`audit.rules.j2`), lukitus `-e 2`
- audisp-syslog: audit-lokit → syslog-ketju
- Aikavyöhyke: UTC

Muuttujat: `roles/common/defaults/main.yml` (`honeypot_egress_allow`, `audit_immutable`).

### `high-interaction` – honeypot-identiteetti

Tekee palvelimesta uskottavan tuotantoympäristön:

- **issue.net** – pre-login varoitusbanneri (näkyy ennen autentikointia)
- **MOTD** – post-login operatiivinen tieto (palvelintyyppi, backup-status, maintenance-ikkuna)
- **system-status.sh** – dynaaminen järjestelmätieto kirjautuessa (uptime, CPU, muisti, levy)
- RHEL:n oletusviestit poistettu: poistetaan `/etc/insights-client/insights-client.motd`, johon `/etc/motd.d/insights-client` osoittaa. Insights-viesti paljastaisi palvelimen olevan tuore, rekisteröimätön RHEL-asennus.

Banneristrategia: palvelin esittäytyy PostgreSQL-tietokantapalvelimena tuotantoympäristössä. Backup-tiedot ja huoltoikkuna luovat vaikutelman hoidetusta palvelimesta.

Päivämäärät ovat muuttujia (`roles/high-interaction/defaults/main.yml`: `lure_next_maintenance`, `lure_last_backup`), koska ne vanhenevat. Menneisyyteen jäänyt "seuraava huoltoikkuna" on ensimmäinen asia josta tarkkaavainen hyökkääjä päättelee, ettei palvelinta oikeasti ylläpidetä.

### `psql` – PostgreSQL

- Asennus (`postgresql-server`, `python3-psycopg2`) ja initialisointi (`postgresql-setup --initdb`)
- Palvelun käynnistys ja autostart
- `pg_hba.conf` templatesta (`postgresql_hba_entries`): local-socket `peer`, TCP-localhost `scram-sha-256`. Ulkoista pääsyä ei sallita – 5432 ei ole `honeypot_open_ports`-listassa.
- Lokitus maksimoitu näkyvyyttä varten (`postgresql_settings`, ALTER SYSTEM → reload):
  `log_connections`, `log_disconnections`, `log_statement=all`, `log_line_prefix`
- **`log_destination=stderr,syslog` + `syslog_facility=LOCAL0`** – ilman tätä kantalokit
  jäisivät tiedostoihin `/var/lib/pgsql/data/log/` eivätkä päätyisi Sentineliin.
  Edellyttää että DCR kerää `local0`-facilityn.
- `sales`-tietokannan luonti
- PostgreSQL-käyttäjät: `psqladmin` (SUPERUSER), `psqluser` (CONNECT)
- Taulurakenne:

| Taulu | Kentät |
|---|---|
| `customers` | id, name, email |
| `products` | id, name, price |
| `orders` | id, customer_id (FK), product_id (FK), amount, order_date |

- Fake-data: asiakkaat, tuotteet ja tilaukset insertoidaan idempotentisti (`COUNT`-tarkistus)
- Backup: `/var/backups/sales-db/` – oikea pg_dump-tiedosto (lure)

### `users` – fake-käyttäjät

Luo uskottavan käyttäjärakenteen:

| Käyttäjä | Shell | Ryhmät | Tarkoitus |
|---|---|---|---|
| `psqladmin` | `/bin/bash` | – | PostgreSQL admin-tunnus |
| `psqluser` | `/sbin/nologin` | – | Palvelutili, ei kirjautumista |
| `mimu` | `/bin/bash` | `wheel` | Ylläpitäjä (sudo + kanta) |
| `pela` | `/bin/bash` | `wheel` | Ylläpitäjä (sudo + kanta) |

Tunnuksille **ei aseteta salasanaa**, joten ne ovat tällä hetkellä lukittuja. Sisäänpääsyn avaus on erillinen, vielä tekemätön vaihe – ks. README, "Nykytila ja rajoitukset".

### `crontab` – varmuuskopiointi

Asentaa `/usr/local/bin/backup_postgresql.sh` ja ajastaa sen päivittäin klo 02:00 postgres-käyttäjänä. `pg_dump` → `/var/backups/sales-db/sales_<pvm>.sql`, retention 14 vrk, ajo kirjataan syslogiin tagilla `pg-backup`.

Backup on samalla houkutin: hakemisto on tarkoituksella luettavissa (`0755`), ja selkokielinen dump "tuotantokannasta" on uskottava palkinto. MOTD viittaa siihen suoraan.

### `monitoring` – Sysmon for Linux (POIS KÄYTÖSTÄ)

`monitoring_enabled: false` – Sysmonia ei tällä hetkellä asenneta, koska `packages.microsoft.com` on NSG:n `DenyInternetOut`-säännön takana eikä pakettivarastoa voi hakea. Repoa ei kannata avata NSG:stä pelkän pakettivaraston takia. Kun rooli on pois käytöstä, `common` siivoaa tavoittamattoman repon pois – muuten se kaataisi `dnf update` -taskin jokaisella ajolla.

Kun se on käytössä, rooli asentaa Microsoftin pakettirepon ja `sysmonforlinux`-paketin, sekä konfiguraation `/etc/sysmon/sysmon-config.xml`. Kerää `ProcessCreate`, `NetworkConnect`, `FileCreate`, `FileDelete` ja `ProcessTerminate` -tapahtumat syslogiin.

Suodatus on rakennettu siten, että Azuren oma kohina (WALinuxAgent, gc_worker, rsyslogin tilatiedostot) jää pois **ilman että hyökkääjän vastaava toiminta suodattuisi** – esim. `iptables`-ajot suodatetaan `CurrentDirectory`-kentän perusteella, ei komennon nimen.

> **Päällekkäisyys auditd:n kanssa:** Sysmonin `NetworkConnect` ja auditd:n `socket`/`connect`/`accept`/`bind` -säännöt tuottavat saman verkkotelemetrian kahteen kertaan, samoin `ProcessCreate` ja `execve`. Standard_B1ms (1 vCPU / 2 GB) yhdistettynä `-b 16384` + `-f 1` -asetuksiin tarkoittaa, että puskurin täyttyessä tapahtumia katoaa hiljaisesti – ja Sentinel-ingestio maksaa kahdesta kopiosta. Päällekkäisyyden purkaminen on avoin päätös.

### `wireguard` – ylläpitäjien VPN

Asentaa `wireguard-tools`-paketin (RHEL 10:n omissa repoissa, ei EPEL-riippuvuutta), templatoi `/etc/wireguard/wg0.conf` oikeuksilla `0600` ja käynnistää `wg-quick@wg0`. Ajetaan omana playbookinaan (`playbooks/wireguard.yml`), ei osana `deploy.yml`:ää.

Kaikki avaimet ja osoitteet ovat vaultissa (`wireguard_*`). Template ohittaa peerin jos sen julkinen avain on tyhjä, joten toisen ylläpitäjän voi lisätä myöhemmin ilman templaten muokkausta.

Portti avataan `honeypot_open_ports`-listan kautta kuten kaikki muutkin – roolissa ei ole omaa firewalld-taskia.

### Ylläpitäjien pääsyn rajaus

`common`-rooli lisää `sshd_config`-tiedoston loppuun `Match`-lohkon, joka poistaa `admin_users`-listan tunnuksilta autentikoinnin kaikkialta muualta kuin WireGuard-subnetistä:

```
Match User <admin_users> Address !<wireguard_network>
    PubkeyAuthentication no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
```

Idea on että ylläpitäjien tunnukset **näkyvät** `/etc/passwd`:ssä ja tekevät palvelimesta uskottavamman, mutta eivät ole hyökkääjän käytettävissä. Houkutintunnuksiin (`mimu`, `pela`, `psql*`) rajoitus ei vaikuta – ne jäävät auki julkiseen porttiin 22, koska ne ovat se reitti jota pitkin hyökkääjän on tarkoituskin tulla.

`validate: sshd -t -f %s` estää rikkinäisen konfiguraation kirjoittamisen. Se ei kuitenkaan estä lukkiutumista: syntaksi voi olla oikein ja silti sulkea sinut ulos. Ansible yhdistää `azureuser`-tunnuksella, joka ei ole `admin_users`-listalla, joten korjausreitti säilyy.

> **Deployn järjestys on olennainen.** WireGuard on saatava pystyyn ja todennettua ENNEN kuin tämä rajoitus astuu voimaan – muuten ylläpitäjien oma pääsy katkeaa siihen asti kunnes VPN toimii.

> **`Match`-lohko on oltava viimeisenä.** sshd:ssä kaikki `Match`-lohkon jälkeen tuleva kuuluu siihen lohkoon. `high-interaction`-roolin `Banner`- ja `PrintMotd`-taskit käyttävät siksi `insertbefore: '^Match '` -suojausta: tyhjällä palvelimella `lineinfile` lisäisi puuttuvan rivin tiedoston loppuun eli rajoituksen sisään, jolloin banneri näkyisi vain ylläpitäjille eikä lainkaan hyökkääjälle.

### `admins` – oikeat ylläpitäjät

Ansible-vaultilla salattu `tasks/main.yml`, joka luo oikeat ylläpitotunnukset ja SSH-julkiavaimet. Ajetaan erikseen (`playbooks/admins.yml`), ei osana `deploy.yml`:ää, jotta houkutin- ja ylläpitotunnukset pysyvät erillään.

### `defender` – KESKENERÄINEN

`roles/defender/tasks/main.yml` on tyhjä. `playbooks/harden.yml` ajaa sen, mutta ei tee vielä mitään.

---

## Lokiketju

Lokeja kerätään rinnakkaisista lähteistä, jotka kaikki päätyvät rsyslogin kautta samaan putkeen. **Sysmon-haara on tällä hetkellä pois käytöstä** (ks. `monitoring`-rooli), joten toiminnassa ovat auditd ja PostgreSQL.

```
Palvelin
┌──────────────────────────────────────────────────────────┐
│  Hyökkääjän toiminto (komento, yhteys, kysely)           │
│         ↓                    ↓                  ↓        │
│  Linux kernel syscall    Sysmon (eBPF)     PostgreSQL    │
│         ↓                    ↓                  ↓        │
│  auditd                  ProcessCreate     log_statement │
│  /var/log/audit/         NetworkConnect    log_connect.  │
│         ↓                FileCreate/Delete      ↓        │
│  audisp-syslog                ↓            facility      │
│  (audispd-plugins)            │            local0        │
│         └─────────────────────┴─────────────────┘        │
│                            ↓                             │
│                        rsyslog                           │
└──────────────────────────────────────────────────────────┘
                             ↓
Azure
┌──────────────────────────────────────────────────────────┐
│  AMA (Azure Monitor Agent) ← asennetaan DCR:n kautta      │
│                             ↓                            │
│  Log Analytics Workspace → Microsoft Sentinel             │
└──────────────────────────────────────────────────────────┘
```

AMA:ta ei asenneta Ansiblella – se asennetaan automaattisesti kun Data Collection Rule (DCR) liitetään VM:ään Azure-portaalista tai Terraformilla.

> **DCR:ää ei ole vielä liitetty.** Kaavion Azure-puolisko on suunnitelma, ei nykytila: putki toimii palvelimen rsyslogiin asti ja pysähtyy siihen. Ansiblen hallitsema osuus (auditd → audisp-syslog → rsyslog, Sysmon → rsyslog, PostgreSQL → rsyslog) on valmis ja testattavissa palvelimella jo nyt.

**DCR:n on kerättävä `local0`-facility**, muuten PostgreSQL-lokit pysähtyvät rsyslogiin. Auditd- ja Sysmon-tapahtumat tulevat oletusfacilityillä.

Tapahtumat päätyvät `Syslog`-tauluun, eivät `CommonSecurityLog`-tauluun. Auditd-sääntöjen `-k`-tagi näkyy `SyslogMessage`-kentässä muodossa `key="<tagi>"`. Esimerkkikyselyt: `kql.txt`.

---

## Palomuuristrategia

Suodatus on kahdessa kerroksessa, ja **Azure NSG on niistä tärkeämpi**. Hyökkääjä joka saa rootin voi poistaa hostin palomuurin käytöstä; NSG:hen hän ei pysty koskemaan. Host-tason firewalld on puolustuksen syvyyttä, ei ensisijainen kontrolli.

### Azure NSG (ensisijainen)

| Prioriteetti | Sääntö | Suunta | Vaikutus |
|---|---|---|---|
| 220 | `AllowWireguardInbound` – UDP 51820 | sisään | Ylläpitäjien VPN (`wireguard`-rooli) |
| 4000 | `AllowAzureMonitorOut` – TCP 443 → `AzureMonitor` | ulos | **Telemetriapolku Sentineliin** |
| 4010 | `DenyInternetOut` – kaikki → `Internet` | ulos | Estää ulospääsyn julkiseen internetiin |
| 4020/4030 | SSH sallittu kahdesta ylläpitäjän IP:stä | sisään | Hallintapääsy |
| 4040 | ICMP yhdestä IP:stä | sisään | |

Prioriteetti 4000 voittaa 4010:n, joten AMA:n telemetria pääsee ulos vaikka muu internet on kiinni. Tämä on koko egress-strategian ydin: **täsmäreikä telemetrialle, ei yleistä ulospääsyä.**

> **Egress on väliaikaisesti auki.** Azuren RHUI-endpoint `rhui4-1.microsoft.com`
> resolvoituu julkiseen osoitteeseen (`azure-rhui4.<region>.cloudapp.azure.com`),
> joten `DenyInternetOut` esti sen – eikä kone saanut tietoturvapäivityksiä
> lainkaan. NSG:hen on lisätty Azuren endpointeille Allow-säännöt prioriteetilla
> alle 4010, ja `dnf` toimii taas.
>
> Tila on tietoisesti väliaikainen: koneessa ei ole vielä ketään, joten
> ulospääsystä ei aiheudu riskiä. **Egress suljetaan ennen honeypotin avaamista**
> (README: avaamisen tarkistuslista).
>
> Taustalla on projektin keskeinen jännite, jota tämä ei poista: **sama kontrolli
> joka estää honeypotin käytön hyökkäysalustana estää myös sen paikkaamisen.**
> Kun egress suljetaan, päivitykset lakkaavat jälleen toimimasta. Steady state
> -ratkaisu on valitsematta; vaihtoehdot ovat huoltoikkuna (egress auki hetkeksi,
> ks. ToDo.md kohta 4), pysyvä RHUI-poikkeus, tai tietoinen päätös jättää kone
> päivittämättä. Huomaa että RHUI on Traffic Managerin takana, joten yksittäisen
> IP:n allowlistaus on hauras.
>
> Miksi egress-rajoitus ylipäätään: honeypotissa kompromissi on myönnetty
> lähtökohdaksi, joten ainoa jäljellä oleva turvakysymys on mitä hyökkääjä voi
> tehdä root-oikeuksin. Ulospääsy on se, joka muuttaa koneen aseeksi muita
> vastaan – pivot, C2, botnet, spam – ja tekee tilauksesta abuse-vastuullisen.
> Erityisesti: VM:llä on managed identity AMA:a varten, ja root-oikeuksin siihen
> saa tokenin IMDS:stä. Honeypot ei siis ole irrallinen laatikko vaan jalansija
> Azure-tilaukseen.

Seurauksia joita ei näe koodista:

- Julkisessa internetissä olevat pakettivarastot eivät ole tavoitettavissa. `packages.microsoft.com` on niiden joukossa, minkä vuoksi Sysmon on toistaiseksi pois käytöstä (`monitoring_enabled: false`). RHEL:n omat päivitykset toimivat, koska Azuren RHUI on sisäverkossa.
- Managed identity toimii, koska token haetaan IMDS:stä (`169.254.169.254`), joka on link-local eikä kulje NSG:n läpi.
- Palvelin ei ole tällä hetkellä tavoitettavissa internetistä lainkaan: SSH on sallittu vain kahdesta ylläpitäjän IP:stä. Honeypotin avaaminen edellyttää tämän muuttamista NSG:ssä sen lisäksi että houkutintunnuksille asetetaan salasanat.

### firewalld hostissa (puolustuksen syvyys)

**Sisäänpäin (inbound):** kaikki estetty oletuksena (drop-zone). Vain `honeypot_open_ports`-listassa määritellyt portit sallitaan.

Lista on **auktoritatiivinen**: `common`-rooli sekä avaa listan portit että sulkee kaikki muut. Ilman sovitusta Ansiblen `firewalld`-moduuli vain lisää portteja eikä koskaan poista, jolloin lista olisi pelkkä lisäysjono ja palvelimen todellinen tila ajautuisi hiljaa erilleen reposta. Näin oli käynytkin: drop-zonessa oli auki 23, 80, 443, 445, 3306 ja 5900 ilman että mikään kuunteli niissä eikä repo tiennyt niistä mitään.

Ne suljettiin, kahdesta syystä. **Persoonan johdonmukaisuus:** palvelin esittää PostgreSQL-kantapalvelinta, joten avoin MySQL-portti 3306 on suora ristiriita – samoin SMB ja VNC Linux-kantapalvelimella. Hyökkääjä lukee porttiskannauksesta persoonan, ja epäjohdonmukaisuus kertoo hänelle enemmän kuin meille. **Ei signaalia:** portti jonka takana ei kuuntele mitään vastaa `connection refused` eikä tuota yhtään vuorovaikutusdataa – vain skannauskohinaa lokeihin.

Jos porttia halutaan käyttää houkuttimena, sen taakse on laitettava jotain joka vastaa. Pelkkä avoin portti ei ole houkutin.

Sovitustaskia edeltää `assert`, joka keskeyttää ajon jos portti 22 puuttuu listalta – muuten sovitus katkaisisi hallintayhteyden.

**Ulospäin (outbound):** firewalld **policy object** `egress` (`/etc/firewalld/policies/egress.xml`, template `roles/common/templates/egress-policy.xml.j2`):

- `ingress-zone=HOST`, `egress-zone=ANY` → koskee palvelimen omaa lähtevää liikennettä
- `target=REJECT` → kaikki mitä ei erikseen sallita, torjutaan
- Sallittu (`honeypot_egress_allow`): `dns`, `http`, `https` – nimenselvitys, pakettirepot, AMA→Sentinel
- Established/related-paluuliikenteen firewalld hoitaa conntrackilla itse

Tämä estää honeypotin käyttämisen hyökkäysalustana edelleen (pivot/lateral movement).

> **Miksi ei iptables.** Aiempi toteutus käytti `iptables`-moduulia OUTPUT-ketjuun. Se oli rikki kahdella tavalla: säännöt elivät vain ajonaikaisessa taulussa (ei `iptables-services`, ei `iptables-save`), joten **outbound-lukitus katosi ensimmäisessä rebootissa** – hiljaisesti, mitään ei näkynyt lokeissa. Lisäksi `OUTPUT policy DROP` ilman `-o lo -j ACCEPT` -sääntöä katkaisi loopback-liikenteen, mikä rikkoi mm. `psql -h 127.0.0.1` -yhteydet joita `pg_hba.conf` nimenomaan odottaa. Policy object persistoituu itsestään eikä koske loopbackiin.

---

## Auditd-säännöt

Säännöt on jaettu kategorioihin (`audit.rules.j2`):

| Kategoria | Tagi Sentinelissä | Mitä valvotaan |
|---|---|---|
| Prosessien suoritus | `process_execution` | Kaikki `execve`-syscallit – jokainen ajettu komento |
| Oikeuksien eskalointi | `priv_escalation` | setuid/setgid, sudo, su, pkexec |
| Käyttäjähallinta | `user_management` | /etc/passwd, /etc/shadow, /etc/sudoers, useradd/del/mod |
| SSH-avaimet | `ssh_key_injection` | /root/.ssh |
| Kotihakemistot | `home_dir_changes` | /home – mm. käyttäjien authorized_keys |
| Autentikaatiokonfiguraatio | `auth_config` | /etc/pam.d, /etc/security |
| Kirjautumislokit | `auth_log` | wtmp, btmp, utmp |
| Verkkokonfiguraatio | `network_config` | /etc/hosts, resolv.conf |
| Verkkoaktiviteetti | `network_activity` | socket, connect, accept, **accept4**, bind syscallit |
| Kernel-moduulit | `kernel_modules` | insmod, rmmod, modprobe – rootkit-havaitseminen |
| Persistenssi (cron) | `persistence_cron` | /etc/cron.*, /etc/crontab, /var/spool/cron |
| Persistenssi (systemd) | `persistence_systemd` | /etc/systemd/system |
| LD_PRELOAD | `ld_preload_rootkit` | kirjastohyökkäykset |
| Binääritamperointi | `binary_tampering` | /bin, /sbin, /usr/bin, /lib muutokset |
| Lokien tuhoaminen | `log_tampering` | /var/log muutokset |
| Tiedosto-oikeudet | `file_permissions` | chmod, fchmod, fchmodat |
| Tiedoston omistajuus | `file_ownership` | chown, fchown, fchownat, lchown |
| Tiedostojen poisto | `file_deletion` | unlink, unlinkat, rename, renameat, **renameat2** |

**Lokitusinfrastruktuuri on suljettava pois.** Sääntötiedosto alkaa `never,exit`-säännöillä, jotka poistavat auditoinnista `rsyslogd`, `auditd` ja `systemd-journald` (`audit_exclude_exe`). Ilman niitä syntyy takaisinkytkentä: rsyslog kirjoittaa tilatiedostonsa uudelleennimeämällä, se osuu `file_deletion`-sääntöön, syntyvä audit-tapahtuma kulkee rsyslogin läpi ja aiheuttaa uuden kirjoituksen. Mitattu tyhjäkäyntitaso ennen korjausta oli **~340 riviä sekunnissa eli ~15 GB vuorokaudessa** koneella jossa ei ollut ketään – pelkkää itse tuotettua kohinaa. Poissulkemisten on oltava ennen `always,exit`-sääntöjä, koska kernel käy exit-suodattimen läpi järjestyksessä ja ensimmäinen osuma ratkaisee.

### Volyymin viritys

Auditd tuottaa oletusasetuksilla enemmän dataa kuin honeypotin kokoinen kone kestää, ja Sentinel-ingestio maksaa jokaisesta rivistä. Tyhjäkäyntitaso on viritetty mitaten, ei arvaten:

| Vaihe | Riviä/min | GB/vrk |
|---|---|---|
| Lähtötilanne | ~20 000 | ~15 |
| `never`-säännöt lokitusinfralle | 406 | ~0,3 |
| AMA asennettu | 3 364 | ~2,4 |
| `auid`-suodatin verkkosääntöihin | 2 718 | ~2,0 |
| `auid`-suodatin `file_deletion`iin | **151** | **~0,1** |

Kaksi asiaa tekee virityksestä epäintuitiivista.

**Kerroin.** Yksi audit-tapahtuma tuottaa syslogiin noin kuusi riviä: `SYSCALL`, `PATH`, `CWD`, `PROCTITLE` ja `EOE`. Yhden tapahtuman poistaminen poistaa siis kuusi riviä ingestiosta, ja tapahtumamäärää tuijottamalla saa väärän kuvan kustannuksesta.

**Lähde ei ole se miltä näyttää.** AMA:n asennuksen jälkeen `file_deletion` tuotti 799 tapahtumaa kahdessa minuutissa, joista 778 oli agentin omaa lokinkierrätystä – 97 % säännöstä ja 53 % kaikista tapahtumista. Verkkosääntöjen suodattaminen tuntui ilmeiseltä korjaukselta mutta pudotti volyymia vain 19 %. Oikea sääntö löytyi vasta kysymällä auditd:ltä avainjakauma:

```bash
journalctl SYSLOG_FACILITY=22 --since "-2 min" | tr " " "\n" | grep ^key= | sort | uniq -c | sort -rn
```

`auid`-suodattimet (`audit_network_user_only`, `audit_file_deletion_user_only`) rajaavat säännöt käyttäjälähtöiseen toimintaan. Järjestelmädemonit ajavat `auid=unset`-tilassa, hyökkääjä SSH:n kautta ei – ja `auid` säilyy `sudo`n ja `su`:n läpi, joten myös root-oikeuksin tehty toiminta kirjautuu. Suodatin on kestävämpi kuin binäärien luettelointi `audit_exclude_exe`-listaan, koska agentit päivittävät itseään ja polut vanhenevat hiljaisesti.

**`process_execution` on tarkoituksella suodattamatta.** Se on honeypotin arvokkain sääntö – jokainen hyökkääjän ajama komento. `auid`-suodatin poistaisi cronin ja systemd:n kautta ajetut prosessit, eli juuri sen mitä hyökkääjän asentama persistenssi tuottaa. Jos volyymia on pakko karsia lisää, `log_tampering`- ja `binary_tampering`-watch-säännöistä on halvempi luopua kuin komentohistoriasta.

**Syscall-nimet ovat tarkkoja.** `accept4` ja `renameat2` on lisättävä erikseen, koska moderni glibc ja coreutils käyttävät niitä vanhempien tilalla: ilman `accept4`:ää saapuvat SSH-yhteydet eivät osu `network_activity`-sääntöön lainkaan, ja ilman `renameat2`:ta `mv`-komennolla tehty jälkien siivous jää kirjaamatta.

### Sääntöjen lukitus ja sen hinta

Säännöt lukitaan `-e 2`:lla – hyökkääjä ei voi poistaa auditia käytöstä ilman rebootia (joka myös lokitetaan).

Lukitus koskee kuitenkin myös ylläpitoa: kun `-e 2` on voimassa, `audit.rules.j2`:n muutokset kirjoittuvat palvelimelle mutta **eivät astu voimaan ennen rebootia**. `augenrules --load` epäonnistuu odotetusti, eikä playbook laske sitä virheeksi – se varoittaa ja jatkaa.

Kehityksessä lukituksen voi ohittaa muuttujalla `audit_immutable=false` (`roles/common/defaults/main.yml`), jolloin templaten loppuun kirjoitetaan `-e 1` ja sääntöjä voi iteroida ilman rebootia.

Huomaa myös, ettei auditd:tä voi käynnistää uudelleen systemd:llä RHEL:llä – `auditd.service` on `RefuseManualStop=yes`, joten `systemctl restart auditd` hylätään. Sääntöjen lataus tehdään siksi `augenrules --load` -komennolla, ei `service`-moduulilla.

---

## Turvallisuushuomiot

**Konfiguraation jako.** `inventory/group_vars/all/` on jaettu kahtia:

| Tiedosto | Sisältö | Versionhallinnassa |
|---|---|---|
| `vars.yml` | Ei-arka konfiguraatio, viittaa salaisuuksiin `vault_`-etuliitteellä | Selkokielisenä |
| `vault.yml` | Salaisuudet ja arat arvot (hostname, salasanat, workspace key) | **Ansible-vaultilla salattuna** |

Molemmat committoidaan, jotta tiimi jakaa saman konfiguraation gitin kautta – `vault.yml` vain salattuna. Näin `vars.yml`:stä näkee *mitkä* muuttujat ovat arkoja ilman että arvot vuotavat. `inventory/host_vars/*.yml` (palvelinkohtaiset yhteystiedot) ovat gitignored, `.example`-tiedostot repossa pohjaksi.

Roolikohtaiset ei-arat oletukset ovat `roles/<rooli>/defaults/main.yml`:ssä, ja ne voi ylikirjoittaa group_vars/host_vars-tasolla.

**Vuotojen esto.** `.githooks/pre-commit` estää salaamattoman vault-tiedoston committaamisen. Se tarkistaa sekä eksplisiittisesti listatut tiedostot että kaikki jotka olivat HEADissa jo salattuja – jälkimmäinen estää vahingossa tehdyn `ansible-vault decrypt`in päätymisen repoon. Hook on versionhallinnassa mutta vaatii kertaluontoisen aktivoinnin: `git config core.hooksPath .githooks`.

**Muut periaatteet:**

- fail2ban on **tarkoituksella poistettu** – honeypotilla ei blokata hyökkääjiä, enemmän yrityksiä = enemmän dataa
- Pääsynhallinta hoidetaan Azure NSG:llä, ei palvelimella
- Houkutin- ja ylläpitotunnukset ovat eri rooleissa ja eri playbookeissa, jotta oikeat ylläpitäjät eivät vuoda selkokielisenä repoon
