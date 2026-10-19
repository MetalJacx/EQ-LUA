# Puller

Puller is a standalone MacroQuest Lua script that finds a mob, tags it, and then either drags it
back to camp or fights it where it stands. It deliberately does **not** run spell, ability or
discipline rotations. It gets you into the fight and then hands combat to you or to your own
combat script (for example `/assistme`, `/cleartargets stick`, or E3Next).

It started as the Puller (Camp) feature inside a larger `triune.lua` plugin suite and was
rewritten from scratch as its own script.

## Requirements

- [MacroQuest](https://www.macroquest.org/) with Lua scripting support.
- [MQ2Nav](https://www.macroquest.org/), with a navmesh loaded for your current zone. Pulling,
  dragging mobs home, and choosing which mob is closest all depend on it.
- Optional: a combat script or boxing framework to hand fights off to, through the
  **On Engage Command** setting.

## Installation

Put `puller.lua` in your MacroQuest `lua/` folder, then run:

```
/lua run puller
```

The UI window opens automatically. Settings are saved per character to
`puller_<CharacterName>.lua` in your MacroQuest config folder and reload the next time you run
the script.

## Commands

| Command | What it does |
|---|---|
| `/puller start` (or `resume`) | Start pulling |
| `/puller stop` (or `pause`) | Stop pulling and cancel any movement in progress |
| `/puller setcamp` | Set the camp to your current position and facing (Camp mode) |
| `/puller clearcamp` | Clear the camp location |
| `/puller addwp` | Add a waypoint at your current position |
| `/puller clearwp` | Clear all waypoints |
| `/puller mode camp` / `/puller mode hunt` | Switch Pull Mode |
| `/puller status` | Print the current state to the console |
| `/puller force` (or `forceengage`) | Start fighting your current target immediately |
| `/pullerexit` | Exit the script |

Every command also has a button or control in the UI window.

## How it works

Puller runs a simple state machine: **IDLE → TO_MOB → TO_CAMP → FIGHTING**, then back to IDLE
once nothing hostile is left.

- **Hunt mode** skips TO_CAMP and fights each mob where it was tagged.
- **Swarm Pull** inserts a **GATHER** state after IDLE, which collects several mobs before the
  fight starts.

## Features

### Pull modes

- **Camp** drags every tagged mob back to one fixed spot.
- **Hunt** fights each mob where it was tagged. You can roam freely, or stay within an anchor
  point and radius.

### Pull methods

**Melee, Ranged, Spell or Item.** Puller moves into that method's range, tags the mob, and
confirms aggro before dragging it home or fighting it in place.

- **Melee** stays under Puller's control for the whole fight. It closes distance, keeps you
  facing the mob, and moves to the nearest mob on your extended target list (XTarget) when the
  current one dies or can't be reached.
- **Melee range:** Puller moves you to about 65% of melee range but only counts you as out of
  range past about 90%. You end up in the middle of melee range instead of on its edge, so a mob
  shifting half a step doesn't put abilities like Flying Kick out of reach. Distances include
  height, which matches how the game checks range on slopes and stairs.
- **Ranged, Spell and Item** hand the fight to your combat script once it starts.

### On Engage Command

On Engage Command runs whatever you put in it (for example `/assistme`) when a fight begins.

- **With Melee**, it runs each time your melee target changes, so your group follows the mob
  you're actually hitting.
- **With other pull methods**, it runs once for each new mob on XTarget. Runs are spaced a few
  seconds apart so they don't flood your combat script.
- **Several commands** can go in one line with MacroQuest's `/multiline`:

  ```
  /multiline ; /assistme;/hidecorpse all
  ```

### Targeting

- **Pull Radius / Hunt Radius and Height (Z):** how far out from your camp or anchor to look for
  mobs, and how far up or down. Both radii go up to 1000. In Hunt mode, a radius of **0 means the
  whole zone**.
- **Min/Max Level and Faction Consideration:** limit which mobs can be pulled, by level and by
  con tier (color-coded from worst to best). Con is read by sending `/consider` and capturing the
  chat reply, because `ConColor()` isn't reliable on every server. The faction filter applies to
  normal pulls and to Swarm Pull gathering.
- **Closest by walking distance:** the next mob is chosen by MQ2Nav path length, not straight-line
  distance. A mob on the other side of a wall that would need a long walk around loses to one
  that's farther in a straight line but easy to reach. The scan stops as soon as no remaining mob
  can beat the shortest walk it has found, so it stays cheap.
- **Pull Wait:** limits how often Puller rescans once the area is empty. This is mainly for
  camping a named mob through a long respawn. It never delays reacting to a mob that attacks you,
  and never delays picking a new mob right after the previous one was dropped.
- **Show radius on EQ map:** draws circles on the native EQ map (through MQ2Map's `/maploc`),
  pinned to the camp or anchor point rather than to you. The pull radius is red. In Camp mode,
  the Camp Safe Radius is green.

### Camp Safe Radius

Camp Safe Radius is a Camp mode setting with a default of 30 (0 turns it off).

- **Holding at camp:** once a drag reaches camp, you stay on the camp spot. Melee only goes after
  mobs that have come within this distance of the camp point, so you don't run straight back out
  to the nearest mob on XTarget.
- **Delayed engage:** On Engage Command waits until a mob is inside the radius, so your group
  isn't sent out after it either.
- **Force Engage** ignores the radius.

### Pull arc

The pull arc works like KissAssist's `/setpullarc`: it limits pulls to a cone in one direction
instead of the full circle.

- The Pull Arc tab has a live preview that turns with you while you aim.
- **Lock Heading** commits the direction and **Re-aim** lets you change it. Aiming is separate
  from the camp or anchor location, so you can re-aim without standing on your camp spot again.

### Waypoint patrol

A waypoint patrol is a list of saved points that Puller walks in order while there's nothing to
pull. It can loop or go back and forth between the ends, and it scans for mobs along the way.
It works in either Pull Mode.

Each waypoint has two optional settings:

- **Cmd** runs once when you arrive at that waypoint. Leave it blank to do nothing. `/multiline`
  works here too.
- **Delay (s)** is how long to wait at that waypoint before moving on. The default is 0, meaning
  no wait. Puller still pulls anything that shows up while it's waiting.

### Swarm Pull

Swarm Pull gathers a set number of mobs onto XTarget **before** the fight starts, instead of
tagging and fighting one mob at a time.

- **Body pull by default:** Puller walks into range and lets EQ's own proximity aggro do the
  rest. It deals no damage, so nothing gets a chance to summon you mid-gather. You can set a tag
  command for each candidate if you'd rather accept that risk.
- **Fight When Summoned:** if you get summoned anyway, the gather ends immediately and Puller
  fights, or heads back to camp, with whatever has aggro, even if that's fewer than the count.
- **Stop Gathering Below HP%:** the same early exit, triggered when your own HP drops too low.
- **Fights start close:** when a gather ends, melee starts on the nearest mob that's already
  attacking you, not on the candidate it was still walking toward.
- **Works in either mode:** Hunt fights the whole group in place. Camp drags the whole group
  home.

### Priority Kill List

The Priority Kill List is for rare or named mobs that should be pulled ahead of whatever happens
to be closer. Lists are saved **per zone**.

A priority mob still has to pass your level, faction, radius and arc filters. Being on the list
only means it wins the pick when it's up and eligible.

### Resource Gate

The Resource Gate stops new pulls when HP, Mana or Endurance (whichever you turn on) is at or
below a "start" percentage. Pulling resumes once that resource is back above a higher "stop"
percentage. You sit to recover in between.

### Quality of life and safety

- **Sit while idle:** sit and regenerate when there's nothing to pull.
- **Return to AP:** walk back to the camp or anchor point before sitting, instead of sitting
  wherever the last mob died.
- **Force Engage:** manual override for a pull that's stuck. It skips straight to fighting your
  current target.
- **Line-of-sight checks:** being in range isn't enough. Puller also checks line of sight, moves
  in close or backs off to try another angle when something blocks it, and switches to a
  different mob if the current one can't be reached for too long.
- **Missing XTarget entries:** XTarget sometimes fails to list a mob that's attacking you. When
  that happens, Puller checks whether your current target is hitting back, and reads the
  attacker's name from the combat log.
- **Zoning:** the camp and hunt anchor remember which zone they were set in. If you zone
  somewhere else while pulling, Puller pauses instead of heading for coordinates from the old
  zone.
- **Debug mode:** prints a status line to the console every couple of seconds, with the state,
  the mob it's after, distance, line of sight, combat flags, XTarget and swarm counts, the
  anchor, radius and arc in use, and your HP. Use it to see why Puller is or isn't doing
  something.

## Out of scope

Puller finds a mob, tags it, and drags it home or fights it. It is not a full combat script and
does not include:

- hazard avoidance
- recovery when you're cut off from the navmesh
- ladder climbing
- retracing your steps after getting lost
- pull coordination across multiple boxes
- spell loadouts or combat rotations

Navigation is a plain `/nav id|loc`. If there's no progress for a while, Puller tries once to
get unstuck and then skips that mob for a short time. There's no full stuck-recovery system.

## Credits

The pull logic and several conventions (heading math, unstuck moves, the start/stop thresholds
of the Resource Gate) were ported and adapted from a larger `triune.lua` plugin suite. Swarm
Pull's gather, fight and summon-abort design was adapted from that suite's `tac/swarm_pull.lua`
plugin.
