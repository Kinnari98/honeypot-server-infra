#!/bin/bash
#
# /usr/local/bin/backup_postgresql.sh
# Hallinnoi: Ansible (roles/crontab/templates/backup_postgresql.sh)
#
# Päivittäinen pg_dump sales-kannasta. Ajetaan cronista postgres-käyttäjänä
# klo 02:00. Muuttujat: roles/crontab/defaults/main.yml
#
# Kaksoisrooli: tämä on sekä oikea varmuuskopiointi (MOTD lupaa backupit, joten
# niiden on myös oltava olemassa) että houkutin – selkokielinen SQL-dump
# "tuotantokannasta" on uskottava palkinto hyökkääjälle.

set -euo pipefail

BACKUP_DIR="{{ backup_dir }}"
DB_NAME="{{ backup_db }}"
RETENTION_DAYS="{{ backup_retention_days }}"

# pg_hba.conf käyttää local-socketilla peer-autentikaatiota, eli Linux-käyttäjän
# on vastattava PostgreSQL-roolia. Rootina ajettuna tämä kaatuisi virheeseen
# "Peer authentication failed", joka ei kerro syytä – tarkistetaan se itse.
if [ "$(id -un)" != "postgres" ]; then
    echo "VIRHE: aja postgres-käyttäjänä:  sudo -u postgres $0" >&2
    exit 1
fi

# find varoittaa jos työhakemisto ei ole postgresin luettavissa (esim. kun
# skripti ajetaan käsin toisen käyttäjän kotihakemistosta). Siirrytään pois.
cd "$BACKUP_DIR"

TARGET="${BACKUP_DIR}/${DB_NAME}_$(date +%Y%m%d).sql"
TMP="${TARGET}.partial"

# Dumpataan väliaikaistiedostoon ja siirretään paikalleen vasta onnistuessa.
# Suora uudelleenohjaus kohteeseen jättäisi epäonnistuessa tyhjän tai katkenneen
# tiedoston, joka näyttää varmuuskopiolta muttei ole sellainen.
trap 'rm -f "$TMP"' EXIT

pg_dump "$DB_NAME" > "$TMP"
mv "$TMP" "$TARGET"

# Poista retention-ikkunaa vanhemmat dumpit ja mahdolliset keskeneräiset
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${DB_NAME}_*.sql" \
    -mtime "+${RETENTION_DAYS}" -delete
find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.partial" -mmin +60 -delete

# Kirjaa syslogiin → AMA → Sentinel. Antaa samalla vertailukohdan: jos dumppeja
# katoaa ilman vastaavaa lokiriviä, joku muu kuin tämä skripti on koskenut niihin.
logger -t pg-backup "backup of database '${DB_NAME}' completed: ${TARGET} ($(stat -c%s "$TARGET") bytes)"
