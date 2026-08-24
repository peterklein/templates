#!/bin/zsh

set -u
set -o pipefail

# ------------------------------------------------------------
# Konfiguration
# ------------------------------------------------------------

SOURCE="$HOME/workspace/"

SMB_USER=""
SMB_SERVER=""
SMB_SHARE=""

LOG_DIR="$HOME/Library/Logs/workspace-backup"
LOCK_DIR="/tmp/workspace-backup-$UID.lock"

# ------------------------------------------------------------
# Optionen
# ------------------------------------------------------------

DRY_RUN=false
DELETE_REMOTE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --delete)
            DELETE_REMOTE=true
            ;;
        *)
            echo "Unbekannte Option: $arg"
            echo "Erlaubt: --dry-run --delete"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/$(date '+%Y-%m-%d').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ------------------------------------------------------------
# Verhindern, dass zwei Backups gleichzeitig laufen
# ------------------------------------------------------------

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Backup läuft offenbar bereits."
    exit 1
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# Quelle prüfen
# ------------------------------------------------------------

if [[ ! -d "$SOURCE" ]]; then
    log "FEHLER: Quellverzeichnis existiert nicht:"
    log "$SOURCE"
    exit 2
fi

# ------------------------------------------------------------
# SMB-Mount suchen
# ------------------------------------------------------------

find_mount() {

    /sbin/mount | /usr/bin/awk \
        -v server="$SMB_SERVER" \
        -v share="$SMB_SHARE" '

    {
        needle = "@" server "/" share " on "
        pos = index($0, needle)

        if (pos > 0 && index($0, "(smbfs") > 0) {

            rest = substr($0, pos + length(needle))
            endpos = index(rest, " (smbfs")

            if (endpos > 0) {
                print substr(rest, 1, endpos - 1)
                exit
            }
        }
    }'
}

MOUNT_POINT="$(find_mount)"

# ------------------------------------------------------------
# Share mounten, falls noch nicht vorhanden
# ------------------------------------------------------------

if [[ -z "$MOUNT_POINT" ]]; then

    log "SMB-Share ist nicht gemountet."
    log "Verbinde mit $SMB_SERVER ..."

    /usr/bin/osascript \
        -e "mount volume \"smb://${SMB_USER}@${SMB_SERVER}/${SMB_SHARE}\""

    # Maximal ca. 20 Sekunden auf Mount warten
    for i in {1..20}; do

        MOUNT_POINT="$(find_mount)"

        if [[ -n "$MOUNT_POINT" ]]; then
            break
        fi

        sleep 1
    done
fi

# ------------------------------------------------------------
# Mount überprüfen
# ------------------------------------------------------------

if [[ -z "$MOUNT_POINT" ]]; then
    log "FEHLER: SMB-Share konnte nicht gemountet werden."
    exit 3
fi

if [[ ! -d "$MOUNT_POINT" ]]; then
    log "FEHLER: Mountpoint existiert nicht:"
    log "$MOUNT_POINT"
    exit 4
fi

log "NAS gemountet unter:"
log "$MOUNT_POINT"

# ------------------------------------------------------------
# Schreibzugriff testen
# ------------------------------------------------------------

TEST_FILE="$MOUNT_POINT/.workspace-backup-write-test-$$"

if ! touch "$TEST_FILE" 2>/dev/null; then
    log "FEHLER: Kein Schreibzugriff auf das NAS."
    exit 5
fi

rm -f "$TEST_FILE"

# ------------------------------------------------------------
# rsync auswählen
# ------------------------------------------------------------

if [[ -x "/opt/homebrew/bin/rsync" ]]; then
    RSYNC="/opt/homebrew/bin/rsync"

elif [[ -x "/usr/local/bin/rsync" ]]; then
    RSYNC="/usr/local/bin/rsync"

else
    RSYNC="/usr/bin/rsync"
fi

log "Verwende rsync:"
"$RSYNC" --version | head -n 1

# ------------------------------------------------------------
# rsync Optionen
# ------------------------------------------------------------

RSYNC_ARGS=(
    -a
    --human-readable
    --stats
    --itemize-changes

    # Unix-Berechtigungen sind über SMB für uns uninteressant
    --no-owner
    --no-group
    --no-perms

    # macOS
    --exclude=.DS_Store

    # Node / Next / Frontend
    --exclude=node_modules/
    --exclude=.next/
    --exclude=.nuxt/
    --exclude=.turbo/
    --exclude=dist/
    --exclude=build/
    --exclude=coverage/

    # allgemeine Caches
    --exclude=.cache/

    # Rails
    --exclude=tmp/
    --exclude=log/
    --exclude=vendor/bundle/
)

if $DRY_RUN; then
    RSYNC_ARGS+=(--dry-run)
    log "DRY-RUN aktiviert – es werden keine Dateien verändert."
fi

if $DELETE_REMOTE; then
    RSYNC_ARGS+=(--delete)
    log "ACHTUNG: --delete aktiviert."
fi

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

log "Starte Synchronisierung"
log "Quelle: $SOURCE"
log "Ziel:   $MOUNT_POINT/"

"$RSYNC" \
    "${RSYNC_ARGS[@]}" \
    "$SOURCE" \
    "$MOUNT_POINT/"

RESULT=$?

# ------------------------------------------------------------
# Ergebnis
# ------------------------------------------------------------

if [[ $RESULT -eq 0 ]]; then
    log "Backup erfolgreich abgeschlossen."
else
    log "FEHLER: rsync wurde mit Code $RESULT beendet."
fi

exit $RESULT
