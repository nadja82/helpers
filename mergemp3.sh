#!/usr/bin/env bash
# merge_mp3s.sh — MP3s mergen (mit Progressbar)
# Optional: nach Änderungszeit umbenennen (älteste => 1.mp3).
set -u
OUT="output.mp3"
BAR_WIDTH=50

need() { command -v "$1" >/dev/null 2>&1 || { echo "[Error] $1 nicht gefunden."; exit 1; }; }
for t in ffmpeg ffprobe find sort awk; do need "$t"; done
test -w . || { echo "[Error] Kein Schreibrecht im aktuellen Verzeichnis."; exit 1; }

# ---- Liste nach mtime (älteste→neueste), space-safe, GNU/BSD-kompatibel
list_mp3_by_mtime_asc() {
  if find . -maxdepth 1 -type f -iname '*.mp3' -printf '%T@ %f\0' >/dev/null 2>&1; then
    find . -maxdepth 1 -type f -iname '*.mp3' -printf '%T@ %f\0' \
    | sort -z -n \
    | awk -v RS='\0' -v ORS='\0' -F' ' '{ $1=""; sub(/^ /,""); if(tolower($0)!="output.mp3") print $0 }'
  else
    find . -maxdepth 1 -type f -iname '*.mp3' -print0 \
    | while IFS= read -r -d '' f; do
        base="${f#./}"
        [[ "${base,,}" == "${OUT,,}" ]] && continue
        if stat -c '%Y' "$f" >/dev/null 2>&1; then ts=$(stat -c '%Y' "$f"); else ts=$(stat -f '%m' "$f"); fi
        printf '%s\t%s\0' "$ts" "$base"
      done \
    | sort -z -n \
    | awk -v RS='\0' -v ORS='\0' -F'\t' '{print $2}'
  fi
}

# ---- Optional: Umbenennen nach Aktualität
ask_and_rename_by_mtime() {
  mapfile -d '' -t ALL_MP3 < <(list_mp3_by_mtime_asc)
  (( ${#ALL_MP3[@]} > 0 )) || { echo "[Info] Keine MP3-Dateien gefunden."; return 1; }

  read -r -p "Alle MP3s nach Aktualität umbenennen (älteste = 1.mp3)? [j/N] " resp
  case "${resp:-N}" in
    j|J|y|Y)
      TMPFILES=()
      for f in "${ALL_MP3[@]}"; do
        tmp=".$$.rename.$RANDOM.$(date +%s).mp3"
        while [[ -e "$tmp" ]]; do tmp=".$$.rename.$RANDOM.$(date +%s).mp3"; done
        mv -f -- "$f" "$tmp" || { echo "[Error] Temp-Move für '$f' fehlgeschlagen."; return 2; }
        TMPFILES+=( "$tmp" )
      done
      idx=1
      for tmp in "${TMPFILES[@]}"; do
        final="${idx}.mp3"
        [[ -e "$final" ]] && rm -f -- "$final"
        mv -f -- "$tmp" "$final" || { echo "[Error] Rename '$tmp' → '$final' fehlgeschlagen."; return 3; }
        ((idx++))
      done
      echo "[OK] Neu nummeriert nach Änderungszeit."
      ;;
    *) echo "[Skip] Umbenennen übersprungen." ;;
  esac
}

# ---- Progressbar
draw_bar() {
  local done_us="$1" total_us="$2" width="$3"
  (( total_us == 0 )) && { printf "\r[working...]   "; return; }
  local pct=$(( done_us*100 / total_us )); (( pct > 100 )) && pct=100
  local filled=$(( width*pct/100 ))
  local empty=$(( width-filled ))
  printf -v hashes '%*s' "$filled" ''; hashes=${hashes// /#}
  printf -v dots   '%*s' "$empty"  ''; dots=${dots// /.}
  printf "\r[%s%s] %3d%%" "$hashes" "$dots" "$pct"
}

run_ffmpeg_with_progress() {
  local progress_fifo; progress_fifo="$(mktemp -u)"
  mkfifo "$progress_fifo"
  {
    while IFS='=' read -r k v; do
      [[ $k == out_time_ms ]] || continue
      v=${v%.*}
      draw_bar "$v" "$total_us" "$BAR_WIDTH"
    done < "$progress_fifo"
  } &
  local reader_pid=$!

  ffmpeg -hide_banner -y -f concat -safe 0 -i "$LISTFILE" "$@" -progress "$progress_fifo" -nostats >/dev/null 2>&1
  local rc=$?

  wait "$reader_pid" 2>/dev/null
  rm -f "$progress_fifo"
  return $rc
}

# ---- Start
ask_and_rename_by_mtime

# Nummerierte Dateien einsammeln — **case-insensitive** und robust
mapfile -t FILES < <(
  # bevorzugt: find mit -iregex (Ziffern + .mp3/.MP3)
  find . -maxdepth 1 -type f -regextype posix-extended -iregex '.*/[0-9]+\.mp3' -printf '%f\n' 2>/dev/null \
  | sort -V
)

# Fallback ohne -printf/-iregex
if (( ${#FILES[@]} == 0 )); then
  while IFS= read -r -d '' f; do
    b="${f#./}"
    [[ "${b,,}" =~ ^[0-9]+\.mp3$ ]] && FILES+=( "$b" )
  done < <(find . -maxdepth 1 -type f \( -iname '*.mp3' \) -print0)
  IFS=$'\n' FILES=($(printf '%s\n' "${FILES[@]}" | sort -V)); unset IFS
fi

# Diagnose, falls leer
if (( ${#FILES[@]} == 0 )); then
  echo "[Info] Keine nummerierten Dateien gefunden."
  echo "[Hint] Gefundene MP3s insgesamt: $(find . -maxdepth 1 -type f -iname '*.mp3' | wc -l)"
  echo "       Tipp: Frage mit 'j' bestätigen oder manuell z. B. '1.mp3', '2.mp3' benennen."
  exit 0
fi

# Concat-Liste
LISTFILE="$(mktemp)"; trap 'rm -f "$LISTFILE"' EXIT
for f in "${FILES[@]}"; do printf "file '%s'\n" "$PWD/$f" >> "$LISTFILE"; done

# Gesamtdauer (für Progress)
total_us=0
for f in "${FILES[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f" || echo 0)
  [[ $dur =~ ^[0-9] ]] || dur=0
  add_us=$(awk -v d="$dur" 'BEGIN{printf "%.0f", d*1000000}')
  total_us=$(( total_us + add_us ))
done
(( total_us > 0 )) || echo "[Warn] Gesamtdauer unklar – Progress ggf. ungenau."

rm -f -- "$OUT"

# 1) Stream copy
if run_ffmpeg_with_progress -c copy "$OUT"; then
  printf "\n[Fertig] %s erstellt (stream copy).\n" "$OUT"; exit 0
fi

# 2) Fallback: Re-encode
echo -e "\n[Info] Parameter-Mix erkannt – Fallback via libmp3lame 192k."
if run_ffmpeg_with_progress -vn -acodec libmp3lame -b:a 192k "$OUT"; then
  printf "\n[Fertig] %s erstellt (re-encode).\n" "$OUT"; exit 0
else
  printf "\n[Error] Zusammenfügen fehlgeschlagen.\n"; exit 1
fi
