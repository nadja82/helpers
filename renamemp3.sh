#!/usr/bin/env bash
# rename_mp3_by_mtime.sh
set -euo pipefail

DIR="."
AUTO_YES=false
DRY_RUN=false

usage() {
  echo "Usage: $(basename "$0") [-d DIR] [-y] [-n]"
  echo "  -d DIR  Arbeitsverzeichnis (Default: .)"
  echo "  -y      Ohne Rückfrage durchführen"
  echo "  -n      Dry-Run (nur anzeigen, nicht umbenennen)"
  exit 1
}

while getopts ":d:ynh" opt; do
  case "$opt" in
    d) DIR="$OPTARG" ;;
    y) AUTO_YES=true ;;
    n) DRY_RUN=true ;;
    h|*) usage ;;
  esac
done

# Verzeichnis prüfen
if [[ ! -d "$DIR" ]]; then
  echo "Fehler: Verzeichnis nicht gefunden: $DIR" >&2
  exit 2
fi

# MP3s nach mtime sammeln (älteste zuerst), NUL-getrennt
# Format: "<epoch> <pfad>\0"  → sortieren → Pfad extrahieren
mapfile -d '' -t FILES < <(
  find "$DIR" -maxdepth 1 -type f -iregex '.*\.mp3$' -printf '%T@ %p\0' \
  | sort -z -n \
  | awk -v RS='\0' -v ORS='\0' '{sub(/^[^ ]+ /,""); print}'
)

COUNT=${#FILES[@]}
if (( COUNT == 0 )); then
  echo "Info: Keine MP3-Dateien im Verzeichnis gefunden: $DIR"
  exit 0
fi

echo "Gefunden: $COUNT MP3-Datei(en) in: $DIR"
echo "Zielschema: 1.mp3, 2.mp3, ... (älteste zuerst)"

# Bestätigung
if ! $AUTO_YES; then
  read -rp "Fortfahren? [ja/NEIN] " ANSWER
  case "${ANSWER,,}" in
    j|ja) ;;
    *) echo "Abgebrochen."; exit 0 ;;
  esac
fi

# Dry-Run: nur anzeigen
if $DRY_RUN; then
  i=1
  for src in "${FILES[@]}"; do
    printf 'PLAN: "%s" → "%s/%d.mp3"\n' "$src" "$DIR" "$i"
    ((i++))
  done
  echo "Dry-Run abgeschlossen. Keine Änderungen vorgenommen."
  exit 0
fi

# Kollisionen vermeiden: temporäres Arbeitsverzeichnis im selben Ordner
TMPDIR=$(mktemp -d --tmpdir="$DIR" ".rename_tmp.XXXXXX")
cleanup() { rm -rf -- "$TMPDIR"; }
trap cleanup EXIT

# Pass 1: alles temporär verschieben in Reihenfolge
i=1
for src in "${FILES[@]}"; do
  tmp="$TMPDIR/$i.mp3"
  printf 'MOVE1: "%s" → "%s"\n' "$src" "$tmp"
  mv -f -- "$src" "$tmp"
  ((i++))
done

# Pass 2: final benennen
i=1
while (( i <= COUNT )); do
  final="$DIR/$i.mp3"
  tmp="$TMPDIR/$i.mp3"
  printf 'MOVE2: "%s" → "%s"\n' "$tmp" "$final"
  mv -f -- "$tmp" "$final"
  ((i++))
done

echo "Erfolg: $COUNT Datei(en) nach mtime als 1.mp3 … ${COUNT}.mp3 umbenannt."
