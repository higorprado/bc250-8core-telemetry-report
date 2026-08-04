#!/usr/bin/env bash
#
# bc250-telemetry-kernel.sh
#
# Build a CachyOS kernel with the BC-250 telemetry patches, packaged as a
# SEPARATE kernel (linux-cachyos-bc250) that coexists with the stock kernel.
# One command: downloads the official CachyOS PKGBUILD, injects the patches,
# builds and installs. Roll back any time by booting the stock kernel.
#
# Patches applied by default:
#   0001  per-core telemetry + GPU activity (8-core hybrid SMU layout, gfxclk)
#   0002  DisplayPort spread-spectrum audio fix        (opt-in: --audio; 7.2 only)
#
# Usage:
#   ./bc250-telemetry-kernel.sh             # stable linux-cachyos, telemetry only
#   ./bc250-telemetry-kernel.sh --rc        # linux-cachyos-rc instead
#   ./bc250-telemetry-kernel.sh --audio     # also apply the DP audio fix (7.2 only)
#   ./bc250-telemetry-kernel.sh extra.patch # also apply an extra (3rd) patch
#   ./bc250-telemetry-kernel.sh --dry-run   # inject patches, verify they apply, skip the build
#   ./bc250-telemetry-kernel.sh --help
#
# Run as a NORMAL user (not root — makepkg refuses root).
# Requires: base-devel (makepkg), curl, zstd, and enough disk (~3 GB for the build).
#
set -Eeuo pipefail

VARIANT="${BC250_VARIANT:-linux-cachyos}"   # linux-cachyos (stable) | linux-cachyos-rc
APPLY_AUDIO="${BC250_AUDIO:-0}"             # 0 = skip audio (default); 1 = apply DP audio fix (0002, 7.2 only)
EXTRA_PATCH=""
DRY_RUN=0

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rc)      VARIANT="linux-cachyos-rc"; shift;;
    --stable)  VARIANT="linux-cachyos"; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --audio)    APPLY_AUDIO=1; shift;;
    --no-audio) APPLY_AUDIO=0; shift;;
    -h|--help) usage;;
    --*) echo "Unknown option: $1" >&2; exit 2;;
    *)  if [[ -n "$EXTRA_PATCH" ]]; then
          die "Only one extra patch is supported. Got: $1 and $EXTRA_PATCH"
        fi
        EXTRA_PATCH="$1"; shift;;
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

# ---- preflight --------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "Run as a normal user, not root (makepkg refuses root)."
for c in makepkg curl b2sum sed grep nproc realpath; do
  command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
done

# ---- setup build dir (before patch fetch so cleanup doesn't delete it) --------
log "Clean build directory: $BUILD_ROOT"
rm -rf -- "$BUILD_ROOT"
mkdir -p -- "$BUILD_ROOT"

# ---- locate telemetry patch -------------------------------------------------
# Bundled next to this script, else fetch to cache (OUTSIDE build dir so the
# cleanup above can't delete it).
if [[ ! -f "$TELEMETRY_PATCH" ]]; then
  log "Telemetry patch not bundled; fetching from GitHub"
  TELEMETRY_PATCH="${XDG_CACHE_HOME:-$HOME/.cache}/0001-bc250-8core-telemetry.patch"
  curl -fL "$PATCH_RAW_URL" -o "$TELEMETRY_PATCH" || die "Could not fetch telemetry patch."
fi
[[ -f "$TELEMETRY_PATCH" ]] || die "Telemetry patch missing: $TELEMETRY_PATCH"

PATCHES=("$TELEMETRY_PATCH")

# Optional: apply the DP spread-spectrum audio fix (patch 0002), bundled in
# the repo. Opt in with --audio (or BC250_AUDIO=1). 7.2 only.
AUDIO_PATCH="${SCRIPT_DIR}/../patches/0002-bc250-audio-dp-ss.patch"
if [[ "$APPLY_AUDIO" == "1" ]]; then
  [[ -f "$AUDIO_PATCH" ]] || die "Audio patch not found: $AUDIO_PATCH (use --no-audio to skip)"
  PATCHES+=("$(realpath "$AUDIO_PATCH")")
fi

if [[ -n "$EXTRA_PATCH" ]]; then
  [[ -f "$EXTRA_PATCH" ]] || die "Extra patch not found: $EXTRA_PATCH"
  PATCHES+=("$(realpath "$EXTRA_PATCH")")
fi

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
# Iterate in reverse so prepend (insert after opening paren) yields correct
# order: telemetry first, then extra, then existing entries.
for (( _i=${#PATCHES[@]}-1; _i>=0; _i-- )); do
  p="${PATCHES[$_i]}"
  pname="$(basename "$p")"
  [[ "$pname" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Patch filename unsafe: $pname"
  cp -- "$p" "./$pname"
  pb2="$(b2sum "$pname" | cut -d' ' -f1)"
  log "Injecting $pname (b2sum ${pb2:0:16}…)"
  sed -i "/^source=(\$/a\\  \"$pname\"" PKGBUILD
  sed -i "s/^b2sums=(/b2sums=('${pb2}'\\n /" PKGBUILD
done

# ---- guard against interactive kconfig prompts --------------------------------
# CachyOS's config occasionally contains invalid values (e.g. CONFIG_X=m for a
# bool symbol) that make 'make prepare' halt with a "Restart config" interactive
# prompt, blocking automated builds.  Insert a non-interactive 'olddefconfig'
# run before the existing 'make prepare' so every new/invalid symbol resolves to
# its default.  Harmless when the config is already clean.
log "Guarding against interactive kconfig prompts"
sed -i '/### Rewrite configuration/a\    yes "" | make "${BUILD_FLAGS[@]}" olddefconfig >/dev/null 2>&1 || true' PKGBUILD

log "Resulting package configuration"
makepkg --printsrcinfo 2>/dev/null | grep -E '^\s*(pkgbase|pkgver|pkgrel) = '

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
    for _p in "${PATCHES[@]}"; do
      _pname="$(basename "$_p")"
      if ( cd "${srcball%.tar.gz}" && patch -p1 --dry-run < "../$_pname" ); then
        log "$_pname APPLIES CLEANLY to ${srcball%.tar.gz} ✓"
      else
        die "$_pname does NOT apply cleanly — rework needed."
      fi
    done
  else
    log "(could not resolve source tarball via makepkg; skipping apply check)"
  fi
  log "--dry-run complete. PKGBUILD ready at: $PWD/PKGBUILD"
  log "Run without --dry-run to build and install."
  exit 0
fi

# ---- build ------------------------------------------------------------------
# Build only — do NOT install yet.  Separating build from install means the
# compiled .pkg.tar.* survives even if the install step fails or the user
# walks away.  No background keepalive: sudo is invoked twice, both explicit
# (once for build deps, once for the actual install).
log "Authenticating (sudo needed for build dependencies)"
sudo -v || die "This script needs sudo to install build dependencies."

log "Building $CUSTOM_PKGBASE (this takes ~30-50 min)"
PKGDEST="$BUILD_ROOT" makepkg --syncdeps --cleanbuild

# ---- install ----------------------------------------------------------------
# Install explicitly so the password prompt appears HERE, after the build —
# not buried inside makepkg where a timeout silently discards everything.
# If it fails, the packages are safe and the manual command is printed.
log "Installing built packages"
if ! sudo pacman -U "$BUILD_ROOT"/*.pkg.tar.*; then
  log "Install failed or cancelled. Packages are safe at: $BUILD_ROOT/"
  log "Install manually with: sudo pacman -U $BUILD_ROOT/*.pkg.tar.*"
  exit 1
fi

# Per-core telemetry is auto-detected at boot (the patched driver counts
# physical cores and selects the 8-core hybrid layout when 8 are present), so
# no kernel command-line parameter is required. The optional cs_eight_core_map=1
# remains available to force the 8-core layout for debugging.
log "Done. Installed $CUSTOM_PKGBASE."
log "Reboot and select 'linux-cachyos-bc250' in your bootloader."
log "Per-core telemetry and GPU activity are auto-detected at boot; verify with:"
log "  amdgpu_top   (current_coreclk across 8 cores; GPU usage)"
