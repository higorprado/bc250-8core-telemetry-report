# BC-250 (cyan skillfish) SMU metrics layout with 8 cores unlocked

This documents the actual byte layout the SMU firmware (PMFW) writes into the metrics
table of a BC-250 / Steam-Deck-derivate APU ("cyan skillfish") when all eight physical
cores are enabled, and how it differs from both the stock six-core struct and the
community "eight-core" patches. It is the result of a differential probe (offlining
cores one group at a time and reading the raw buffer). Raw data is included inline.

## Driver patch (experimental)

A driver patch that turns the layout below into working per-core telemetry is in
[`patches/0001-bc250-8core-telemetry.patch`](patches/0001-bc250-8core-telemetry.patch),
with build/install instructions in [`APPLY-PATCH.md`](APPLY-PATCH.md).

> **EXPERIMENTAL — USE AT YOUR OWN RISK.** The mapping is empirical and specific
to one PMFW revision; it has no runtime sanity check and is not endorsed by AMD.
It only modifies the telemetry **read-out** path (no power/clock/voltage control is
changed), so the worst realistic outcome is wrong telemetry numbers — but you apply
it at your own responsibility. Read `APPLY-PATCH.md` fully and keep the stock
rollback handy.

## Hardware and context

- APU: AMD "cyan skillfish" (Van Gogh / Aerith family), originally 6 physical cores.
- 8 cores unlocked via a BIOS/core-presence patch (persistent across cold boot).
  After unlock: core_ids 0-7, `nproc=16` (SMT).
- Driver: `amdgpu` swsmu, `cyan_skillfish_ppt.c`. Kernel 7.1.3 (CachyOS).
- Topology: physical core N = cpu(2N) + cpu(2N+1). Core 0 (cpu0) cannot be offlined
  (boot cpu); cores 1-7 can be taken offline at runtime via Linux CPU hotplug.

## The problem

The driver defines two metrics structs:

```c
/* Stock, six cores — known-correct layout */
typedef struct SmuMetricsTable_t {
    uint16_t CoreFrequency[6];     // 0x00
    uint32_t CorePower[6];         // 0x0C
    uint16_t CoreTemperature[6];   // 0x24
    uint16_t L3Frequency[2];       // 0x30
    uint16_t L3Temperature[2];     // 0x34
    uint16_t C0Residency[6];       // 0x38
    uint16_t GfxclkFrequency;      // 0x44
    uint16_t GfxTemperature;       // 0x46
    uint16_t SocclkFrequency;      // 0x48  ... (aggregated tail to 0x72)
    ...
} SmuMetricsTable_t;  // sizeof = 116
```

Some initial community patches assumed the firmware expands every per-core array to `[8]` and
introduced `SmuMetricsTable8_t` (CoreFrequency[8], CorePower[8], CoreTemperature[8], ...).
On this machine that assumption is **wrong**: reading the buffer as `SmuMetricsTable8_t`
produces garbage per-core values and breaks the aggregated tail. The aggregated telemetry
(GPU/SOC temperature, socket power, memory clocks) keeps working because it sits at the
same offsets, but per-core frequency/power/temperature are unusable.

## Method: differential core-offline probe

The firmware keeps reporting all slots regardless of Linux online/offline state, but the
**value** of an offlined core drops (it is not executing). So: offline a known group of
cores, put the online cores under load, dump the raw metrics buffer, and see which slot
goes low. A 3-bit code per core identifies it in three rounds; a fourth round (D) is the
complement of A and validates by symmetry.

Rounds (cores offlined → cores that remain online and loaded):

| round | offlined cores | online (loaded) |
|---|---|---|
| A | 4,5,6,7 | 0,1,2,3 |
| B | 2,3,6,7 | 0,1,4,5 |
| C | 1,3,5,7 | 0,2,4,6 |
| D | 1,2,3 | 0,4,5,6,7 |

The raw buffer was dumped with a small module param (`print_hex_dump`, ~1 dump / 5 s).
Each round stresses only the online cores (≈4 cores), keeping the SoC well under throttle.

## Discovery: the firmware uses a hybrid layout

The table is still 116 bytes (same total as six-wide). The firmware redistributed the
per-core arrays **inside the same 48-byte window (0x00-0x2F)** and pinned L3 and the whole
aggregated tail at the **same offsets** as the six-core struct. That is why every anchor
(Socclk=1254 @0x48, Dclk=1111 @0x4C, Memclk=450 @0x4E, VDDCR_GFX voltage=699 @0x54,
GPU-rail power=4570 @0x64, socket power @0x68) matched from the start — the tail never moved.

Mapping (six-core struct → actual 8-core firmware layout):

| field | six-core offset [count] | 8-core offset [count] | change |
|---|---|---|---|
| CoreFrequency | 0x00 [6] | 0x00 **[8]** | +2 cores (6,7) |
| CorePower | 0x0C [6] | 0x10 **[7]** | shifted +4; now cores 1-7 (core 0 dropped) |
| CoreTemperature | 0x24 [6] | **0x2C [2]** | reduced to 2 (cores 4,5) |
| L3Frequency | 0x30 [2] | 0x30 [2] | same (pinned) |
| L3Temperature | 0x34 [2] | 0x34 [2] | same (pinned) |
| C0Residency | 0x38 [6] | 0x38 **[7]** | +1 (core 6; takes 0x44) |
| GfxclkFrequency | 0x44 | **gone** | 0x44 is now C0[6] |
| GfxTemperature | 0x46 | 0x46 | same |
| Socclk … Spare | 0x48-0x72 | 0x48-0x72 | identical tail |

Byte budget of the pre-L3 window (0x00-0x2F = 48 bytes in both):
- six-core: freq[6]=12 + power[6]=24 + temp[6]=12 = **48**
- 8-core: freq[8]=16 + power[7]=28 + temp[2]=4 = **48**

Frequency grew +4 and power grew +4; temperature shrank -8 to keep L3 pinned at 0x30.

### Per-core coverage is not uniform

The arrays do **not** all cover the same cores:

| array | count | cores covered |
|---|---|---|
| CoreFrequency | 8 | 0-7 (all) |
| CorePower | 7 | 1-7 (core 0 has no slot) |
| CoreTemperature | 2 | 4 and 5 only |
| C0Residency | 7 | 0-6 (core 7 has no slot) |

- **Core 0 power** is not in a per-core slot; it is folded into the CPU rail aggregate
  (`Power[0]` @0x60). Residual = rail − Σ(online per-core powers) ≈ 7.5-8.0 W across all
  rounds, consistent with one loaded core. (Core 0 cannot be offlined, so it cannot be
  separated from uncore.)
- **Core temperature exists only for cores 4 and 5.** The six-core `CoreTemperature[6]`
  occupied 0x24-0x2F; the power expansion (to hold cores 6,7) overwrote 0x24-0x2B, leaving
  only the last two slots (0x2C, 0x2E = cores 4,5). The firmware did not redesign the
  temperature array — it let power eat the first four slots.
- **GfxclkFrequency has no slot** (0x44 became C0[6]). The GPU clock must be read via the
  `GetGfxclkFrequency` SMU message instead of the table.

## Proof (differential, round-by-round)

H = slot high (core online+loaded), L = slot low (core offlined). Power slots:

| slot | A (off 4567) | B (off 2367) | C (off 1357) | D (off 123) | → core |
|---|---|---|---|---|---|
| 0x10 | H | H | L | L | 1 |
| 0x14 | H | L | H | L | 2 |
| 0x18 | H | L | L | L | 3 |
| 0x1C | L | H | H | H | 4 |
| 0x20 | L | H | L | H | 5 |
| 0x24 | L | L | H | H | 6 |
| 0x28 | L | L | L | H | 7 |

Each slot's H/L pattern across rounds matches exactly one core's online/offline pattern.
No slot is high in all four rounds → core 0 (always online) has no power slot. C0 slots
(0x38-0x44) map identically (0x38=c0 … 0x44=c6). Frequency (0x00-0x0F) is high exactly
for online cores in every round.

Temperature slots 0x2C/0x2E track cores 4 and 5: 0x2C is low only in A (core 4 offlined);
0x2E is low in A and C (core 5 offlined). This matches the six-core positional meaning
(CoreTemperature[4]=core4, CoreTemperature[5]=core5) — two independent methods agree.

L3 fields (0x30/0x32 freq, 0x34/0x36 temp) respond to the two core groups {0,1,2,3} and
{4,5,6,7}: 0x32 (group {4-7} L3 frequency) drops to idle only in round A (the only round
where cores 4-7 are all offlined), and 0x34/0x36 temperatures swap hot/cold between A
(group 0-3 loaded) and D (group 4-7 loaded).

## What works and what the firmware does not provide

Available per-core after the unlock (8 cores):
- **Frequency:** all 8 cores.
- **Power:** cores 1-7 (core 0 only as a rail residual).
- **C0 residency:** cores 0-6 (not exposed in `gpu_metrics_v2_2` anyway).
- **Temperature:** cores 4 and 5 only. Cores 0,1,2,3,6,7 have no individual temperature
  sensor slot in this layout.

Aggregated telemetry (tail) is intact and identical to the six-core offsets.

For cores without data, the correct marker is the `0xFFFF` sentinel (the kernel's
`smu_cmn_init_soft_gpu_metrics` already memsets to 0xFF; tools treat 0xFFFF as "no data").
Using 0 is wrong — it would be read as a real 0 MHz / 0 °C / 0 mW and confuse fan/undervolt
tooling.

## Caveats

- The layout was mapped empirically on one machine/firmware revision. Other BC-250 firmware
  versions may differ. Frequency/power/C0/temperature labels for the L3 and group fields
  (0x30-0x36) are inferred from value range + grouping behaviour + six-core struct position,
  not from firmware documentation.
- "CCX" (core complex) grouping is inferred from the {0-3}/{4-7} behaviour, not confirmed
  by published architecture docs.

## Raw data — Current table (0x00-0x73), four probe rounds

Little-endian, 16 bytes per line. `k10` is the k10temp Tctl die temperature (millicelsius)
during each round.

```
[A] offlined cores 4,5,6,7 (online 0,1,2,3)   k10 ~76 C
0000: 0fd2 0fd2 0fd2 0fd2 05c0 05c0 05c0 05c0
0010: 1e66 0000 1e2c 0000 1db4 0000 0003 0000
0020: 0004 0000 0003 0000 0005 0000 117b 1469
0030: 0fd2 05c0 16c1 12a7 0064 0064 0064 0064
0040: 0002 0002 0002 13ba 04e6 0000 0457 01c2
0050: 051a 0000 02bb 0000 5bae 0000 1981 0000
0060: 77c2 0000 11da 0000 eeb2 0000 1117 1117
0070: 0000 0000

[B] offlined cores 2,3,6,7 (online 0,1,4,5)   k10 ~71 C
0000: 0fd2 0fd2 0708 0708 0fd2 0fd2 0708 0708
0010: 1d16 0000 0004 0000 0004 0000 1e05 0000
0020: 1e02 0000 0004 0000 0004 0000 19e1 1b0d
0030: 0fd2 0fd2 13d3 13ec 0064 0064 0002 0002
0040: 0064 0064 0002 12d9 04e6 0000 0457 01c2
0050: 0520 0000 02bb 0000 5bae 0000 1981 0000
0060: 7855 0000 11da 0000 ee28 0000 1036 0fd2
0070: 0000 0000

[C] offlined cores 1,3,5,7 (online 0,2,4,6)   k10 ~73 C
0000: 0fd2 0708 0fd2 0708 0fd2 0708 0fd2 0708
0010: 0003 0000 1aea 0000 0003 0000 1d83 0000
0020: 0003 0000 1def 0000 0003 0000 1bbc 1162
0030: 0fd2 0fd2 1450 1469 0064 0002 0064 0002
0040: 0064 0002 0064 11df 04e6 0000 0457 01c2
0050: 0520 0000 02bb 0000 599d 0000 1981 0000
0060: 759e 0000 11da 0000 ec56 0000 1036 0feb
0070: 0000 0000

[D] offlined cores 1,2,3 (online 0,4,5,6,7)   k10 ~78 C   [complement of A]
0000: 0fd2 0708 0708 0708 0fd2 0fd2 0fd2 0fd2
0010: 0005 0000 0004 0000 0005 0000 1e6a 0000
0020: 1dcc 0000 1db9 0000 1e83 0000 1d7e 1c6b
0030: 0fd2 0fd2 1450 1725 0064 0002 0002 0002
0040: 0064 0064 0064 1405 04e6 0000 0457 01c2
0050: 0526 0000 02bb 0000 726e 0000 1c56 0000
0060: 96e7 0000 13d6 0000 1036 0001 1149 10fe
0070: 0000 0000
```

Reading the raw data: `0fd2`=4050 MHz (loaded core frequency), `05c0`/`0708`=1472/1800
(idle/offlined), power slots are the u32 pairs at 0x10-0x28 (high ~7700 mW when loaded,
~3-5 mW when offlined), C0 at 0x38-0x44 (100 when loaded, 2 when offlined).
