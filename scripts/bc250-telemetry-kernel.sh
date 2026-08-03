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
log "Building and installing $CUSTOM_PKGBASE (this takes ~20-30 min)"
makepkg --syncdeps --install --cleanbuild

# ---- enable cs_eight_core_map=1 (per-core telemetry needs it) ---------------
# Per-core telemetry is gated by this module parameter (default off).
# Best-effort: auto-add for Limine; clear instructions otherwise.
ensure_eight_core_map() {
  local param='amdgpu.cs_eight_core_map=1'
  local limine=/boot/limine.conf grub=/etc/default/grub

  if [[ -f "$limine" ]]; then
    if sudo grep -q 'cs_eight_core_map' "$limine" 2>/dev/null; then
      log "cs_eight_core_map already present in $limine"
      return
    fi
    log "Adding $param to Limine kernel command lines (needs sudo)"
    # Append the param to every linux-protocol kernel path line that lacks it.
    # CachyOS Limine entries carry the cmdline on the 'path:' line of the kernel.
    if sudo sed -i "s#\(path:.*vmlinuz[^ ]*\)#\1 $param#g" "$limine" 2>/dev/null \
       && sudo grep -q 'cs_eight_core_map' "$limine" 2>/dev/null; then
      log "Added. Re-running limine entry tool to refresh hashes."
      command -v limine-mkinitcpio >/dev/null 2>&1 && sudo limine-mkinitcpio || true
      command -v rebuild-pstate.py >/dev/null 2>&1 && sudo rebuild-pstate.py || true
      return
    fi
    log "WARNING: could not auto-edit $limine safely."
  elif [[ -f "$grub" ]]; then
    if sudo grep -q 'cs_eight_core_map' "$grub" 2>/dev/null; then
      log "cs_eight_core_map already present in $grub"
      return
    fi
    log "Adding $param to GRUB_CMDLINE_LINUX_DEFAULT (needs sudo)"
    sudo sed -i "s#\(^GRUB_CMDLINE_LINUX_DEFAULT=.*\)\"#\1 $param\"#" "$grub" 2>/dev/null \
      && sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null && return
    log "WARNING: could not auto-edit $grub safely."
  else
    log "No Limine or GRUB config detected."
  fi

  cat >&2 <<EOF

  ── MANUAL STEP REQUIRED ──────────────────────────────────────────
  Per-core telemetry needs  $param  on the kernel command line.
  Add it to your bootloader config and rebuild the bootloader, e.g.:

    Limine : append "$param" to the kernel path line in /boot/limine.conf,
             then: sudo limine-mkinitcpio && sudo rebuild-pstate.py
    GRUB   : add "$param" to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,
             then: sudo grub-mkconfig -o /boot/grub/grub.cfg
  ──────────────────────────────────────────────────────────────────
EOF
}
ensure_eight_core_map

log "Done. Installed $CUSTOM_PKGBASE."
log "Reboot and select 'linux-cachyos-bc250' in your bootloader,"
log "then check: cat /sys/module/amdgpu/parameters/cs_eight_core_map  (expect: Y)"
