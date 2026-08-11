# Grow a Mini Fighter

Your Roblox avatar becomes a tiny fighter that you train, mutate and send into the arena.

Working title. Strategy, research and roadmap live in the Phase 0 document
(`C:\Users\elias\.claude\plans\declarative-prancing-taco.md`).

## Setup

Once, on a new machine:

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then from this folder:

```bash
rokit install
```

2. Install the **Rojo plugin** in Roblox Studio: Plugins → Manage Plugins → search "Rojo".

3. Open `place.rbxl` in Studio (create an empty Baseplate and save it under that name the first time).

## Daily workflow

Start the sync server from this folder:

```bash
rojo serve
```

Then in Studio: Plugins → Rojo → **Connect**. Edits to any `.luau` file under `src/`
appear in Studio within a second. Studio is for the map, GUI and rigs; VS Code is
for all code. Never edit scripts inside Studio — Rojo overwrites them.

## Layout

| Path | Maps to | Holds |
|---|---|---|
| `src/shared/` | `ReplicatedStorage.Shared` | Config, types, utilities, the remote definitions |
| `src/server/` | `ServerScriptService.Server` | Services. All authority lives here |
| `src/client/` | `StarterPlayerScripts.Client` | Controllers. Input, UI, camera, VFX, audio |
| `assets/` | not synced | Source art, audio, reference images |
| `docs/` | not synced | Changelog and experiment log |

`src/server/init.server.luau` and `src/client/init.client.luau` are loaders with an
explicit `LOAD_ORDER`. A service may only depend on services listed above it.

## Rules that are not up for debate

- **The server decides everything** that matters: currency, damage, ownership,
  rarity outcomes, purchases, rewards, inventory, stats. The client sends
  intents and draws pictures.
- **Every client→server remote is rate limited.** `Remotes.bind` will not let you
  register one without a limit.
- **Content is config, not code.** New enemies, upgrades and mutations are table
  entries under `src/shared/Config/`.
- **Mobile first.** Hard budget: 24 active minis and 40 active enemies per server.
  Nothing gets built in the combat hot path with `Instance.new`.
