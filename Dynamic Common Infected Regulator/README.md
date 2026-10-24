# [L4D2] Common Infected Regulator - Dynamic

**Version:** 1.2.0
**Author:** monnie
**Source:** [gitlab.com/iqrar99/l4d2-plugins](https://gitlab.com/iqrar99/l4d2-plugins)
**Requires:** SourceMod 1.11+ and [Left 4 DHooks Direct](https://forums.alliedmods.net/showthread.php?p=2684897)

Scales common infected pressure for servers with more than 4 survivors. The more living survivors there are, the larger the common limit and the hordes, using the map's own Director values as the starting point instead of fixed numbers.

---

## How it works

The plugin counts **living survivors** (team 2, bots included, incapacitated still counts) and computes a multiplier:

```
multiplier = 1.0 + (living_survivors - 4) * percent_per_survivor / 100
             capped at commonregulator_max_multiplier
```

It then applies that multiplier through two paths:

| Path | What it scales | How |
|---|---|---|
| **Director hook** | `CommonLimit`, `MegaMobSize`, `MobSpawnSize`, `MobMinSize`, `MobMaxSize`, `MobMaxPending`, `cm_CommonLimit` | Hooks `L4D_OnGetScriptValueInt` (`CDirector::GetScriptValueInt`) and scales the value the Director reads, whether it comes from the map's `DirectorOptions` or the cvar default. Nothing is written anywhere. |
| **Cvar fallback** | `z_mob_spawn_min_size`, `z_mob_spawn_max_size` (regular / natural hordes) | Vanilla maps read regular mob sizes straight from these cvars, bypassing the hook. The plugin writes the scaled value into the cvar while remembering the real ("base") value, and writes the base back on map end, plugin unload, or when scaling no longer applies. |

Rules applied to every value:
- Negative values (e.g. `-1` = "not used") and `0` (deliberately disabled by the map) are never changed.
- No value goes above `commonregulator_value_cap`. If the map's own value is already above the cap, the map's value is kept: the plugin only ever increases, never shrinks the map's tuning.

### Default scaling (20% per survivor, max 2.5x)

| Living survivors | Multiplier | CommonLimit (30) | MegaMobSize (50) | Mob min/max (10/30) |
|---|---|---|---|---|
| 4 or fewer | 1.0x | 30 | 50 | 10 / 30 |
| 5 | 1.2x | 36 | 60 | 12 / 36 |
| 6 | 1.4x | 42 | 70 | 14 / 42 |
| 7 | 1.6x | 48 | 80 | 16 / 48 |
| 8 | 1.8x | 54 | 90 | 18 / 54 |
| 10 | 2.2x | 66 | 110 | 22 / 66 |
| 12 | 2.5x (capped) | 75 | 120 (capped) | 25 / 75 |

The numbers in parentheses are vanilla defaults; custom maps may use different base values.

---

## Installation

1. Install Left 4 DHooks Direct (plugin + gamedata) if it is not already installed.
2. Compile `l4d2_dynamic_common_regulator.sp` and put `l4d2_dynamic_common_regulator.smx` in `addons/sourcemod/plugins/`.
3. Make sure **only one** build of this plugin is in the `plugins` folder. Two builds loaded together will scale twice.
4. Change map (or restart the server).
5. Config is generated at `cfg/sourcemod/l4d2_dynamic_common_regulator.cfg`.

> **Upgrading from 1.1.0 or earlier:** older builds used `cfg/sourcemod/cge_l4d2_commonregulator.cfg`. That file is no longer read. Copy any changed values into the new config, then delete the old one.

---

## ConVars

| ConVar | Default | Range | Description |
|---|---|---|---|
| `commonregulator` | `1` | 0–1 | Master switch. Turning it off restores the mob cvars to their base values. |
| `commonregulator_percent_per_survivor` | `20` | 0–100 | Increase per living survivor above 4. Decimals are allowed (e.g. `12.5`). |
| `commonregulator_max_multiplier` | `2.5` | 1.0–10.0 | Hard ceiling for the multiplier, regardless of survivor count. Protects against entity/edict overload. |
| `commonregulator_value_cap` | `120` | 0–1000 | Maximum value any scaled setting may reach. `0` = no cap. |
| `commonregulator_scale_mob_cvars` | `1` | 0–1 | Enables the cvar fallback for regular horde sizes. |
| `commonregulator_debug` | `0` | 0–1 | Prints Director key changes (`original -> scaled`) to the server console. |
| `commonregulator_version` | — | — | Plugin version (read-only). |

All changes take effect immediately; no map change needed.

---

## Commands

| Command | Access | Description |
|---|---|---|
| `sm_cge_debug` | Admin (`b` / generic) | Shows living vs cached survivor count, multiplier, cvar settings, the last `original -> scaled` value per Director key, and `base -> current` for each mob cvar. |
| `sm_l4dd_detours` | Admin (`z`) | *(Left 4 DHooks)* Lists active detours and which plugin uses each one. |
| `sm_l4dd_reload` | Admin (`z`) | *(Left 4 DHooks)* Rescans plugins and re-enables detours. Use after loading the plugin mid-map. |

---

## Debugging steps

Run these in order. If a step fails, see the matching entry in **Troubleshooting**.

**1. Plugin loaded with the right version**
```
sm plugins list
sm_cge_debug
```
Expected: the plugin is listed without errors and the debug header shows the current version (`DEBUG v1.2.0`).

**2. Hook is attached to the Director**
```
sm_l4dd_detours
```
Expected:
```
l4d2_dynamic_common_regulator.smx  > L4D_OnGetScriptValueInt  (CDirector::GetScriptValueInt)
```
If it says `L4D2_OnGetScriptValueInt (ScriptVM)`, an old build (1.1.0 or earlier) is running.

**3. Survivor count and multiplier**
Add bots past 4 survivors. Expected console output, one line per change:
```
[CommonRegulator] Enabled=1 Survivors=8 multiplier=1.79x
```
(`1.79x` is `1.80x` shown truncated; see Troubleshooting.)

**4. Director values are scaled**
```
commonregulator_debug 1
```
Leave the saferoom or trigger a horde. Expected:
```
[CommonRegulator] Director key=CommonLimit original=30 -> scaled=54 (multiplier=1.79x)
[CommonRegulator] Director key=MegaMobSize original=50 -> scaled=90 (multiplier=1.79x)
```

**5. Mob cvar fallback**
```
sm_cge_debug
```
Expected at the bottom (8 survivors, vanilla):
```
z_mob_spawn_min_size : base=10 -> current=18
z_mob_spawn_max_size : base=30 -> current=54
```
Kick bots back to 4: `current` must return to `base`. After a map change, `current` must equal `base` until survivors are counted again.

**6. Gameplay check**
During a large horde, compare `commonregulator 1` with `commonregulator 0`. With the plugin on, noticeably more commons should be alive at once.

When done, set `commonregulator_debug 0` again.

---

## Troubleshooting

### Nothing is ever scaled; every key says "not requested"
- **Multiplier is 1.0.** With 4 or fewer living survivors the hook exits immediately by design and records nothing. Check that `sm_cge_debug` shows more than 4 living survivors.
- **Wrong forward / old build.** `sm_l4dd_detours` shows `L4D2_OnGetScriptValueInt (ScriptVM)`. That forward fires on the VScript VM value getter, not on Director lookups, so it never sees these keys. Recompile from the current source and replace the `.smx`.
- **Detour not enabled yet.** Left 4 DHooks only detours forwards that a loaded plugin uses, and rescans on map change. After loading the plugin mid-map, run `sm_l4dd_reload` or change map.
- **Outdated Left 4 DHooks gamedata.** After an L4D2 game update, signatures can break and detours fail silently or log errors. Update Left 4 DHooks and check `addons/sourcemod/logs/errors_*.log`.

### Some keys stay "not requested" while `CommonLimit` works
Normal. Each key is only read when the Director needs it:
- `MegaMobSize`: panic events, car alarms, finales.
- `cm_CommonLimit`, `MobMaxPending`: only in modes or maps that define them. `-1` and `0` are left unchanged by design.
- `MobSpawnSize`, `MobMinSize`, `MobMaxSize`: on vanilla maps regular hordes read the cvars directly, which is why the cvar fallback exists. These keys only show up on maps whose scripts request them.

Debug data is reset on every map change, so keys reappear only after the Director asks again.

### Regular hordes are not bigger
- Check that `commonregulator_scale_mob_cvars` is `1` and that `sm_cge_debug` shows `current` above `base`.
- `CommonLimit` caps how many commons can be alive at once. If `commonregulator_value_cap` is low, both the limit and the mob size are capped together.
- Horde **frequency** is not scaled, only size. Pacing cvars (`z_mob_spawn_*_interval`) and the map's own scripts still decide how often hordes come.
- A map's VScript can set `z_mob_spawn_*` itself. The plugin treats that as a new base and rescales it, but a script that keeps rewriting the cvar every tick will fight the plugin.

### Hordes are far too big or the server lags
- Two builds of the plugin are loaded and scaling twice. Check `sm plugins list` and `sm_l4dd_detours` for duplicates.
- Another plugin also modifies the same Director values or `z_*` cvars (difficulty or "more zombies" plugins). Multipliers stack.
- Lower `commonregulator_max_multiplier` or `commonregulator_value_cap` to match what the host machine can handle.

### Mob cvars stay scaled after the plugin is removed
The plugin restores base values on map end and on unload. If the server crashed instead of unloading normally, the scaled value can remain until the next config execution. Restart the server or re-execute `server.cfg`.

### Multiplier fluctuates during play
By design, only **living** survivors count. A death lowers the multiplier until the survivor is rescued or defibbed. Bots taking over for idle players still count as one living survivor.

### Multiplier shows `1.79x` instead of `1.80x`
Display only. The float is stored as 1.7999999…, and SourceMod's `%.2f` truncates instead of rounding. The scaled values are still correct (`RoundToNearest(30 * 1.7999999) = 54`).

### `sm_cge_debug` says "You do not have access"
The command is admin-only (generic flag) since 1.2.0. Run it from the server console or with an admin account.

### Cvar changes in the config file have no effect
Make sure you are editing `cfg/sourcemod/l4d2_dynamic_common_regulator.cfg`, not the old `cge_l4d2_commonregulator.cfg` from 1.1.0 or earlier.

---

## Changelog

**1.2.0**
- **Fixed:** hook moved from `L4D2_OnGetScriptValueInt` (ScriptVM) to `L4D_OnGetScriptValueInt` (CDirector). Earlier versions never scaled anything. The hook now returns `Plugin_Handled` so the override is applied.
- Added cvar fallback for regular horde sizes (`z_mob_spawn_min_size` / `z_mob_spawn_max_size`) with base tracking and automatic restore, plus `commonregulator_scale_mob_cvars`.
- Double-scale guard between the hook and the cvar fallback.
- Added multiplier ceiling and value cap.
- Event filtering and debounced recount; commons dying no longer create timers.
- Added defib, bot replace and disconnect handling, plus a 3-second safety recount.
- Fast path in the hook, StringMap key lookup, cached cvars.
- Debug output behind `commonregulator_debug`; `sm_cge_debug` is admin-only.
- Removed `FCVAR_PLUGIN`; percent is now a real float.
- Config file renamed to `l4d2_dynamic_common_regulator.cfg`.

**1.1.0**
- Hooked `L4D2_OnGetScriptValueInt`; Director values were never actually scaled.