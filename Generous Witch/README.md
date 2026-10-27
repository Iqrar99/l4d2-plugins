# Generous Witch

**Version:** 1.0.0
**Author:** monnie
**Source:** [gitlab.com/iqrar99/l4d2-plugins](https://gitlab.com/iqrar99/l4d2-plugins)
**Requires:** SourceMod 1.11+ and [Left 4 DHooks Direct](https://forums.alliedmods.net/showthread.php?p=2684897)

A SourceMod plugin for **Left 4 Dead 2** that rewards survivors for dealing with a Witch. Every Witch that dies, by any means, drops exactly **one** healing item: a First Aid Kit, a Defibrillator, or a random pick between the two.

---

## Features

- One guaranteed drop per Witch kill: crowns, melee, fire, explosions, or any other cause.
- Works with low violence mode (`-lv`), where explosive kills make the Witch vanish instantly.
- Choose the drop: First Aid Kit only, Defibrillator only, or random.
- Works in every gamemode by default, with an optional whitelist to limit it to specific modes.
- Settings can be changed live without a map restart.
- Auto-generates its config file on first load.

---

## Installation

1. Compile `l4d2_generous_witch.sp` with `spcomp` (or `compile.exe` on Windows), found in `addons/sourcemod/scripting/`.
2. Copy the resulting `l4d2_generous_witch.smx` to `addons/sourcemod/plugins/`.
3. Restart the server or change the map. Alternatively, run `sm plugins load l4d2_generous_witch` in the server console.
4. Edit `cfg/sourcemod/l4d2_generous_witch.cfg`, which is created automatically on first load.

---

## ConVars

| ConVar | Default | Values | Description |
|---|---|---|---|
| `l4d2_generous_witch_enable` | `1` | `0` / `1` | Disables or enables the plugin. |
| `l4d2_generous_witch_drop` | `2` | `0`, `1`, `2` | `0` = First Aid Kit, `1` = Defibrillator, `2` = Random. |
| `l4d2_generous_witch_modes` | `""` | Comma-separated list | Gamemodes where the plugin is active. Empty = all gamemodes. |
| `l4d2_generous_witch_lvfix` | `1` | `0` / `1` | Low violence fix: a Witch removed while alive counts as killed. See [How it works](#how-it-works). |
| `l4d2_generous_witch_version` | — | — | Plugin version (read-only). |

### Gamemode whitelist

Values must match the server's `mp_gamemode` exactly. Common values:

| Mode | `mp_gamemode` |
|---|---|
| Campaign | `coop` |
| Realism | `realism` |
| Versus | `versus` |
| Survival | `survival` |
| Scavenge | `scavenge` |
| Mutations | `mutation1`, `mutation4`, etc. |

Examples:

```
// Active everywhere
l4d2_generous_witch_modes ""

// Campaign and Realism only
l4d2_generous_witch_modes "coop,realism"
```

Spaces are ignored, and entries are matched whole. `versus` will not match `teamversus`.

---

## How it works

Every Witch is tracked from the moment she spawns. Her death is detected through two paths:

1. **`witch_killed` event**: the normal death path.
2. **Entity removal**: in low violence mode, explosive ammo and explosions delete the Witch instantly, at full health, without any damage being applied or a death event firing. With `l4d2_generous_witch_lvfix 1`, a Witch removed while still alive counts as killed, **unless**:
   - the round or map is ending (normal entity cleanup), or
   - she incapped or killed a survivor, since she then flees and may despawn on her own.

A Witch stops being tracked the moment she drops her item, so only **one** item drops even if both paths fire.

Before dropping, the plugin checks that it is enabled and the current gamemode is allowed. The item spawns on the next frame, 15 units above the Witch's position.

---

## Known limitations

- Items drop at the Witch's origin. On steep slopes or ledges they may roll away.
- The low violence fix is a heuristic. If another plugin or an admin command removes a living Witch mid-round, she will drop an item. Set `l4d2_generous_witch_lvfix 0` if that is a problem on your server.

## Changelog

**1.1.0**
- Initial release.
