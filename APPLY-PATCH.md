# Applying the BC-250 8-core telemetry patch

> **EXPERIMENTAL — USE AT YOUR OWN RISK.**
> This patch is the result of empirical reverse-engineering of one specific PMFW
> revision on a BC-250 / "cyan skillfish" APU with all eight physical cores
> unlocked. It is not official, not signed off by AMD, and not guaranteed to be
> correct on any other firmware, board, or silicon. It only touches the telemetry
> **read-out** path (it does not change any SMU power/clock/voltage command), so
> the worst realistic outcome is wrong telemetry numbers — but you apply it on
> your own responsibility. Keep the stock rollback handy (see below).

## Recommended: use the BC-250 CachyOS kernel (MastaG)

The telemetry and audio fixes are now packaged and maintained as a CachyOS
kernel by **MastaG** — [`MastaG/linux-cachyos-bc250`](https://github.com/MastaG/linux-cachyos-bc250).
It publishes `linux-cachyos-bc250` (+ headers) as a pacman repository with
automatic rebuilds on upstream updates and a stable package name across RC and
stable kernels. **Prefer it over a manual build.**

```ini
# /etc/pacman.conf
[bc250-cachyos]
SigLevel = Optional TrustAll
Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo
```

```bash
sudo pacman -Syy
sudo pacman -Syu linux-cachyos-bc250 linux-cachyos-bc250-headers
```

The build script and the standalone patch files that used to live in this repo
have been removed in favour of that maintained package.

The rest of this document is the **manual / advanced** module-replacement
procedure, kept as historical reference. The patches now live in MastaG's repo
(`patches/0001-bc250-8core-telemetry-gpu-activity.patch` and
`patches/0002-bc250-audio.patch`).

## What it does

On a BC-250 with 8 cores unlocked, the PMFW writes a **hybrid** Current metrics
table (116 bytes): `CoreFrequency[8]`, `CorePower[7]` (cores 1–7),
`CoreTemperature[2]` (cores 4–5), `C0Residency[7]`, no Gfxclk slot, and the same
aggregated tail as the stock six-core layout. The stock driver misreads the
per-core region and the Gfxclk field. This patch:

- Adds `SmuMetricsTable_hybrid_t` (with a `static_assert(sizeof == 116)`).
- Reads Gfxclk via the `GetGfxclkFrequency` SMU message (offset 0x44 is C0[6]).
- Auto-detects the physical core count and populates the per-core `gpu_metrics`
  arrays from the hybrid layout when 8 cores are present. Cores with no firmware
  slot stay at `0xFFFF` sentinel.
- Reports **GPU activity** (`average_gfx_activity` / `AMDGPU_PP_SENSOR_GPU_LOAD`)
  by sampling the `GRBM` `GUI_ACTIVE` bit, since cyan skillfish firmware publishes
  no GFX-activity field.
- Leaves all aggregate telemetry (GPU/SOC temperature, rail power, clocks) intact.

## Prerequisites

- CachyOS, kernel **7.1.3-2-cachyos** (Limine bootloader).
- The official CachyOS source tree (`cachyos-7.1.3-1.tar.gz` over `linux-7.1.3`).
- clang/LLVM (`CONFIG_CC_IS_CLANG=y`), `zstd`, `llvm-strip`, `llvm-objcopy`.

The patch is generated against the **official CachyOS cyan_skillfish source**
(round-trip verified: applying it to a fresh tarball extract reproduces the
deployed source byte-for-byte).

## 1. Apply

```bash
cd /path/to/cachyos-7.1.3-1
grep -c SmuMetrics_t drivers/gpu/drm/amd/pm/swsmu/smu11/cyan_skillfish_ppt.c   # stock, six-wide
patch -p1 < 0001-bc250-8core-telemetry-gpu-activity.patch   # from MastaG/linux-cachyos-bc250
```

Files touched (2):
- `drivers/gpu/drm/amd/pm/swsmu/smu11/cyan_skillfish_ppt.c`
- `drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu11_driver_if_cyan_skillfish.h`

## 2. Build (modules only)

```bash
make LLVM=1 -j"$(nproc)" modules
modinfo drivers/gpu/drm/amd/amdgpu/amdgpu.ko | grep -E '^srcversion|^vermagic'
```

## 3. Post-process (`CONFIG_DEBUG_INFO_BTF=y` requires removing `.BTF`)

```bash
K=drivers/gpu/drm/amd/amdgpu/amdgpu.ko
llvm-strip --strip-debug "$K"
llvm-objcopy --remove-section .BTF "$K"
zstd -19 -f "$K"
```

## 4. Install + rebuild initramfs (CachyOS / Limine)

```bash
MOD=/usr/lib/modules/7.1.3-2-cachyos/kernel/drivers/gpu/drm/amd/amdgpu
sudo cp amdgpu.ko.zst "$MOD/"
sudo depmod 7.1.3-2-cachyos
sudo limine-mkinitcpio            # HOOKS include 'kms' -> amdgpu baked into initramfs
sudo rebuild-pstate.py            # rebuilds initramfs-pstate + updates limine hash
sudo reboot
```

Verify the same module hash is in the initramfs as on disk, then after reboot:
```bash
cat /sys/module/amdgpu/srcversion
# Per-core telemetry is auto-detected (param reads N by default on an 8-core
# machine); verify the hybrid layout is active with: amdgpu_top
```

## 5. Module parameter (optional)

The driver **auto-detects** the physical core count at boot and selects the
8-core hybrid layout when 8 cores are present — no parameter is needed.

| Parameter | Default | Effect |
|---|---|---|
| `cs_eight_core_map` | off | Force the 8-core hybrid layout even when auto-detection would not pick it (off = auto-detect, on = force 8-core). |

Optional, for debugging/edge cases — add to the kernel command line:
```
amdgpu.cs_eight_core_map=1
```

## 6. Expected behaviour (8-core, auto-detected)

- `current_coreclk`: all 8 cores (~4050 MHz under load).
- `average_core_power`: cores 1–7 (~7 W/core under load); core 0 = sentinel (its
  power is in the aggregate CPU rail, `average_soc_power`).
- `temperature_core`: cores 4 and 5 only; the rest = `0xFFFF` (no individual sensor).
- `current_gfxclk`: via `GetGfxclkFrequency`.
- `average_gfx_activity` / GPU load: GFX busy % from `GRBM` `GUI_ACTIVE`.
- Aggregates (Gfx/SOC temperature, CPU/GPU rail power, clocks): reliable.

> `average_socket_power` (CurrentSocketPower @0x68) is an unreliable PMFW field on
> this firmware (it drops under load). Use `average_soc_power` (`Power[0]`, which is
> what `amdgpu_top` displays) or `hwmon` for package power.

## 7. Rollback

Keep a stock backup (e.g. `amdgpu.ko.zst.stock-safe`):
```bash
sudo cp "$MOD/amdgpu.ko.zst.stock-safe" "$MOD/amdgpu.ko.zst"
sudo depmod 7.1.3-2-cachyos && sudo limine-mkinitcpio && sudo rebuild-pstate.py
```

## Caveats

- The hybrid layout was mapped empirically on one machine/firmware revision. Other
  PMFW versions may shift offsets; auto-detection is keyed on physical core count
  (a 6-core BC-250 gets the stock layout, an 8-core one gets the hybrid layout).
  There is no runtime sanity check on the byte offsets yet.
- Read-path only: no power/clock/voltage control is altered; only the
  `GetGfxclkFrequency` query is added.
- See `README.md` for the full layout mapping and differential-proof data.

## Credits

GPU activity reporting, the hybrid-aware GFX-clock read fix, and the
DisplayPort spread-spectrum audio fix are contributed by **MastaG**. The physical
core-count auto-detection is contributed by **FilippoR**
([github.com/filippor](https://github.com/filippor)).
