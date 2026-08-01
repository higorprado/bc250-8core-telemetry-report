# Applying the BC-250 8-core telemetry patch

> **EXPERIMENTAL — USE AT YOUR OWN RISK.**
> This patch is the result of empirical reverse-engineering of one specific PMFW
> revision on a BC-250 / "cyan skillfish" APU with all eight physical cores
> unlocked. It is not official, not signed off by AMD, and not guaranteed to be
> correct on any other firmware, board, or silicon. It only touches the telemetry
> **read-out** path (it does not change any SMU power/clock/voltage command), so
> the worst realistic outcome is wrong telemetry numbers — but you apply it on
> your own responsibility. Keep the stock rollback handy (see below).

## What it does

On a BC-250 with 8 cores unlocked, the PMFW writes a **hybrid** Current metrics
table (116 bytes): `CoreFrequency[8]`, `CorePower[7]` (cores 1–7),
`CoreTemperature[2]` (cores 4–5), `C0Residency[7]`, no Gfxclk slot, and the same
aggregated tail as the stock six-core layout. The stock driver misreads the
per-core region and the Gfxclk field. This patch:

- Adds `SmuMetricsTable_hybrid_t` (with a `static_assert(sizeof == 116)`).
- Reads Gfxclk via the `GetGfxclkFrequency` SMU message (offset 0x44 is C0[6]).
- Populates the per-core `gpu_metrics` arrays from the hybrid layout, gated by a
  module parameter. Cores with no firmware slot stay at `0xFFFF` sentinel.
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
patch -p1 < 0001-bc250-8core-telemetry.patch
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
cat /sys/module/amdgpu/parameters/cs_eight_core_map
```

## 5. Module parameter (only one)

| Parameter | Default | Effect |
|---|---|---|
| `cs_eight_core_map` | off | Interpret the Current table as the 8-core hybrid layout and expose per-core telemetry. **Enable for per-core data.** |

Make it persistent via the Limine kernel command line (default boot entry):
```
amdgpu.cs_eight_core_map=1
```
With it off (default): aggregates only; per-core fields stay at the `0xFFFF` sentinel.

## 6. Expected behaviour (`cs_eight_core_map=1`)

- `current_coreclk`: all 8 cores (~4050 MHz under load).
- `average_core_power`: cores 1–7 (~7 W/core under load); core 0 = sentinel (its
  power is in the aggregate CPU rail, `average_soc_power`).
- `temperature_core`: cores 4 and 5 only; the rest = `0xFFFF` (no individual sensor).
- `current_gfxclk`: via `GetGfxclkFrequency`.
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
  PMFW versions may shift offsets; `cs_eight_core_map` is opt-in (default off) to
  mitigate this. There is no runtime sanity check yet.
- Read-path only: no power/clock/voltage control is altered; only the
  `GetGfxclkFrequency` query is added.
- See `README.md` for the full layout mapping and differential-proof data.
