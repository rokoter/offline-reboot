#!/usr/bin/env bash
# Doomsday Digital Library - jaarlijkse/offline sync
# Usage: ./doomsday_sync.sh /pad/naar/doelmap
set -u

DEST_ROOT="${1:-$PWD/DoomsdayLibrary}"
DATE_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG="$DEST_ROOT/_logs/sync-$DATE_STAMP.log"
mkdir -p "$DEST_ROOT/_logs"
exec > >(tee -a "$LOG") 2>&1

# -------- helpers --------
have() { command -v "$1" >/dev/null 2>&1; }

# downloader: aria2c (snel, parallel) -> wget (fallback)
dl() {
  url="$1"; outdir="$2"; fname="${3:-}"
  mkdir -p "$outdir"
  if [ -z "$fname" ]; then fname="$(basename "$url" | sed 's/[?].*$//')"; fi
  outpath="$outdir/$fname"
  if have aria2c; then
    aria2c -x16 -s16 -k1M --dir="$outdir" --out="$fname" --file-allocation=none \
           --auto-file-renaming=false --continue=true "$url"
  else
    wget -c -nv -O "$outpath" "$url" || { echo "wget failed for $url"; return 1; }
  fi
}

# Timestamped re-download (wget --timestamping equivalent via headers)
dl_ts() {
  url="$1"; outdir="$2"; fname="${3:-}"
  mkdir -p "$outdir"
  if have aria2c; then
    # aria2c mist --timestamping; gebruik gewone dl()
    dl "$url" "$outdir" "$fname"
  else
    mkdir -p "$outdir"
    if [ -z "$fname" ]; then
      (cd "$outdir" && wget -N -nv "$url")
    else
      (cd "$outdir" && wget -N -nv -O "$fname" "$url")
    fi
  fi
}

# haal directory-index op en kies laatste bestand dat op prefix past
latest_from_index() {
  base="$1"      # bv. https://download.kiwix.org/zim/wikipedia/
  prefix="$2"    # bv. wikipedia_en_all_maxi_
  ext="${3:-.zim}"
  echo ">>> Fetching index: $base" 1>&2
  html="$(curl -fsSL "$base")" || return 1
  echo "$html" \
    | grep -Eo "href=\"(${prefix}[^\"]*${ext})\"" \
    | sed -E 's/^href="//; s/"$//' \
    | sort -V \
    | tail -n1
}

# Git clone/pull (shallow)
git_sync() {
  repo="$1"; dest="$2"
  if [ -d "$dest/.git" ]; then
    echo ">>> Git updating $dest"
    git -C "$dest" fetch --depth=1 origin && git -C "$dest" reset --hard origin/HEAD
  else
    echo ">>> Git cloning $repo -> $dest"
    git clone --depth=1 "$repo" "$dest"
  fi
}

# -------- start --------
echo "==== Doomsday Digital Library sync @ $DATE_STAMP ===="
echo "Target: $DEST_ROOT"
mkdir -p "$DEST_ROOT"/{isos,kiwix,code,osm,_meta}

# ---------- ISOs ----------
echo "== ISOs =="

# Debian stable netinst (auto-current)
DEBIAN_DIR_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
deb_latest="$(latest_from_index "$DEBIAN_DIR_URL" "debian-.*-amd64-netinst" ".iso")"
if [ -n "$deb_latest" ]; then
  dl_ts "${DEBIAN_DIR_URL}${deb_latest}" "$DEST_ROOT/isos"
  dl_ts "${DEBIAN_DIR_URL}SHA512SUMS" "$DEST_ROOT/isos"
  dl_ts "${DEBIAN_DIR_URL}SHA512SUMS.sign" "$DEST_ROOT/isos"
fi

# Arch Linux (stabiel "latest" alias)
dl_ts "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso" "$DEST_ROOT/isos"
dl_ts "https://geo.mirror.pkgbuild.com/iso/latest/sha256sums.txt" "$DEST_ROOT/isos" "archlinux-x86_64.iso.sha256"

# SystemRescue (laatste via projectpagina mirror)
# Gebruik Fastly mirror index om laatste ISO te vinden
SYSR_BASE="https://fastly.system-rescue.org/iso/"
sysr_latest="$(latest_from_index "$SYSR_BASE" "systemrescue-" ".iso")"
if [ -n "$sysr_latest" ]; then
  dl_ts "${SYSR_BASE}${sysr_latest}" "$DEST_ROOT/isos"
  dl_ts "${SYSR_BASE}${sysr_latest}.sha256sum" "$DEST_ROOT/isos"
fi

# ---------- Kiwix (offline kennis) ----------
echo "== Kiwix ZIMs =="

KIWIX_BASE_WP="https://download.kiwix.org/zim/wikipedia/"
KIWIX_BASE_WV="https://download.kiwix.org/zim/wikivoyage/"
KIWIX_BASE_WB="https://download.kiwix.org/zim/wikibooks/"

# Wikipedia en maxi + nopic (Engels)
wp_maxi="$(latest_from_index "$KIWIX_BASE_WP" "wikipedia_en_all_maxi_" ".zim")"
wp_nopic="$(latest_from_index "$KIWIX_BASE_WP" "wikipedia_en_all_nopic_" ".zim")"
[ -n "$wp_maxi" ]  && dl_ts "${KIWIX_BASE_WP}${wp_maxi}" "$DEST_ROOT/kiwix/wikipedia"
[ -n "$wp_nopic" ] && dl_ts "${KIWIX_BASE_WP}${wp_nopic}" "$DEST_ROOT/kiwix/wikipedia"

# Nederlandstalige Wikipedia (maxi of nopic – neem wat beschikbaar is)
wp_nl="$(latest_from_index "$KIWIX_BASE_WP" "wikipedia_nl_all_maxi_" ".zim")"
[ -z "$wp_nl" ] && wp_nl="$(latest_from_index "$KIWIX_BASE_WP" "wikipedia_nl_all_nopic_" ".zim")"
[ -n "$wp_nl" ] && dl_ts "${KIWIX_BASE_WP}${wp_nl}" "$DEST_ROOT/kiwix/wikipedia"

# Wikivoyage (reizen)
wv_en="$(latest_from_index "$KIWIX_BASE_WV" "wikivoyage_en_all_maxi_" ".zim")"
[ -n "$wv_en" ] && dl_ts "${KIWIX_BASE_WV}${wv_en}" "$DEST_ROOT/kiwix/wikivoyage"

# Wikibooks (how-to/handboeken)
wb_en="$(latest_from_index "$KIWIX_BASE_WB" "wikibooks_en_all_maxi_" ".zim")"
[ -n "$wb_en" ] && dl_ts "${KIWIX_BASE_WB}${wb_en}" "$DEST_ROOT/kiwix/wikibooks"

# Kiwix Desktop (reader) – AppImage (x86_64)
# (versiepad kan wisselen; haal laatste uit /releases/)
KIWIX_APP_BASE="https://download.kiwix.org/release/kiwix-desktop/"
kiwix_app="$(latest_from_index "$KIWIX_APP_BASE" "Kiwix-desktop-x86_64" ".AppImage")"
[ -n "$kiwix_app" ] && dl_ts "${KIWIX_APP_BASE}${kiwix_app}" "$DEST_ROOT/kiwix"

# ---------- Meshtastic & tools ----------
echo "== Code & tooling =="

git_sync "https://github.com/meshtastic/firmware.git" "$DEST_ROOT/code/meshtastic-firmware"
git_sync "https://github.com/meshtastic/meshtastic-device.git" "$DEST_ROOT/code/meshtastic-device" || true
git_sync "https://github.com/ventoy/Ventoy.git" "$DEST_ROOT/code/ventoy" || true
git_sync "https://github.com/systemrescue/systemrescue-sources.git" "$DEST_ROOT/code/systemrescue" || true

# ---------- Offline kaarten ----------
echo "== OSM maps =="
# Geofabrik NL extract (laatste)
dl_ts "https://download.geofabrik.de/europe/netherlands-latest.osm.pbf" "$DEST_ROOT/osm"

# ---------- Metadata ----------
echo "== Metadata =="
{
  echo "Synctime: $DATE_STAMP"
  echo "Host: $(uname -a)"
  echo "Tools: $( { aria2c --version 2>/dev/null | head -n1 || echo 'aria2c:N/A'; }; { wget --version 2>/dev/null | head -n1 || echo 'wget:N/A'; } )"
} > "$DEST_ROOT/_meta/ABOUT_SYNC.txt"

echo "==== Done. Library at: $DEST_ROOT ===="
