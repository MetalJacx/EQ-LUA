# EQ-LUA

# Puller

A standalone MacroQuest Lua script that finds a mob, tags it, and either drags it back to camp
or fights it where it stands. It deliberately does **not** do spell/ability/disc rotations — it
gets you into the fight and hands combat itself off to you or your own combat script
(e.g. `/assistme`, `/cleartargets stick`, E3Next). Originally pulled out of the Puller (Camp)
feature inside a larger `triune.lua` plugin suite, rewritten from scratch as its own script.

## Requirements

- [MacroQuest](https://www.macroquest.org/) with Lua scripting support
- [MQ2Nav](https://www.macroquest.org/) (navmesh loaded for your current zone) — pulling and
  dragging mobs home both rely on it
- Optional: a combat script/box framework to hand fights off to via **On Engage Command**

## Installation

Drop `puller.lua` into your MacroQuest `lua/` folder and run:

```
/lua run puller
```

Settings are saved per-character to `puller_<CharacterName>.lua` in your MQ config folder, and
reload automatically next time you run the script.

## Commands

| Command | Does |
|---|---|
| `/puller start` (or `resume`) | Starts pulling |
| `/puller stop` (or `pause`) | Stops pulling |
| `/puller setcamp` | Sets the camp location (Camp mode) to your current position/facing |
| `/puller clearcamp` | Clears the camp location |
| `/puller addwp` | Adds a waypoint at your current position |
| `/puller clearwp` | Clears all waypoints |
| `/puller mode camp` / `/puller mode hunt` | Switches Pull Mode |
| `/puller status` | Prints the current state to console |
| `/puller force` (or `forceengage`) | Skips straight to fighting whatever's currently targeted |
| `/pullerexit` (or `stop`/`quit`) | Exits the script |

All of the above are also available as buttons/controls in the UI window (`/lua run puller`
opens it automatically).

## How it works

Puller runs a simple state machine: **IDLE → TO_MOB → TO_CAMP → FIGHTING**, back to IDLE once
nothing hostile is left. Hunt mode skips TO_CAMP and fights mobs where they're tagged instead of
dragging them home. When Swarm Pull is enabled, a **GATHER** state is inserted between IDLE and
TO_MOB/TO_CAMP/FIGHTING to collect multiple mobs before committing to a fight.

## Features

### Pull Modes

- **Camp** — drags every tagged mob back to one fixed spot.
- **Hunt** — fights each mob where it's tagged, either roaming unrestricted or within an
  optional anchor point + radius.

### Pull Methods

**Melee / Ranged / Spell / Item** — tag by approaching the method's reach, firing, and
confirming aggro before dragging home or fighting in place. Melee stays self-managed through the
whole fight (closing distance, facing, re-engaging a different target if the current one dies or
becomes unreachable); Ranged/Spell/Item/E3Next-driven combat is handed off entirely once the
fight starts.

### Targeting

- **Pull Radius / Height (Z)** — how far out (and how far up/down) to look for mobs from your
  camp/anchor point.
- **Min/Max Level** and **Faction Consideration** (con-color tiers, color-coded worst → best) —
  filter what's eligible to pull. Con colors are read via the same `/consider` chat-line capture
  triune.lua uses, since `ConColor()` isn't trusted on every server.
- **Show radius on EQ map** — draws a circle on the native EQ map pinned to the camp/anchor point
  (via MQ2Map's `/maploc`), not to the player, so it stays put while you travel.
- **Pull Wait** — throttles how often it re-scans for a target once an area's empty, so it isn't
  hammering a spawn scan every tick while waiting out a long repop (mainly for camping a named).
- Target selection always picks the **true closest** candidate by real 3D distance among
  everything that passes every filter — not just the first one MacroQuest's own (2D, height-blind)
  default ordering happens to return.

### Pull Arc

Same idea as KissAssist's `/setpullarc`: restricts pulls to a directional cone instead of the
full circle. Its own tab has a live preview that rotates with your facing while aiming, plus a
Lock Heading / Re-aim toggle — independent of moving the actual camp/anchor location, so you can
re-aim the cone without having to stand exactly on your camp spot again.

### Waypoint Patrol

A list of saved points walked in order (looping or ping-ponging at the ends), scanned for
targets along the way. Available under either Pull Mode.

### Swarm Pull

Gathers a configurable number of mobs onto XTarget **before** engaging, instead of tagging and
fighting one at a time.

- Gathering is a **body pull by default** (walk into range, let EQ's own proximity/faction aggro
  do the rest — no damage dealt, so nothing gets a chance to summon you mid-gather). An optional
  tag command can be set per-candidate if you'd rather accept that risk.
- **Fight When Summoned** — getting summoned anyway ends the gather immediately and fights (or
  heads back to camp) with whatever's already aggro'd, even below the configured count.
- **Stop Gathering Below HP%** — same idea, triggered by your own HP dropping too low instead of
  a summon.
- Works under either Pull Mode: Hunt fights the whole group in place; Camp drags the whole group
  home (they all just follow whoever they're hating, same as any pull).

### Priority Kill List

Rare/named mobs that jump the queue when up, instead of waiting their turn behind whatever
happens to be closer. Saved **per zone**. This is a tie-breaker, not a bypass — a priority name
still has to pass your level/faction/radius/arc filters like anything else; it just wins the pick
over everything else when it's up and otherwise eligible.

### Resource Gate

Won't start a new pull if HP/Mana/Endurance (whichever you enable) is at or below a "start" %,
and won't resume until it's back above a higher "stop" % — the same hysteresis shape as
triune.lua's MedBreak, scoped to the puller.

### Quality-of-life / Safety

- **Sit While Idle** — sits and regens when there's nothing to pull instead of standing around.
- **Return to AP** — walks back to the camp/anchor point before sitting when idle, instead of
  sitting wherever the last mob happened to die.
- **Force Engage** — manual override for a pull that's stuck despite everything below; skips
  straight to fighting whatever's currently targeted.
- **Line-of-sight-aware navigation** — "in range" alone isn't good enough to call a pull or a
  melee swing landed; it checks actual LOS too, and pushes in close (or backs off and retries
  from a different angle if already point-blank and still blocked) instead of parking somewhere
  it can't hit from. This keeps working all the way through a fight, not just the initial
  approach — melee re-faces and repositions if a mob moves, and switches to a different hostile
  (or backs off to try a new angle) if its current target turns out to be unreachable for too
  long.
- **Non-XTarget aggro fallback** — XTarget can occasionally fail to populate for a mob that's
  genuinely attacking you (a server-side quirk, not something a script can fix). Falls back to
  checking whether your current target is retaliating, and to resolving the attacker's name
  directly from the combat log when it's neither your target nor on XTarget, so it isn't
  permanently blind to a fight XTarget missed.
- **Debug mode** — prints a periodic status line to the console (state, what it's chasing,
  distance/LOS, combat flags, XTarget/swarm counts, anchor/radius/arc in use, HP%) for diagnosing
  "why isn't it doing anything" live instead of needing a screenshot.

## Deliberately out of scope

This is "find it, tag it, drag or fight" — not a full combat script. It does not include
hazard-avoidance detours, navmesh-isolation recovery, ladder-climb handling, breadcrumb
backtracking, box-network pull coordination, or spell-loadout/combat-rotation logic. Navigation
is a plain `/nav id|loc` with a simple "no progress in N seconds → try to get unstuck, then give
up on this mob for a while" timeout, not a full stuck-recovery state machine.

## Credits

Pull logic and several conventions (heading math, unstuck maneuvers, resource-gate hysteresis)
ported and adapted from a larger `triune.lua` plugin suite. Swarm Pull's gather/fight/summon-abort
design adapted from that suite's `tac/swarm_pull.lua` plugin.
