#!/usr/bin/env bash
#
# bc250-telemetry-kernel.sh
#
# Build a CachyOS kernel with the BC-250 8-core telemetry patch, packaged as a
# SEPARATE kernel (linux-cachyos-bc250) that coexists with the stock kernel.
# One command: downloads the official CachyOS PKGBUILD, injects the patch,
# builds and installs. Roll back any time by booting the stock kernel.
#
# Usage:
#   ./bc250-telemetry-kernel.sh             # stable linux-cachyos, telemetry patch
#   ./bc250-telemetry-kernel.sh --rc        # linux-cachyos-rc instead
#   ./bc250-telemetry-kernel.sh extra.patch # also apply an extra patch (e.g. audio)
#   ./bc250-telemetry-kernel.sh --dry-run   # inject patch, verify it applies, skip the build
#   ./bc250-telemetry-kernel.sh --help
#
# Run as a NORMAL user (not root — makepkg refuses root).
# Requires: base-devel (makepkg), curl, zstd, and enough disk (~3 GB for the build).
#
set -Eeuo pipefail

VARIANT="${BC250_VARIANT:-linux-cachyos}"   # linux-cachyos (stable) | linux-cachyos-rc
EXTRA_PATCH=""
DRY_RUN=0

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rc)      VARIANT="linux-cachyos-rc"; shift;;
    --stable)  VARIANT="linux-cachyos"; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    --*) echo "Unknown option: $1" >&2; exit 2;;
    *)  EXTRA_PATCH="$1"; shift;;
  esac
done

CUSTOM_SUFFIX="cachyos-bc250"
CUSTOM_PKGBASE="linux-${CUSTOM_SUFFIX}"
RAW_BASE="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/${VARIANT}"
BUILD_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/${CUSTOM_PKGBASE}-build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Telemetry patch: bundled next to this script, else fetch from the repo.
TELEMETRY_PATCH="${SCRIPT_DIR}/../patches/0001-bc250-8core-telemetry.patch"
PATCH_RAW_URL="https://raw.githubusercontent.com/higorprado/bc250-8core-telemetry-report/main/patches/0001-bc250-8core-telemetry.patch"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- preflight --------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "Run as a normal user, not root (makepkg refuses root)."
for c in makepkg curl b2sum sed grep nproc realpath; do
  command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
done

if [[ ! -f "$TELEMETRY_PATCH" ]]; then
  log "Telemetry patch not bundled; fetching from GitHub"
  mkdir -p "$BUILD_ROOT"
  TELEMETRY_PATCH="${BUILD_ROOT}/0001-bc250-8core-telemetry.patch"
  curl -fL "$PATCH_RAW_URL" -o "$TELEMETRY_PATCH" || die "Could not fetch telemetry patch."
fi
[[ -f "$TELEMETRY_PATCH" ]] || die "Telemetry patch missing: $TELEMETRY_PATCH"

PATCHES=("$TELEMETRY_PATCH")
if [[ -n "$EXTRA_PATCH" ]]; then
  [[ -f "$EXTRA_PATCH" ]] || die "Extra patch not found: $EXTRA_PATCH"
  PATCHES+=("$(realpath "$EXTRA_PATCH")")
fi

# ---- setup build dir --------------------------------------------------------
log "Clean build directory: $BUILD_ROOT"
rm -rf -- "$BUILD_ROOT"
mkdir -p -- "$BUILD_ROOT"
cd -- "$BUILD_ROOT"

log "Downloading ${VARIANT} PKGBUILD + config"
curl -fL --retry 3 -o PKGBUILD "${RAW_BASE}/PKGBUILD"
curl -fL --retry 3 -o config   "${RAW_BASE}/config"

# Fail loudly if CachyOS changed the PKGBUILD structure we rely on.
[[ $(grep -c '^pkgbase="linux-\$_pkgsuffix"$' PKGBUILD) -eq 1 ]] || \
  die 'Expected pkgbase="linux-$_pkgsuffix" exactly once in PKGBUILD.'
[[ $(grep -c '^source=($' PKGBUILD) -eq 1 ]] || die 'Expected source=( exactly once.'
[[ $(grep -c '^b2sums=(' PKGBUILD) -eq 1 ]] || die 'Expected b2sums=( exactly once.'

# ---- rename package so it coexists with stock ------------------------------
log "Renaming kernel package to $CUSTOM_PKGBASE"
sed -i \
  "s/^pkgbase=\"linux-\\\$_pkgsuffix\"\$/_pkgsuffix=\"${CUSTOM_SUFFIX}\"\\npkgbase=\"linux-\\\$_pkgsuffix\"/" \
  PKGBUILD

# ---- inject patches into source=() and b2sums=() ---------------------------
for p in "${PATCHES[@]}"; do
  pname="$(basename "$p")"
  [[ "$pname" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Patch filename unsafe: $pname"
  cp -- "$p" "./$pname"
  pb2="$(b2sum "$pname" | cut -d' ' -f1)"
  log "Injecting $pname (b2sum ${pb2:0:16}…)"
  sed -i "/^source=(\$/a\\  \"$pname\"" PKGBUILD
  sed -i "s/^b2sums=(/b2sums=('${pb2}'\\n /" PKGBUILD
done

log "Resulting package configuration"
grep -E '^(_pkgsuffix=|pkgbase=|_major=|_minor=|_rcver=|_srctag=|pkgver=|pkgrel=)' PKGBUILD | tail -n 10

# ---- import the kernel's PGP signing key (makepkg verifies source .asc) --------
# CachyOS signs the kernel tarball; without the key makepkg aborts at verify().
log "Ensuring kernel signing key is present in keyring"
mapfile -t _pgpkeys < <(awk '/^validpgpkeys=\(/,/^\)/' PKGBUILD | grep -oE '[0-9A-F]{40}' | sort -u)
for _k in "${_pgpkeys[@]}"; do
  if gpg --list-keys "$_k" >/dev/null 2>&1; then continue; fi
  gpg --recv-keys "$_k" 2>/dev/null \
    || gpg --keyserver keyserver.ubuntu.com --recv-keys "$_k" 2>/dev/null \
    || log "WARNING: could not import PGP key $_k"
done

# ---- dry-run: verify the patch applies cleanly to the downloaded source ------
if [[ $DRY_RUN -eq 1 ]]; then
  log "--dry-run: verifying the patch applies to the source"
  # Resolve the source tarball URL via makepkg (expands ${_srcname} etc.).
  srcurl="$(makepkg --printsrcinfo 2>/dev/null \
            | grep -oE 'https://[^"]+cachyos-[0-9][^"/]+\.tar\.gz' | head -1)"
  if [[ -n "$srcurl" ]]; then
    srcball="$(basename "$srcurl")"
    log "Downloading $srcball"
    curl -fL --retry 2 -o "$srcball" "$srcurl"
    tar -xzf "$srcball"
    ( cd "${srcball%.tar.gz}" && patch -p1 --dry-run < "../$pname" ) \
      && log "PATCH APPLIES CLEANLY to ${srcball%.tar.gz} ✓" \
      || die "Patch does NOT apply cleanly — rework needed."
  else
    log "(could not resolve source tarball via makepkg; skipping apply check)"
  fi
  log "--dry-run complete. PKGBUILD ready at: $PWD/PKGBUILD"
  log "Run without --dry-run to build and install."
  exit 0
fi

# ---- build + install --------------------------------------------------------
# Prime sudo up front so the password is entered NOW (while the user is
# attentive), not after a ~30 min build. A background loop keeps the sudo
# timestamp alive across the build so makepkg's internal sudo calls
# (--syncdeps, --install) need no further prompt. Same pattern yay/paru use.
log "Authenticating now (sudo password needed for install later)"
sudo -v || die "This script needs sudo to install the built kernel."
( while true; do sudo -n true 2>/dev/null || break; sleep 60; done ) &
_BC250_SUDO_KEEP=$!
trap 'kill "$_BC250_SUDO_KEEP" 2>/dev/null || true' EXIT

log "Building and installing $CUSTOM_PKGBASE (this takes ~20-30 min)"
makepkg --syncdeps --install --cleanbuild

# Per-core telemetry is auto-detected at boot (the patched driver counts
# physical cores and selects the 8-core hybrid layout when 8 are present), so
# no kernel command-line parameter is required. The optional cs_eight_core_map=1
# remains available to force the 8-core layout for debugging.
log "Done. Installed $CUSTOM_PKGBASE."
log "Reboot and select 'linux-cachyos-bc250' in your bootloader."
log "Per-core telemetry is auto-detected at boot; verify with:"
log "  amdgpu_top   (look for current_coreclk across 8 cores)"
