# Puller

Puller is a standalone MacroQuest Lua script that finds a mob, tags it, and then either drags it
back to camp or fights it where it stands. It deliberately does **not** run spell, ability or
discipline rotations. It gets you into the fight and hands combat to you or to your own combat
script, such as E3Next, triune.lua or KissAssist.

📖 **Full documentation is in the [Puller wiki](https://github.com/MetalJacx/EQ-LUA/wiki).**

![The Puller window](docs/images/puller-pull-method.png)

## Features

- **[Camp or Hunt](https://github.com/MetalJacx/EQ-LUA/wiki/Pull-Modes):** drag every mob back
  to one spot, or fight each one where you tag it. Camps are saved per zone.
- **[Melee, Ranged, Spell or Item pulls](https://github.com/MetalJacx/EQ-LUA/wiki/Pull-Methods),**
  with On Engage and On Fight End commands to hand off to your combat script.
- **[Targeting](https://github.com/MetalJacx/EQ-LUA/wiki/Targeting):** radius, height, level and
  faction filters, a KS guard, and picking the mob that's closest to walk to.
- **[Pull Arc](https://github.com/MetalJacx/EQ-LUA/wiki/Pull-Arc):** only pull from one
  direction.
- **[Waypoint Patrol](https://github.com/MetalJacx/EQ-LUA/wiki/Waypoint-Patrol):** walk a route
  and pull along the way.
- **[Swarm Pull](https://github.com/MetalJacx/EQ-LUA/wiki/Swarm-Pull):** gather several mobs
  before the fight starts.
- **[Priority and Ignore Lists](https://github.com/MetalJacx/EQ-LUA/wiki/Priority-and-Ignore-Lists):**
  per-zone named mobs to pull first, or never pull.
- **[Wait for Loot](https://github.com/MetalJacx/EQ-LUA/wiki/Wait-for-Loot)** and the
  **[Resource Gate](https://github.com/MetalJacx/EQ-LUA/wiki/Resource-Gate):** hold the next pull
  while looting, or while you or a group member are low on HP or mana.
- **[Safety and quality of life](https://github.com/MetalJacx/EQ-LUA/wiki/Safety-and-Quality-of-Life):**
  line-of-sight handling, Force Engage, session stats (XP, AA, kills and plat per hour) and
  Debug mode.

## Requirements

- [MacroQuest](https://www.macroquest.org/) with Lua scripting support.
- [MQ2Nav](https://www.macroquest.org/), with a navmesh loaded for your current zone.

## Quick start

1. Copy [`Puller/puller.lua`](Puller/puller.lua) into your MacroQuest `lua/` folder.
2. In game, run `/lua run puller`. The Puller window opens.
3. Stand where you want to camp, face the direction you want to pull from, and click
   **Set Camp Here**.
4. On the **Pull Method** tab, pick Melee, Ranged, Spell or Item.
5. Click **Start**.

Settings are saved per character and reload the next time you run the script. For a full
walkthrough, see [Getting Started](https://github.com/MetalJacx/EQ-LUA/wiki/Getting-Started).

## Common commands

| Command | What it does |
| --- | --- |
| `/puller start` / `/puller stop` | Start or stop pulling |
| `/puller setcamp` | Set the camp to your position and facing |
| `/puller mode camp` / `/puller mode hunt` | Switch Pull Mode |
| `/puller status` | Print the current state |
| `/puller help` | List every command in the console |
| `/pullerexit` | Exit the script |

See the [full command list](https://github.com/MetalJacx/EQ-LUA/wiki/Getting-Started#commands).

## Using a combat script

Puller hands the fight to your combat script through the **On Engage Command**. There are setup
guides for [E3Next](https://github.com/MetalJacx/EQ-LUA/wiki/Combat-Scripts-E3Next),
[triune.lua](https://github.com/MetalJacx/EQ-LUA/wiki/Combat-Scripts-triune) and
[KissAssist](https://github.com/MetalJacx/EQ-LUA/wiki/Combat-Scripts-KissAssist). The one rule
for any of them: only one thing should move you during a fight. See
[Combat Scripts](https://github.com/MetalJacx/EQ-LUA/wiki/Combat-Scripts).

## Help

Something not working? Turn on **Debug** in the Puller window and check
[Troubleshooting](https://github.com/MetalJacx/EQ-LUA/wiki/Troubleshooting).

## Credits

Puller started as the Puller (Camp) feature in a larger `triune.lua` plugin suite and was
rewritten as its own script. More in [About](https://github.com/MetalJacx/EQ-LUA/wiki/About).
