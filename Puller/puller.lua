--[[
    puller.lua
    A standalone "find a mob, tag it, and either drag it to camp or fight it
    where it stands" script, pulled out of the Puller (Camp) feature inside
    triune.lua. It deliberately does not do spell/ability/disc rotations --
    it gets you into the fight and hands the fight itself off to you or your
    own combat script (onEngageCommand, e.g. /assistme or /cleartargets
    stick).

    State machine: IDLE -> TO_MOB -> TO_CAMP -> FIGHTING (Hunt mode skips
    TO_CAMP and fights in place -- see Pull Mode below), back to IDLE once
    nothing hostile is left. Swarm Pull (below) inserts a GATHER state
    between IDLE and TO_MOB/TO_CAMP/FIGHTING when enabled.

    Core behavior:
      - Pull methods: Melee / Ranged / Spell / Item. Tag by approaching the
        method's reach, firing, and confirming aggro (XTarget, or a non-
        XTarget fallback -- see below) before dragging home or fighting in
        place.
      - Con-color filtering via the same /consider chat-line mechanism as
        triune.lua (ConColor() is not trusted on this server).
      - Pull Mode: Camp (drag every tagged mob back to one spot) or Hunt
        (fight each mob where it's tagged; roam either unrestricted or
        within an optional anchor point + radius).
      - Waypoint Patrol: a list of saved points walked in order (looping or
        ping-ponging at the ends), scanned for targets along the way,
        available under either Pull Mode.
      - Return to AP: when idle with nothing to pull (and not patrolling),
        optionally walks back to the camp/anchor point before sitting,
        instead of sitting wherever the last mob happened to die.
      - Pull Wait: throttles how often it re-scans for a target once an
        area's empty (mainly for camping a named without hammering
        NearestSpawn every tick).
      - EQ map radius circle: a red circle drawn via MQ2Map's /maploc,
        pinned to the actual camp/anchor point (not the player -- it stays
        put while you travel). Toggle: Targeting -> "Show radius on EQ map".
      - Pull Arc (same idea as KissAssist's /setpullarc): restricts pulls to
        a directional cone instead of the full circle. Its own tab has a
        live preview (rotates with your facing while aiming) and a
        Lock Heading / Re-aim toggle, independent of moving the actual
        camp/anchor location.
      - Line-of-sight-aware navigation: "in range" alone isn't good enough
        to call a pull or a melee swing landed -- it also checks actual LOS,
        and pushes in close (or backs off and retries from a different angle
        if already point-blank and still blocked) instead of parking
        somewhere it can't hit from. This keeps working through FIGHTING,
        not just the initial approach, so melee also re-faces and repositions
        if a mob moves mid-fight.
      - Non-XTarget aggro fallback: XTarget can occasionally fail to
        populate for a mob that's genuinely attacking you (seen live on this
        server). Falls back to checking whether your current target is
        hostile and actually retaliating (TargetOfTarget/PctAggro) so it
        isn't permanently blind to a fight XTarget missed.
      - Force Engage: a manual override (button or /puller force) for a pull
        that's stuck despite the above -- skips straight to fighting
        whatever's currently targeted.
      - Swarm Pull (ported from tac/swarm_pull.lua's design): gather a
        configurable count of mobs onto XTarget BEFORE engaging, instead of
        tagging and fighting one at a time. Gathering is a body pull by
        default (walk into range, let EQ's own proximity/faction aggro do
        the rest, no damage dealt, so nothing can summon you mid-gather);
        an optional tag command can be set if you want to accept that risk
        instead. Getting summoned anyway ends the gather immediately with
        whatever's already aggro'd, even below the configured count. Works
        under either Pull Mode: Hunt fights the whole group in place, Camp
        drags it home (they all just follow whoever they're hating, same
        as any pull).
      - Resource gate: won't start a new pull if HP/Mana/Endurance (whichever
        you enable) is at or below a "start" %, and won't resume until it's
        back above a higher "stop" % -- same hysteresis shape as triune.lua's
        MedBreak, scoped to the puller.

    Deliberately out of scope (this is "find/tag/drag or fight", not a full
    combat script): hazard-avoidance detours, navmesh-isolation recovery,
    ladder-climb handling, breadcrumb backtracking, box-network pull
    coordination, the named pull include-list, spell-loadout/castGem combat
    rotations, and Hunt mode's "mob pulled me outside the anchor mid-fight"
    exception handling (it just won't leash you back inside while already
    engaged). Navigation is a plain /nav id|loc with a simple "no progress in
    N seconds -> try to get unstuck, then give up on this mob for a while"
    stall timeout, not a full stuck-recovery state machine.

    Usage: /lua run puller
    Commands: /puller start|stop|resume|pause|setcamp|clearcamp|addwp|
              clearwp|mode camp|mode hunt|status|force
              /pullerexit (also stop/quit) exits the script.
--]]

local mq = require('mq')
local ImGui = require('ImGui')

local myName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or 'Unknown'
local cfgPath = 'puller_' .. myName .. '.lua'
local header = '\ay[\agPuller\ay]'
local running = true

-- ----------------------------------------------------------------------------
-- Config (persisted) + runtime state (not persisted)
-- ----------------------------------------------------------------------------
local CON_TIERS = {
    'Scowling', 'Threateningly', 'Dubious', 'Apprehensive', 'Indifferent',
    'Amiably', 'Kindly', 'Warmly', 'Ally',
}
-- Red (hostile) -> green (friendly), same order as CON_TIERS -- just a
-- quick-glance cue on the Targeting tab for which faction tiers are
-- currently allowed, not tied to any real EQ con-color meaning.
local CON_TIER_COLORS = {
    { 0.90, 0.30, 0.30 }, { 0.90, 0.45, 0.25 }, { 0.90, 0.80, 0.25 },
    { 0.75, 0.80, 0.35 }, { 0.80, 0.80, 0.80 }, { 0.55, 0.80, 0.65 },
    { 0.40, 0.75, 0.90 }, { 0.35, 0.60, 0.90 }, { 0.35, 0.85, 0.45 },
}
local PULL_STYLES = { 'Melee', 'Ranged', 'Spell', 'Item' }

local function defaultConFilter()
    return {
        Scowling = true, Threateningly = true, Dubious = true,
        Apprehensive = true, Indifferent = true,
        Amiably = false, Kindly = false, Warmly = false, Ally = false,
    }
end

local function defaultCfg()
    return {
        enabled = false,
        pullStyle = 'Melee',
        pullSpell = '',
        pullItem = '',
        engageDist = 100,
        -- Fired once, the instant the fight actually begins (state ->
        -- FIGHTING), in either Pull Mode. Blank = do nothing. Meant for a
        -- combat script's engage command (e.g. /cleartargets stick) so it
        -- only ever gets invoked once per pull instead of being driven by
        -- a repeating condition elsewhere.
        onEngageCommand = '',
        -- Pull Mode: 'Camp' drags every tagged mob back to campLoc (as
        -- before); 'Hunt' fights each mob where it's tagged instead.
        pullMode = 'Camp',
        campLoc = nil,
        campRadius = 100,
        campZ = 75,
        -- Camp Safe Radius: once you're back at camp, a mob isn't engaged
        -- (melee chase, onEngageCommand) until it's within this many units
        -- of the camp point -- otherwise the moment a drag got home melee
        -- ran straight back out after whatever on XTarget was nearest, even
        -- 100+ units away, dragging the fight out of camp. 0 = off. Drawn
        -- as a green circle on the EQ map alongside the red pull radius.
        campSafeRadius = 30,
        -- Pull arc, like KissAssist's /setpullarc: 0 = disabled (full
        -- circle), else only mobs within +/- width/2 of campHeading are
        -- pullable. campHeading is captured automatically from your facing
        -- direction at the moment you set the camp (face where you want to
        -- pull, then "Set Camp Here") -- same workflow KissAssist uses.
        campArcWidth = 0,
        campHeading = nil,
        -- Hunt: huntAnchor is optional. nil, or huntRadius <= 0, means
        -- unrestricted roam (just the zone-of-interest scan cap below).
        huntAnchor = nil,
        huntRadius = 0,
        huntZ = 75,
        huntArcWidth = 0,
        huntHeading = nil,
        minLevel = 1,
        maxLevel = 100,
        conFilter = defaultConFilter(),
        -- Shows the active radius as a red circle on the native EQ map,
        -- pinned to the camp/anchor point via MQ2Map's /maploc.
        showMapCircle = true,
        -- Sit and regen while idle (nothing to pull, no waypoints to walk)
        -- instead of just standing there doing nothing between pulls.
        idleSit = true,
        -- Walk back to the camp/anchor point when idle (nothing to pull,
        -- not patrolling waypoints) instead of sitting wherever the last
        -- mob happened to die. No-op if no camp/anchor is set.
        returnToAnchor = false,
        -- Seconds between target scans while IDLE with nothing up -- 0
        -- scans every tick. Mainly for camping a named: no point re-running
        -- the NearestSpawn scan every 200ms while waiting out a long repop.
        -- Doesn't delay picking up an actual aggro (firstHostileXtarget) or
        -- a successful scan transitioning to TO_MOB -- only throttles the
        -- "still nothing up" re-check.
        pullWait = 5,
        -- Waypoint Patrol: walked in order when no target is in range,
        -- scanned for targets along the way. Available under either mode.
        useWaypoints = false,
        waypoints = {},         -- { {x=, y=, z=, name=, cmd=, delay=}, ... }
                                -- cmd: run once on arrival ('' = none); delay: seconds to
                                -- hold there before moving on (0 = none)
        waypointRadius = 20,    -- arrival distance per waypoint
        waypointScanRadius = 100, -- how far to scan for targets while patrolling
        waypointLoop = true,    -- true: always forward, wraps; false: ping-pong
        -- Resource gate: hysteresis per resource, same shape as triune's
        -- MedBreak (start = pause threshold, stop = resume threshold).
        restEnabled = true,
        hpOn = false, hpStart = 20, hpStop = 90,
        manaOn = true, manaStart = 20, manaStop = 90,
        endOn = false, endStart = 20, endStop = 90,
        -- Swarm Pull (ported from tac/swarm_pull.lua's design): gather this
        -- many mobs onto XTarget BEFORE engaging, instead of tagging and
        -- fighting one at a time. Tagging during the gather is a body pull
        -- by default (swarmTagCmd blank) -- walk into range and let EQ's
        -- own proximity/faction aggro do it, no damage dealt -- so nothing
        -- gets a chance to summon you before the batch is complete.
        swarmEnabled = false,
        swarmCount = 3,
        swarmPullRange = 15,   -- stop this close to a candidate and wait for it to aggro
        swarmAggroWait = 3,    -- seconds to wait in range before giving up on a candidate
        swarmMaxChase = 45,    -- seconds to chase a single candidate before giving up on it
        swarmTagCmd = '',      -- optional, sent once in range (e.g. /attack on); blank = body pull
        -- "You have been summoned!" (e.g. a riposte on a body pull) ends
        -- the gather immediately and fights/returns with whatever's already
        -- aggro'd, even below swarmCount -- same safety valve swarm_pull.lua
        -- uses ("Fight when summoned").
        swarmFightOnSummon = true,
        -- Same idea, triggered by your own HP instead of a summon: ends the
        -- gather immediately (Hunt fights what's aggro'd, Camp heads home)
        -- the moment HP drops to or below this -- in case an add, a trap,
        -- or just unlucky proximity aggro is chewing on you while you're
        -- still out gathering more.
        swarmHpAbortEnabled = true,
        swarmHpAbortPct = 60,
        -- Wait for loot: after a fight, hold off on the next pull (and on
        -- Return to AP / sitting) while something -- E3 autoloot, another
        -- script, or you -- is looting. E3Next exposes no "looting" state
        -- (checked E3NextMC Loot.cs: nothing is [ExposedData]), so this
        -- keys off what the game itself shows: the LootWnd being open.
        -- Defaults match E3's autoloot timing: it starts ~2s after a fight
        -- (Loot_TimeToWaitAfterAssist) on a 1s check, and spends up to ~4s
        -- between corpses (walk up to 2.25s + up to 1.5s for LootWnd).
        lootWaitEnabled = false,
        lootStartGrace = 4,     -- sec after a fight for looting to begin (only if corpses are nearby)
        lootGapGrace = 5,       -- sec after LootWnd closes before calling looting done
        lootCorpseRadius = 50,  -- "corpses nearby" radius (E3's Loot_CorpseSeekRadius default)
        lootMaxWait = 180,      -- hard cap on one wait (a loot window left open); 20+ corpses at
                                -- ~4s each needs well over a minute, so keep this generous
        -- Prints a periodic status line (state, chase target, distance/LOS,
        -- XTarget/swarm counts, combat flags, HP%) to the console every few
        -- seconds -- for diagnosing "why isn't it doing anything" live
        -- instead of needing a screenshot each time.
        debugEnabled = false,
        -- Priority Kill List: when a mob on the current zone's list is up
        -- and otherwise pullable (still subject to level/con/anchor-radius/
        -- arc, same as anything else -- this is a tie-breaker, not a bypass
        -- of those), it's picked over everything else regardless of
        -- distance. Keyed by zone short name so each zone has its own list;
        -- {} until something's added. "Pullable" here stays scoped to your
        -- actual hunting area on purpose -- a priority name doesn't drag you
        -- across the zone after it.
        priorityEnabled = false,
        priorityLists = {},    -- zoneShortName -> { 'clean name', ... }
    }
end

local cfg = defaultCfg()
do
    local ok, data = pcall(dofile, mq.configDir .. '/' .. cfgPath)
    if ok and type(data) == 'table' then
        for k, v in pairs(data) do cfg[k] = v end
        if type(cfg.conFilter) ~= 'table' then cfg.conFilter = defaultConFilter() end
        if type(cfg.priorityLists) ~= 'table' then cfg.priorityLists = {} end
        -- A saved Min > Max (possible before the UI clamp existed) would
        -- otherwise display that way forever even though findPullTarget()
        -- now tolerates it -- fix the stored values too, not just the
        -- effective behavior.
        if (cfg.minLevel or 1) > (cfg.maxLevel or 100) then
            cfg.minLevel, cfg.maxLevel = cfg.maxLevel, cfg.minLevel
        end
    end
end

local function saveCfg()
    mq.pickle(cfgPath, cfg)
end

local state = {
    pullState = 'IDLE',   -- IDLE | TO_MOB | TO_CAMP | FIGHTING
    pullTargetId = 0,
    resting = false,
    navBestDist = 9999,
    navBestAt = 0,
    navUnstuckTried = false, -- already tried one unstuck nudge for the current TO_MOB target
    navLosBackoffCount = 0, -- times we've backed off a point-blank LOS block for the current TO_MOB target
    engagedIds = {},       -- ids already announced via onEngageCommand this encounter
    lastAnnounceAt = 0,    -- os.clock() of the last FIGHTING-sweep announce
    lastChaseId = 0,       -- FIGHTING melee's last active chase target (separate from
                           -- engagedIds: onEngageCommand needs to re-fire every time THIS
                           -- changes, even for a mob already seen once as an add)
    tempIgnore = {},       -- id -> os.clock() expiry, mobs we gave up reaching
    conCache = {},          -- cleaned name -> tier
    conAskedAt = {},
    wpIndex = 1,
    wpDirection = 1,
    wpArrivedIdx = nil,    -- waypoint index whose arrival cmd/delay already fired (nil once we leave it)
    wpWaitUntil = 0,       -- os.clock() the current waypoint's delay ends
    mapLocLoc = nil,       -- {x=,y=,z=} of the anchor circle currently drawn, if any
    mapLocRadius = nil,    -- radius currently drawn at mapLocLoc
    safeLocLoc = nil,      -- same, for the green Camp Safe Radius circle
    safeLocRadius = nil,
    campSafeBypassId = 0,  -- Force Engage target: exempt from the Camp Safe Radius wait
    restFightingSince = nil, -- os.clock() a fighting signal first appeared while resting
    lastPruneAt = 0,       -- os.clock() of the last tempIgnore sweep
    lastScanAt = 0,        -- os.clock() of the last IDLE target scan (pullWait throttle)
    lastE3QueryAt = 0,     -- os.clock() /e3echo was last fired
    e3Enabled = false,     -- cached E3Next ClearXTargets.Enabled, from the last reply
    e3MobToAttack = 0,     -- cached E3Next ClearXTargets.MobToAttack (spawn id)
    e3Sticking = false,    -- cached E3Next ClearXTargets.StickTarget (bool, not an id)
    e3UpdatedAt = 0,       -- os.clock() the cached E3 fields were last refreshed
    arcAiming = {},        -- 'Camp'/'Hunt' -> true while the Pull Arc tab's preview
                           -- tracks live facing (nil = not yet decided for this mode)
    swarmSkip = {},        -- id -> true, candidates that wouldn't aggro/reach this gather batch
    swarmSummoned = false, -- set by the "You have been summoned!" event; checked in GATHER
    swarmChaseUntil = 0,   -- os.clock() deadline for reaching the current gather candidate
    swarmAggroSince = nil, -- os.clock() we first got in range of the current candidate, or nil
    swarmTagged = false,   -- already sent swarmTagCmd for the current candidate this approach
    lastHitById = 0,       -- spawn id resolved from the most recent "<blob> YOU for # damage" line
    lastHitAt = 0,         -- os.clock() that line was last seen
    meleeChaseStuckSince = nil, -- os.clock() melee's current FIGHTING chaseId last failed
                                 -- to be "arrived" at (nil once arrived or chaseId changes)
    lastDebugAt = 0,       -- os.clock() of the last debug status print
    priorityInput = '',    -- scratch text for the Priority List tab's Add box
    lootWaitSince = nil,   -- os.clock() the current post-fight loot wait began, nil = not waiting
    lootSeenAt = nil,      -- os.clock() LootWnd was last seen open during this wait
}

local openGUI, drawGUI = true, true

-- ----------------------------------------------------------------------------
-- Small helpers
-- ----------------------------------------------------------------------------
local function printf(fmt, ...)
    print(string.format('%s %s', header, string.format(fmt, ...)))
end

-- 3D, not Spawn.Distance() (X/Y only): EQ's own melee/spell range checks
-- include height, so on a slope, stairs, or a mob up on a ledge a "12" flat
-- distance could really be 14-15 -- reported in range here, out of range
-- for Flying Kick and friends.
local function distToId(id)
    if not id or id <= 0 then return 9999 end
    local d = 9999
    pcall(function()
        local s = mq.TLO.Spawn(id)
        d = s.Distance3D() or s.Distance() or 9999
    end)
    return d
end

-- Verified against tac/map.lua, tac/hud_unitframes.lua, triune.lua
-- (mq.TLO.Spawn(id).LineOfSight() / mq.TLO.Target.LineOfSight(), all nil-
-- safe with `or false`). Fails OPEN (true) on an error so a TLO hiccup
-- can't itself block pulling -- only a confirmed false should.
local function hasLos(id)
    if not id or id <= 0 then return true end
    local ok, los = pcall(function() return mq.TLO.Spawn(id).LineOfSight() end)
    if not ok then return true end
    return los ~= false
end

local function distToLoc(x, y, z)
    local mx, my, mz = 0, 0, 0
    pcall(function() mx, my, mz = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0 end)
    local dx, dy, dz = mx - x, my - y, mz - (z or mz)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function navLoaded()
    local ok, loaded = pcall(function()
        if mq.TLO.Navigation and (mq.TLO.Navigation() ~= nil or mq.TLO.Navigation.MeshLoaded() == true) then
            return true
        end
        local p = mq.TLO.Plugin('mq2nav')
        return p and p() and p.IsLoaded and p.IsLoaded() or false
    end)
    return ok and loaded == true
end

local function isOnXTarget(id)
    if not id or id <= 0 then return false end
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() and (xt.ID() or 0) == id then return true end
    end
    return false
end

local function isHostileNpc(id)
    if not id or id <= 0 then return false end
    local s = mq.TLO.Spawn(id)
    if not s() then return false end
    local dead, stype, state_ = false, '', ''
    pcall(function()
        dead = s.Dead() or false
        stype = s.Type() or ''
        state_ = s.State() or ''
    end)
    if dead or state_ == 'DEAD' then return false end
    if stype ~= 'NPC' and stype ~= 'Pet' then return false end
    if stype == 'Pet' then
        -- Exclude friendly (player-owned) pets; a charmed/summoned hostile
        -- pet has no PC master.
        local masterIsPc = false
        pcall(function() masterIsPc = (s.Master.Type() or '') == 'PC' end)
        if masterIsPc then return false end
    end
    return true
end

-- Camp mode: is this mob inside the Camp Safe Radius (cfg.campSafeRadius
-- around campLoc)? Always true outside Camp mode, with no camp set, with
-- the radius at 0 (off), or for a Force Engage target. Gates what FIGHTING
-- will chase/announce, so a fight stays in camp instead of melee running
-- back out after the nearest XTarget entry the moment a drag gets home.
local function inCampSafeZone(id)
    if cfg.pullMode ~= 'Camp' or not cfg.campLoc then return true end
    local r = cfg.campSafeRadius or 0
    if r <= 0 then return true end
    if id and id == state.campSafeBypassId then return true end
    local sx, sy, sz
    local ok = pcall(function()
        local s = mq.TLO.Spawn(id)
        sx, sy, sz = s.X(), s.Y(), s.Z()
    end)
    if not ok or not sx or not sy then return false end
    local c = cfg.campLoc
    local dx, dy, dz = sx - c.x, sy - c.y, (sz or c.z or 0) - (c.z or sz or 0)
    return dx * dx + dy * dy + dz * dz <= r * r
end

-- Resolves a combat-log attacker blob (e.g. "A haunted chest hits" -- the
-- name AND the melee verb jammed together as one capture, since EQ's verb
-- varies by weapon/attack type -- hits/kicks/crushes/slashes/etc -- with no
-- fixed literal to split on in the pattern below) to a nearby spawn, by
-- finding whichever NPC's CleanName() the blob actually starts with.
-- Case-insensitive: chat capitalization doesn't always match CleanName().
-- Prefers the LONGEST matching name so a more specific nearby name wins
-- over a shorter coincidental prefix match.
local function resolveAttackerBlob(blob)
    if not blob or blob == '' then return 0 end
    local lblob = blob:lower()
    local bestId, bestLen = 0, 0
    for i = 1, 30 do
        local s = mq.TLO.NearestSpawn(i, 'npc radius 150 zradius 100')
        if not s() then break end
        local sid = s.ID() or 0
        if sid > 0 then
            local cname = s.CleanName()
            if cname and #cname > bestLen then
                local lname = cname:lower()
                if lblob:sub(1, #lname) == lname then
                    bestId = sid
                    bestLen = #lname
                end
            end
        end
    end
    return bestId
end

-- Freshness window for the resolved combat-log attacker: long enough to
-- bridge the gap between swings (observed live: roughly every 3-6s), short
-- enough that a stale hit from a fight that's already over doesn't linger.
local UNKNOWN_ATTACKER_FRESH_SEC = 8

-- Same spirit as currentTargetHasAggro() below, but for the harder case:
-- something that is NEITHER on XTarget NOR your current target is hitting
-- you (confirmed live: "a haunted chest" landing repeated hits while it WAS
-- the current target, yet Swarm Pull's XTarget-only hater count never saw
-- it -- so this can't just lean on "is it my target" either). Resolved by
-- the PullerIncomingHit event below from the actual combat log line.
local function recentUnknownAttacker()
    if state.lastHitById <= 0 then return nil end
    if os.clock() - state.lastHitAt > UNKNOWN_ATTACKER_FRESH_SEC then return nil end
    if not isHostileNpc(state.lastHitById) then return nil end
    -- Confirmed live: once gathering has ANY mob already aggro'd (normal --
    -- that's the whole point of gathering), its ordinary combat-log hits
    -- kept re-resolving here too and tripped the "unknown attacker" abort
    -- instantly, even though XTarget already had 3 haters tracked fine.
    -- This is only meant to catch a mob XTarget genuinely can't see -- if
    -- it's already on XTarget, it's not "unknown", so don't report it as
    -- one; let the normal XTarget-based paths handle it instead.
    if isOnXTarget(state.lastHitById) then return nil end
    return state.lastHitById
end

-- XTarget is normally reliable, but it can fail to populate for a given
-- mob (confirmed live: a hostile landing repeated hits with an empty
-- XTarget list the whole time -- a server-side quirk, not something this
-- script can fix). Everything that depends solely on XTarget would
-- otherwise have zero way to notice that fight is happening. This is a
-- fallback using the same non-XTarget signals haveAggro() already relies
-- on elsewhere in this file (proven to work on this server): your current
-- target is hostile AND either targeting you back, or its aggro is fully
-- on you.
local function currentTargetHasAggro()
    local ok, res = pcall(function()
        local t = mq.TLO.Target
        if not t() then return false end
        local id = t.ID() or 0
        if id <= 0 or not isHostileNpc(id) then return false end
        local totId = 0
        pcall(function() totId = t.TargetOfTarget.ID() or 0 end)
        if totId == (mq.TLO.Me.ID() or -1) then return true end
        local pct = 0
        pcall(function() pct = t.PctAggro() or 0 end)
        return pct >= 100
    end)
    return ok and res or false
end

local function inCombat()
    local ok, res = pcall(function()
        if mq.TLO.Me.Combat() then return true end
        if mq.TLO.Me.AutoFire() then return true end
        if mq.TLO.Me.CombatState() == 'COMBAT' then return true end
        if (mq.TLO.Me.XTHaterCount() or 0) > 0 then return true end
        if (mq.TLO.Me.XTAggroCount() or 0) > 0 then return true end
        local slots = mq.TLO.Me.XTargetSlots() or 13
        for i = 1, slots do
            local xt = mq.TLO.Me.XTarget(i)
            if xt() then
                local id = xt.ID() or 0
                if id > 0 and isHostileNpc(id) then return true end
            end
        end
        -- Same non-XTarget fallback hasHostileThreat() already uses below --
        -- without it, this "full combat check" (the comment at its call
        -- site in the IDLE sweep literally says "not bare Me.Combat()")
        -- could still miss a fight XTarget hasn't populated for yet, the
        -- exact gap the fallback exists to cover elsewhere.
        if currentTargetHasAggro() then return true end
        if recentUnknownAttacker() ~= nil then return true end
        return false
    end)
    return ok and res or false
end

local function firstHostileXtarget()
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() then
            local id = xt.ID() or 0
            if id > 0 and isHostileNpc(id) then return id end
        end
    end
    return nil
end

-- Same, but skips one specific id -- used to find a DIFFERENT hostile to
-- switch to when the one currently being chased turns out to be stuck
-- (LOS-blocked, unreachable) despite other options being available.
-- NEAREST, not first by slot: XTarget slot order is just aggro order, and
-- after a big swarm slot 1 can easily be a mob 400 units away while others
-- are already in your face (confirmed live in codecay: melee walked off
-- toward a far slot-1 mob with ~20 on XTarget, several within ~100).
local function nearestHostileXtargetExcept(excludeId, filter)
    local bestId, bestD = nil, math.huge
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() then
            local id = xt.ID() or 0
            if id > 0 and id ~= excludeId and isHostileNpc(id) and (not filter or filter(id)) then
                local d = distToId(id)
                if d < bestD then bestId, bestD = id, d end
            end
        end
    end
    return bestId
end

-- Same as firstHostileXtarget(), but skips anything still in tempIgnore.
-- Used only by melee's FIGHTING-state reselect (state.pullTargetId died/went
-- non-hostile, need a new chase target) -- NOT by hasHostileThreat() or
-- anything else that's asking "is there a hostile at all" rather than
-- "what should I chase next", since a tempIgnore'd mob is still a real
-- threat, just not something melee should walk back into right away.
-- Without this, a mob just abandoned via MELEE_CHASE_STUCK_SEC (LOS-blocked,
-- still sitting on XTarget) gets immediately re-picked the moment the
-- replacement target dies or drops hostile -- confirmed live: melee
-- ping-ponged between an unreachable mob and whatever else was on XTarget,
-- re-firing onEngageCommand (and never settling into a real rotation) every
-- few seconds instead of after the normal 15s stuck window.
-- Nearest, not first by slot -- same reason as nearestHostileXtargetExcept.
local function nearestHostileXtargetNotIgnored(filter)
    local now = os.clock()
    local bestId, bestD = nil, math.huge
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() then
            local id = xt.ID() or 0
            local until_ = id > 0 and state.tempIgnore[id]
            if id > 0 and not (until_ and until_ > now) and isHostileNpc(id) and (not filter or filter(id)) then
                local d = distToId(id)
                if d < bestD then bestId, bestD = id, d end
            end
        end
    end
    return bestId
end

-- Swarm Pull's own "how many have I gathered" count. Uses XTarget's
-- TargetType() == 'Auto Hater' (the signal tac/swarm_pull.lua counts with)
-- rather than isHostileNpc, since that's specifically "is this genuinely
-- hating me" -- a tighter check than "is this a live hostile NPC that
-- happens to be on XTarget for some reason". Kept separate from
-- firstHostileXtarget/isOnXTarget above rather than changing those, since
-- those are relied on elsewhere and this is new, narrower-scoped code.
local function countSwarmHaters()
    local n = 0
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() and (xt.ID() or 0) > 0 then
            local ok, tt = pcall(function() return xt.TargetType() end)
            if ok and tt == 'Auto Hater' then n = n + 1 end
        end
    end
    return n
end

-- Deliberately NOT using inCombat() here -- that check is biased toward
-- "still fighting" on purpose (see checkRestGate's comment) so a flickering
-- signal never stands you up early. This wants the opposite bias: confirm
-- there's an ACTUAL hostile around (XTarget/hater/aggro signals) before
-- trusting it, so a stuck Combat()/AutoFire() flag with nothing left to
-- hit doesn't get mistaken for a real fight.
local function hasHostileThreat()
    local ok, res = pcall(function()
        if (mq.TLO.Me.XTHaterCount() or 0) > 0 then return true end
        if (mq.TLO.Me.XTAggroCount() or 0) > 0 then return true end
        if firstHostileXtarget() ~= nil then return true end
        if currentTargetHasAggro() then return true end
        return recentUnknownAttacker() ~= nil
    end)
    return ok and res or false
end

-- Is there a hostile on XTarget the FIGHTING sweep hasn't already
-- announced/accounted for (state.engagedIds)? Used to only query E3Next's
-- ClearXTargets state (queryE3State, below) when that answer could
-- actually change a decision -- otherwise a long fight against a single
-- mob prints the /e3echo reply to console once a second for its entire
-- duration even though nothing new is happening.
local function hasUnannouncedHostile()
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() then
            local xid = xt.ID() or 0
            if xid > 0 and isHostileNpc(xid) and not state.engagedIds[xid] then
                return true
            end
        end
    end
    return false
end

-- Autoattack/autofire can get stuck ON with nothing left to hit -- the
-- flag doesn't always clear itself when the last hostile dies, breaks LoS,
-- or despawns. Runs every tick regardless of cfg.enabled (pure cleanup,
-- not pulling behavior), and only acts when there's truly nothing hostile
-- left so it never interrupts a real fight.
local function syncAutoAttack()
    local combatOn, fireOn = false, false
    pcall(function() combatOn = mq.TLO.Me.Combat() end)
    pcall(function() fireOn = mq.TLO.Me.AutoFire() end)
    if not (combatOn or fireOn) then return end
    if hasHostileThreat() then return end
    if combatOn then mq.cmd('/attack off') end
    if fireOn then mq.cmd('/autofire off') end
end

local function isSittingOrDucking()
    local sit, duck = false, false
    pcall(function() sit = mq.TLO.Me.Sitting() end)
    pcall(function() duck = mq.TLO.Me.Ducking() end)
    return sit or duck
end

local function canSitNow()
    local casting, moving = false, false
    pcall(function() casting = mq.TLO.Me.Casting() ~= nil end)
    pcall(function() moving = mq.TLO.Me.Moving() end)
    return not casting and not moving and not mq.TLO.Me.Combat()
end

-- ----------------------------------------------------------------------------
-- Con-color filtering: same /consider-based mechanism as triune.lua (this
-- server's ConColor() TLO isn't trusted), same chat patterns.
-- ----------------------------------------------------------------------------
local function recordCon(tier, line, name)
    local tgtName = name and tostring(name):gsub('^%s*(.-)%s*$', '%1') or nil
    if not tgtName or tgtName == '' then return end
    state.conCache[tgtName] = tier
end

mq.event('PullConScowl', '#1# scowls at you#*#', function(line, n) recordCon('Scowling', line, n) end)
mq.event('PullConThreat', '#1# glares at you threateningly#*#', function(line, n) recordCon('Threateningly', line, n) end)
mq.event('PullConDubious', '#1# glowers at you dubiously#*#', function(line, n) recordCon('Dubious', line, n) end)
mq.event('PullConApprehens', '#1# looks your way apprehensively#*#', function(line, n) recordCon('Apprehensive', line, n) end)
mq.event('PullConIndiff', '#1# regards you indifferently#*#', function(line, n) recordCon('Indifferent', line, n) end)
mq.event('PullConAmiable', '#1# judges you amiably#*#', function(line, n) recordCon('Amiably', line, n) end)
mq.event('PullConKindly', '#1# kindly considers you#*#', function(line, n) recordCon('Kindly', line, n) end)
mq.event('PullConWarmly', '#1# looks upon you warmly#*#', function(line, n) recordCon('Warmly', line, n) end)
mq.event('PullConAlly', '#1# regards you as an ally#*#', function(line, n) recordCon('Ally', line, n) end)

-- Confirmed working chat line (same text tac/swarm_pull.lua keys its own
-- "Fight when summoned" safety valve off of). Only meaningful during a
-- Swarm Pull gather (GATHER state checks and clears this); a summon any
-- other time doesn't need special handling here.
mq.event('PullerSummoned', 'You have been summoned!', function()
    if cfg.swarmEnabled and cfg.swarmFightOnSummon then
        state.swarmSummoned = true
    end
end)

-- Confirmed from the user's own MQ Combat log: "<name><verb> YOU for #
-- points of damage." (verb varies -- hits, kicks, crushes, etc. -- with no
-- fixed literal between the name and verb, so both are captured together
-- as one blob and split apart by resolveAttackerBlob() above instead of
-- here). Covers landed melee hits; a miss ("tries to X YOU, but misses!")
-- doesn't update this, but swings land often enough in practice that
-- detection still lands within a few seconds.
mq.event('PullerIncomingHit', '#1# YOU for #2# points of damage.', function(line, blob)
    local id = resolveAttackerBlob(blob)
    if id > 0 then
        state.lastHitById = id
        state.lastHitAt = os.clock()
    end
end)

-- E3Next's ${E3N...} isn't a real MacroQuest TLO -- it's evaluated by E3's
-- own parser via /e3echo, not reachable from Lua as mq.TLO.E3N. Same trick
-- as the con-color capture above: fire /e3echo with a uniquely-prefixed
-- string (so this can't collide with normal chat) and catch the printed
-- result here instead. TRUE/FALSE spelling is a guess (handles a few
-- common variants); mobToAttack/stickTarget assumed to print as plain
-- numeric spawn ids -- tonumber() just yields 0 if that guess is wrong,
-- which safely degrades to "nothing reported" rather than erroring.
-- Confirmed live (2026-10-10): Enabled/StickTarget print "True"/"False"
-- (C#'s bool.ToString(), makes sense -- E3 is a .NET app under MQ2Mono),
-- and StickTarget is itself a bool ("are we currently stuck to a target"),
-- NOT a spawn id as the name suggested -- MobToAttack is the only actual id.
local function parseE3Bool(v)
    local s = tostring(v or ''):lower()
    return s == 'true' or s == '1' or s == 'yes' or s == 'on'
end

mq.event('PullerE3State', 'PullerE3Check:#1#:#2#:#3#', function(line, enabled, mob, stick)
    state.e3Enabled = parseE3Bool(enabled)
    state.e3MobToAttack = tonumber(mob) or 0
    state.e3Sticking = parseE3Bool(stick)
    state.e3UpdatedAt = os.clock()
end)

-- Non-blocking: fires one /consider per name at most every 2s; the caller
-- re-checks every tick so a blocked tier drops the target on the next pass.
local function verifyTargetCon(id)
    if not id or id <= 0 then return true end
    if isOnXTarget(id) then return true end
    local t = mq.TLO.Target
    if not t() or (t.ID() or 0) ~= id then return true end
    local cname = t.CleanName()
    if not cname or cname == '' then return true end

    if not state.conCache[cname] then
        local now = os.clock()
        if (now - (state.conAskedAt[cname] or 0)) >= 2.0 then
            state.conAskedAt[cname] = now
            mq.cmd('/consider')
        end
        return true
    end
    local tier = state.conCache[cname]
    if cfg.conFilter[tier] == false then return false end
    return true
end

-- ----------------------------------------------------------------------------
-- Navigation: plain /nav, with a simple "no progress -> give up" timeout
-- instead of the original's full stuck/hazard/mesh-isolation recovery.
-- ----------------------------------------------------------------------------
local NAV_STALL_SEC = 20

-- Below this distance, telling MQ2Nav to walk "closer" via distance=N is
-- usually a no-op -- you're already inside N, so there's nowhere left for
-- it to walk you. That's exactly the "standing right next to it and still
-- no LOS" case (a thin wall/pillar/door-frame sliver, a stairwell seam):
-- the fix isn't "get closer", it's "reposition" -- back off a bit so the
-- next approach repaths from a different angle (and often backing off
-- alone is enough to open sight, without even needing to re-approach).
local NAV_LOS_POINTBLANK = 10
local NAV_LOS_BACKOFF_MAX = 2

-- A single, simple unstuck nudge -- not the original's full timed
-- back/strafe/jump state machine, just one brief backward step and a jump
-- to try to break free of a wall/lip before giving up on the mob entirely.
-- Commands verified against triune.lua's own performUnstuck().
local function attemptUnstuck()
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
    mq.cmd('/keypress back hold')
    mq.delay(500)
    mq.cmd('/keypress jump')
    mq.delay(200)
    mq.cmd('/keypress back')
end

-- Walks straight away from the mob (not a random/forward direction), so a
-- point-blank LOS block gets a real repath instead of a no-op. Falls back
-- to an arbitrary direction only in the degenerate case of being stacked
-- exactly on the mob's own coordinates.
local function navBackoffFromId(id, backDist)
    local mx, my = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0
    local sx, sy = mx, my
    pcall(function() sx, sy = mq.TLO.Spawn(id).X() or mx, mq.TLO.Spawn(id).Y() or my end)
    local dx, dy = mx - sx, my - sy
    local dlen = math.sqrt(dx * dx + dy * dy)
    if dlen < 0.5 then dx, dy, dlen = 1, 0, 1 end
    local ux, uy = dx / dlen, dy / dlen
    mq.cmdf('/nav locyx %.2f %.2f', my + uy * backDist, mx + ux * backDist)
end

-- approach (optional, defaults to dist): how close /nav actually walks in.
-- Melee passes something inside dist so arrival lands mid-range rather than
-- on its edge (see pullApproach).
local function navTowardId(id, dist, approach)
    approach = approach or dist
    local d = distToId(id)
    local inRange = d <= dist
    local los = hasLos(id)
    -- "Arrived" needs BOTH: close enough per `dist`, and actual line of
    -- sight. Distance alone is a straight-line check -- being within pull
    -- reach on the far side of a wall/door still can't actually be hit, so
    -- a ranged/spell/item pull just sits there re-firing and never gets
    -- aggro. Keep treating that as "not there yet" so navigation stays
    -- engaged and routes us around whatever's blocking sight.
    if inRange and los then
        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        state.navLosBackoffCount = 0
        return true, true
    end
    if d < state.navBestDist - 2 then
        state.navBestDist = d
        state.navBestAt = os.clock()
    elseif (os.clock() - state.navBestAt) > NAV_STALL_SEC then
        if not state.navUnstuckTried then
            state.navUnstuckTried = true
            printf(inRange and 'In range but no line of sight for %ds -- trying to get unstuck.'
                or 'No progress for %ds -- trying to get unstuck before giving up.', NAV_STALL_SEC)
            attemptUnstuck()
            state.navBestAt = os.clock() -- one more full window after the nudge
            return false, true
        end
        return false, false
    end
    if navLoaded() and not mq.TLO.Navigation.Active() then
        if inRange and not los then
            if d <= NAV_LOS_POINTBLANK and (state.navLosBackoffCount or 0) < NAV_LOS_BACKOFF_MAX then
                state.navLosBackoffCount = (state.navLosBackoffCount or 0) + 1
                printf('Point-blank but no line of sight -- backing off to try a different angle (%d/%d).',
                    state.navLosBackoffCount, NAV_LOS_BACKOFF_MAX)
                navBackoffFromId(id, (dist or 20) + 15)
            else
                -- Already within reach but blocked, and not point-blank (or
                -- already tried backing off) -- push in close to the mob
                -- itself (not just to `dist`) so the mesh paths around a
                -- corner/doorway instead of parking somewhere it can't see.
                mq.cmdf('/nav id %d distance=5', id)
            end
        else
            mq.cmdf('/nav id %d distance=%d', id, math.floor(approach))
        end
    end
    return false, true
end

local function navTowardLoc(x, y, z, dist)
    local d = distToLoc(x, y, z)
    if d <= dist then
        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        return true
    end
    if navLoaded() and not mq.TLO.Navigation.Active() then
        local locStr = string.format('loc %.2f %.2f %.2f', y, x, z)
        local ok, exists = pcall(function() return mq.TLO.Navigation.PathExists(locStr)() end)
        if ok and exists then
            mq.cmdf('/nav %s', locStr)
        else
            mq.cmdf('/nav locyx %.2f %.2f', y, x)
        end
    end
    return false
end

-- ----------------------------------------------------------------------------
-- Target scanning
-- ----------------------------------------------------------------------------
-- Where to anchor the search and how far out to allow it. While Waypoint
-- Patrol is active the anchor circle is dropped entirely (same as the
-- original): scan dynamically around wherever the patrol currently is,
-- bounded only by waypointScanRadius. Also returns the arc width/heading
-- for the current mode (0/nil = no arc restriction, full circle).
local function currentAnchor()
    if cfg.useWaypoints and cfg.waypoints and #cfg.waypoints > 0 then
        return nil, cfg.waypointScanRadius or 100, 0, nil
    end
    if cfg.pullMode == 'Hunt' then
        if cfg.huntAnchor and (cfg.huntRadius or 0) > 0 then
            return cfg.huntAnchor, cfg.huntRadius, cfg.huntArcWidth or 0, cfg.huntHeading
        end
        -- Unrestricted (radius 0 / no anchor) means zone-wide: nil radius,
        -- and findPullTarget drops the radius clause entirely. This used to
        -- borrow waypointScanRadius (a Waypoints-tab setting, 100 by
        -- default), so "unlimited" really meant "100 around you" -- one
        -- pull cleared that bubble and it never found anything again.
        return nil, nil, 0, nil
    end
    return cfg.campLoc, cfg.campRadius or 100, cfg.campArcWidth or 0, cfg.campHeading
end

-- Restricts pulls to a directional cone from the anchor, like KissAssist's
-- /setpullarc: widthDeg is the FULL arc width (0 or >=360 = disabled).
-- Dot-product half-angle check against the facing unit vector (fx,fy) in
-- EQ's world X/Y (Y is North, X is West; heading 0=North(+Y)).
-- triune.lua's runtime.isHeadingInForwardCone uses fx,fy = sin(h), cos(h)
-- here (claiming heading 90 = West), but a live in-game test of the arc
-- preview below showed heading ~90 is actually facing EAST, not West --
-- i.e. that formula has East/West (X) mirrored. North/South (Y) checked
-- out fine, so only the X component is negated here.
local function inPullArc(originX, originY, headingDeg, widthDeg, tx, ty)
    local dx, dy = tx - originX, ty - originY
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= 0.001 then return true end
    local vx, vy = dx / dist, dy / dist
    local hRad = math.rad(headingDeg)
    local fx, fy = -math.sin(hRad), math.cos(hRad)
    local dot = fx * vx + fy * vy
    local minDot = math.cos(math.rad(widthDeg / 2))
    return dot >= minDot
end

-- ----------------------------------------------------------------------------
-- Priority Kill List: per-zone names that jump the queue in findPullTarget
-- below (closest-match-among-priority-names wins over everything else),
-- without bypassing any of the existing filters -- still has to pass level/
-- con/anchor-radius/arc/path-exists like any other candidate.
-- ----------------------------------------------------------------------------
local function currentZoneShortName()
    local zs = ''
    pcall(function() zs = mq.TLO.Zone.ShortName() or '' end)
    return zs
end

-- Read-only: the current zone's list, or nil if it has none / the feature's
-- namesoff. Callers that need to MUTATE the list use ensurePriorityList.
local function currentPriorityList()
    if not cfg.priorityEnabled then return nil end
    local zs = currentZoneShortName()
    if zs == '' then return nil end
    local list = cfg.priorityLists[zs]
    if type(list) ~= 'table' or #list == 0 then return nil end
    return list
end

-- Creates the current zone's list on first use (Add button), independent
-- of cfg.priorityEnabled -- you should be able to build a list for a zone
-- before switching the feature on.
local function ensurePriorityList()
    local zs = currentZoneShortName()
    if zs == '' then return nil end
    if type(cfg.priorityLists[zs]) ~= 'table' then cfg.priorityLists[zs] = {} end
    return cfg.priorityLists[zs]
end

local function isPriorityName(cleanName)
    local list = currentPriorityList()
    if not list or not cleanName then return false end
    local lname = cleanName:lower()
    for _, n in ipairs(list) do
        if tostring(n):lower() == lname then return true end
    end
    return false
end

-- extraExclude(sid), if given, is an additional per-candidate skip check on
-- top of the usual filters -- used by Swarm Pull's GATHER to skip anything
-- already aggro'd (on XTarget) or already failed this gather batch, without
-- duplicating all of the level/con/anchor/arc/path filtering above.
local function findPullTarget(extraExclude)
    local anchor, radius, arcWidth, arcHeading = currentAnchor()
    local now = os.clock()
    -- Defensive: a hand-edited or stale config with Min > Max would make
    -- every mob fail this filter forever with no visible symptom beyond
    -- "never pulls anything" -- the UI clamps this now, but normalize here
    -- too rather than trust that's the only way these got set.
    local minLevel = math.min(cfg.minLevel or 1, cfg.maxLevel or 100)
    local maxLevel = math.max(cfg.minLevel or 1, cfg.maxLevel or 100)
    local zradius = (cfg.pullMode == 'Hunt') and (cfg.huntZ or 75) or (cfg.campZ or 75)
    local scanRadius = radius -- nil = unrestricted Hunt: no radius clause, whole zone
    if anchor then
        -- NearestSpawn's own radius filter is relative to the PLAYER, not
        -- the anchor. Standing near the far edge of the anchor circle with
        -- a plain player-centered query of `radius` units can miss mobs on
        -- the opposite side even though they're well inside the circle.
        -- No point inside the anchor circle is ever farther from the
        -- player than (distance from player to anchor) + radius, so widen
        -- the query to that worst case; the inAnchor check below still
        -- does the real circle filtering.
        local mx, my = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0
        local dx, dy = mx - anchor.x, my - anchor.y
        scanRadius = math.ceil(math.sqrt(dx * dx + dy * dy) + radius)
    end
    local p = scanRadius
        and string.format('npc radius %d zradius %d targetable', scanRadius, zradius)
        or string.format('npc zradius %d targetable', zradius)
    local mx, my, mz = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0
    -- Ranked by WALKING distance (MQ2Nav PathLength), not straight-line:
    -- a mob 40 units away on the other side of a wall can be a 600-unit
    -- walk around the instance, and straight-line ranking happily picked it
    -- over one 80 units away down an open hall. Straight-line distance is
    -- only the fallback when nav isn't loaded or a length can't be had.
    --
    -- PathLength is a full path computation per candidate, so this stops
    -- early: NearestSpawn hands candidates back nearest-first by flat
    -- distance, and no walk is ever shorter than the flat distance, so once
    -- a candidate's flat distance reaches the best walk found so far, no
    -- later candidate can beat it. (Skipped while a priority list is in
    -- play -- a priority name further out still has to be found.)
    local bestId, bestDist = nil, math.huge
    -- Priority Kill List candidates are tracked separately and, if any
    -- qualify, win over bestId entirely at the end -- closest-among-
    -- priority-names, not closest-overall. Still has to pass every filter
    -- below same as anything else; this only changes which one gets picked.
    local bestPriorityId, bestPriorityDist = nil, math.huge
    local hasPriority = currentPriorityList() ~= nil
    local useNav = navLoaded()
    for i = 1, 60 do
        local s = mq.TLO.NearestSpawn(i, p)
        if not s() then break end
        local sid = s.ID() or 0
        local sx, sy, sz = s.X() or 0, s.Y() or 0, s.Z() or 0
        if bestId and not hasPriority then
            local fdx, fdy = sx - mx, sy - my
            if math.sqrt(fdx * fdx + fdy * fdy) >= bestDist then break end
        end
        local until_ = sid > 0 and state.tempIgnore[sid]
        if sid > 0 and not (until_ and until_ > now) and not (extraExclude and extraExclude(sid)) then
            local slvl = s.Level() or 0
            if slvl >= minLevel and slvl <= maxLevel and isHostileNpc(sid) then
                local inAnchor = true
                if anchor then
                    local dx, dy = sx - anchor.x, sy - anchor.y
                    inAnchor = (dx * dx + dy * dy) <= (radius * radius)
                    if inAnchor and arcHeading and arcWidth and arcWidth > 0 and arcWidth < 360 then
                        inAnchor = inPullArc(anchor.x, anchor.y, arcHeading, arcWidth, sx, sy)
                    end
                end
                if inAnchor then
                    local cname = s.CleanName()
                    local tier = cname and state.conCache[cname]
                    if not tier or cfg.conFilter[tier] ~= false then
                        local ddx, ddy, ddz = sx - mx, sy - my, sz - mz
                        local dist = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
                        if useNav then
                            local ok, plen = pcall(function()
                                return tonumber(mq.TLO.Navigation.PathLength('id ' .. sid)())
                            end)
                            if ok and plen and plen > 0 then
                                dist = plen
                            else
                                -- No length back (MQ2Nav answers -1 for no
                                -- path): confirm reachability the old way
                                -- before trusting straight-line distance.
                                local ok2, exists = pcall(function() return mq.TLO.Navigation.PathExists('id ' .. sid)() end)
                                if ok2 and not exists then goto continue end
                            end
                        end
                        if dist < bestDist then
                            bestDist = dist
                            bestId = sid
                        end
                        if isPriorityName(cname) and dist < bestPriorityDist then
                            bestPriorityDist = dist
                            bestPriorityId = sid
                        end
                    end
                end
            end
        end
        ::continue::
    end
    return bestPriorityId or bestId
end

-- Walks cfg.waypoints in order (looping, or ping-ponging at the ends),
-- same idea as the original wpTick(). Called from IDLE when no target is
-- in range.
local function patrolTick()
    local wps = cfg.waypoints
    if not wps or #wps == 0 then return false end
    if not state.wpIndex or state.wpIndex < 1 or state.wpIndex > #wps then state.wpIndex = 1 end
    local wp = wps[state.wpIndex]
    if not wp then return false end

    local radius = cfg.waypointRadius or 20
    if distToLoc(wp.x, wp.y, wp.z) <= radius then
        -- Arrival: run this waypoint's command once and start its delay.
        -- wpArrivedIdx (cleared only once we're outside the radius again)
        -- keeps a single-waypoint route, or coming back from a pull that
        -- interrupted the wait, from re-firing the command every tick.
        if state.wpArrivedIdx ~= state.wpIndex then
            state.wpArrivedIdx = state.wpIndex
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            if wp.cmd and wp.cmd ~= '' then
                printf('Waypoint %d (%s): %s', state.wpIndex, wp.name or '?', wp.cmd)
                mq.cmd(wp.cmd)
            end
            state.wpWaitUntil = os.clock() + (tonumber(wp.delay) or 0)
        end
        -- Holding here: IDLE still scans for targets before calling this
        -- each tick, so a mob showing up mid-delay still gets pulled.
        if os.clock() < state.wpWaitUntil then return true end

        local prevIdx = state.wpIndex
        if #wps <= 1 then
            state.wpIndex = 1
        elseif cfg.waypointLoop then
            state.wpIndex = (prevIdx % #wps) + 1
        else
            local dir = state.wpDirection or 1
            local nextIdx = prevIdx + dir
            if nextIdx > #wps then
                dir = -1; nextIdx = math.max(1, #wps - 1)
            elseif nextIdx < 1 then
                dir = 1; nextIdx = math.min(#wps, 2)
            end
            state.wpDirection = dir
            state.wpIndex = nextIdx
        end
        local nextWp = wps[state.wpIndex]
        if nextWp then navTowardLoc(nextWp.x, nextWp.y, nextWp.z, radius) end
    else
        state.wpArrivedIdx = nil
        navTowardLoc(wp.x, wp.y, wp.z, radius)
    end
    return true
end

-- ----------------------------------------------------------------------------
-- Pull tagging
-- ----------------------------------------------------------------------------
-- Two fractions of melee range, not one: "in range" is checked at
-- CHECK_FRAC, but the approach walks in to APPROACH_FRAC. Navigating to
-- exactly the cutoff parked you right on the edge, where half a step from
-- the mob put you out of range for abilities (Flying Kick etc) while this
-- still read "arrived" and didn't move.
-- Deliberately a fixed base, NOT Spawn.MaxRangeTo()/MaxMeleeTo(): those
-- call into the EQ client's own melee-range function, and polling them
-- every tick crashed the client on this emu build within minutes
-- (2026-10-16). 12 is EQ's melee range between two normal-size (6)
-- models; smaller models get more, so this is the conservative case.
local MELEE_RANGE_BASE = 12
local MELEE_CHECK_FRAC = 0.9
local MELEE_APPROACH_FRAC = 0.65

local function meleeRange(id)
    return MELEE_RANGE_BASE
end

local function pullReach(id)
    local style = cfg.pullStyle or 'Melee'
    if style == 'Melee' then return meleeRange(id) * MELEE_CHECK_FRAC end
    local reach = cfg.engageDist or 100
    local cap = 0
    if style == 'Spell' and cfg.pullSpell ~= '' then
        pcall(function() cap = tonumber(mq.TLO.Spell(cfg.pullSpell).Range()) or 0 end)
    elseif style == 'Ranged' then
        pcall(function()
            local r = mq.TLO.Me.Inventory('ranged')
            if r() then
                cap = tonumber(r.Range()) or 0
                local a = mq.TLO.Me.Inventory('ammo')
                if a() then cap = cap + (tonumber(a.Range()) or 0) end
            end
        end)
    end
    if cap > 0 and cap < reach then return cap end
    return reach
end

-- How close to navigate before calling it there -- deeper than pullReach
-- for Melee (see MELEE_APPROACH_FRAC above), unchanged for other styles.
local function pullApproach(id)
    if (cfg.pullStyle or 'Melee') == 'Melee' then
        return math.max(4, math.floor(meleeRange(id) * MELEE_APPROACH_FRAC))
    end
    return math.floor(pullReach(id))
end

-- FIGHTING's own "close the gap" helper for Melee pulls, separate from
-- navTowardId on purpose: once you're actually FIGHTING there's no "give
-- up and blacklist the mob" concept the way there is while still pulling
-- (TO_MOB) -- something may well already be hitting you. This just keeps
-- trying to get in range + LOS for as long as the fight lasts, reusing the
-- same point-blank backoff for a thin-wall/pillar LOS block, without
-- touching navTowardId's own stall/unstuck/give-up counters.
local function meleeCloseOnTarget(id)
    local reach = pullReach(id)
    local approach = pullApproach(id)
    local d = distToId(id)
    local inRange = d <= reach
    local los = hasLos(id)
    -- fireTag() does this for every OTHER style (Ranged/Spell/Item) every
    -- tick, but fireTag only ever runs during the initial TO_MOB tag-up --
    -- never again once FIGHTING begins. Melee never got its own equivalent,
    -- so nothing re-faced you toward a mob that repositions mid-fight (an
    -- AE golem walking around you, a knockback, etc.) -- it'd just end up
    -- hitting your back with nothing correcting it. /face is a cheap,
    -- idempotent snap-to, safe to call every tick while in range.
    if inRange then mq.cmd('/face fast') end
    if inRange and los then
        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        return true
    end
    if navLoaded() and not mq.TLO.Navigation.Active() then
        if inRange and not los and d <= NAV_LOS_POINTBLANK then
            navBackoffFromId(id, reach + 15)
        else
            mq.cmdf('/nav id %d distance=%d', id, inRange and 5 or approach)
        end
    end
    return false
end

local function haveAggro(id)
    if isOnXTarget(id) then return true end
    local t = mq.TLO.Target
    if t() and t.ID() == id then
        local totId, pct = 0, 0
        pcall(function() totId = t.TargetOfTarget.ID() or 0 end)
        if totId == (mq.TLO.Me.ID() or -1) then return true end
        pcall(function() pct = t.PctAggro() or 0 end)
        if pct >= 100 then return true end
    end
    return false
end

local function fireTag(id)
    local style = cfg.pullStyle or 'Melee'
    if mq.TLO.Target.ID() ~= id then mq.cmdf('/target id %d', id) end
    if style == 'Melee' then
        if not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
    elseif style == 'Ranged' then
        -- The actual ranged-weapon attack (bow/thrown item in the Ranged
        -- slot) is /autofire, not /attack (melee) or the Monk-only Throw
        -- Stone skill. It's a toggle, not a fire-once command -- the client
        -- keeps firing on its own once it's on, same as syncAutoAttack()
        -- elsewhere in this file already expects (it reads Me.AutoFire()
        -- and turns it off once nothing hostile is left). /attack would
        -- turn autofire back off, so it's deliberately not used here.
        mq.cmd('/face fast')
        local fireOn = false
        pcall(function() fireOn = mq.TLO.Me.AutoFire() end)
        if not fireOn then mq.cmd('/autofire on') end
    elseif style == 'Spell' then
        mq.cmd('/face fast')
        if cfg.pullSpell ~= '' and mq.TLO.Me.Casting() == nil then
            mq.cmdf('/cast "%s"', cfg.pullSpell)
        end
    elseif style == 'Item' then
        mq.cmd('/face fast')
        if cfg.pullItem ~= '' then
            -- TimerReady() is the item's recast timer: 0 means ready to use.
            -- Without this, a clicky with a cast time or recast would get
            -- re-clicked (and fail) every tick until it actually lands.
            local ready = true
            pcall(function() ready = (tonumber(mq.TLO.FindItem(cfg.pullItem).TimerReady()) or 0) == 0 end)
            if ready then mq.cmdf('/useitem "%s"', cfg.pullItem) end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Resource gate (hysteresis, same shape as triune's MedBreak)
-- ----------------------------------------------------------------------------
local function checkRestGate()
    if not cfg.restEnabled then
        if state.resting then
            state.resting = false
            if isSittingOrDucking() then mq.cmd('/stand') end
        end
        return false
    end

    local hp = mq.TLO.Me.PctHPs() or 100
    local mp = mq.TLO.Me.PctMana() or 0
    local ep = mq.TLO.Me.PctEndurance() or 0
    local hasMana = (mq.TLO.Me.MaxMana() or 0) > 0
    local hasEnd = (mq.TLO.Me.MaxEndurance() or 0) > 0
    local fighting = inCombat()

    if not state.resting then
        local trigger = (cfg.hpOn and hp <= cfg.hpStart)
            or (cfg.manaOn and hasMana and mp <= cfg.manaStart)
            or (cfg.endOn and hasEnd and ep <= cfg.endStart)
        if trigger and not fighting then
            state.resting = true
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            if state.pullState == 'TO_MOB' or state.pullState == 'IDLE' then
                state.pullState = 'IDLE'; state.pullTargetId = 0
            end
            printf('Resting: HP %d%% MP %d%% EP %d%% below threshold -- pausing pulls until recovered.', hp, mp, ep)
            if canSitNow() and not isSittingOrDucking() then mq.cmd('/sit') end
            return true
        end
        return false
    else
        if fighting then
            -- Debounced: inCombat() includes some noisy/stale signals
            -- (a lingering XTarget hate entry, group-wide hater/aggro
            -- counts, CombatState lag). A single flickering tick used to
            -- stand you up, then immediately sit back down next tick since
            -- resources hadn't actually recovered -- bouncing. Require the
            -- signal to hold for a bit before treating it as a real attack.
            state.restFightingSince = state.restFightingSince or os.clock()
            if (os.clock() - state.restFightingSince) >= 1.0 then
                state.resting = false
                state.restFightingSince = nil
                if isSittingOrDucking() then mq.cmd('/stand') end
                return false
            end
            return true
        end
        state.restFightingSince = nil
        local hpOk = (not cfg.hpOn) or hp >= cfg.hpStop
        local mpOk = (not cfg.manaOn) or (not hasMana) or mp >= cfg.manaStop
        local epOk = (not cfg.endOn) or (not hasEnd) or ep >= cfg.endStop
        if hpOk and mpOk and epOk then
            state.resting = false
            if isSittingOrDucking() then mq.cmd('/stand') end
            printf('Recovered -- resuming pulls.')
            return false
        end
        if canSitNow() and not isSittingOrDucking() then mq.cmd('/sit') end
        return true
    end
end

-- ----------------------------------------------------------------------------
-- EQ map circle: a persistent MQ2Map "MapLoc" marker+circle pinned to the
-- actual camp/anchor point -- /maploc takes an arbitrary yloc/xloc/zloc plus
-- its own radius and radius color, independent of the player's position
-- (confirmed from MQ2Map.dll's own usage string: "/maploc [[size] [width]
-- [color r g b] [radius <distance>] [rcolor r g b] [yloc xloc (zloc) |
-- target]] [label text]", plus "Updating existing loc" / "/maploc remove
-- [index | [yloc xloc (zloc)]]"). Unlike the earlier CastRadius approach,
-- this does NOT need re-issuing every tick -- only when the anchor point or
-- radius actually changes -- and stays pinned while you travel away from
-- camp instead of following you. Shown whether or not pulling is started,
-- so the radius can be previewed/adjusted before hitting Start.
-- ----------------------------------------------------------------------------
local function currentAnchorLoc()
    if cfg.pullMode == 'Camp' then
        return cfg.campLoc, cfg.campRadius or 0
    end
    if cfg.huntAnchor and (cfg.huntRadius or 0) > 0 then
        return cfg.huntAnchor, cfg.huntRadius
    end
    return nil, 0 -- no camp set yet, or Hunt roaming unrestricted: nothing to anchor to
end

-- Two independent /maploc markers share this: the red pull/hunt radius
-- (state.mapLoc*) and the green Camp Safe Radius (state.safeLoc*). Each is
-- tracked by the exact y/x/z it was drawn at, since that's what /maploc
-- remove matches on.
local function removeLoc(locKey, radKey)
    local cur = state[locKey]
    if cur then
        mq.cmdf('/maploc remove %.2f %.2f %.2f', cur.y, cur.x, cur.z)
        state[locKey] = nil
        state[radKey] = nil
    end
end

local function syncLoc(locKey, radKey, loc, radius, rgb, label)
    if not loc or not radius or radius <= 0 then
        removeLoc(locKey, radKey)
        return
    end
    local cur = state[locKey]
    local moved = not cur
        or math.abs(cur.x - loc.x) > 0.5
        or math.abs(cur.y - loc.y) > 0.5
        or math.abs(cur.z - loc.z) > 0.5
    if moved or state[radKey] ~= radius then
        -- Anchor moved: the old marker would be orphaned at the old spot.
        if cur and moved then removeLoc(locKey, radKey) end
        mq.cmdf('/maploc %.2f %.2f %.2f size 10 color %s radius %d rcolor %s label %s',
            loc.y, loc.x, loc.z, rgb, radius, rgb, label)
        state[locKey] = { x = loc.x, y = loc.y, z = loc.z }
        state[radKey] = radius
    end
end

local function removeMapLocCircle()
    removeLoc('mapLocLoc', 'mapLocRadius')
    removeLoc('safeLocLoc', 'safeLocRadius')
end

local function syncMapCircle()
    if not cfg.showMapCircle then
        removeMapLocCircle()
        return
    end
    local loc, radius = currentAnchorLoc()
    syncLoc('mapLocLoc', 'mapLocRadius', loc, radius, '255 0 0', 'Puller')
    -- Green Camp Safe Radius, Camp mode only. Drawn 1 unit off the camp
    -- point: /maploc matches an existing marker by its coordinates ("Updating
    -- existing loc"), so a second marker at the exact same spot would just
    -- overwrite the red one instead of adding a circle. 1 unit is invisible
    -- at map scale.
    local safeLoc = nil
    if cfg.pullMode == 'Camp' and cfg.campLoc then
        safeLoc = { x = cfg.campLoc.x, y = cfg.campLoc.y + 1, z = cfg.campLoc.z }
    end
    syncLoc('safeLocLoc', 'safeLocRadius', safeLoc, cfg.campSafeRadius or 0, '0 255 0', 'Camp_Safe')
end

-- E3Next (the combat script onEngageCommand usually hands off to) exposes
-- its ClearXTargets ("stick to whatever's hating you") state via its own
-- /e3echo parser, not a real MacroQuest TLO -- see the PullerE3State event
-- above for how it's actually read. Reading this tells us exactly which mob
-- E3Next already has, instead of guessing from auto-attack/casting toggles:
-- when E3Next already has an add as its target there's no reason to
-- interrupt it with another /cleartargets stick for the same mob.
local E3_QUERY_INTERVAL = 1.0  -- seconds between /e3echo queries
local E3_STALE_AFTER = 3.0     -- no reply in this long -> treat as unknown

local function queryE3State()
    local now = os.clock()
    if now - state.lastE3QueryAt < E3_QUERY_INTERVAL then return end
    state.lastE3QueryAt = now
    -- The brace must be backslash-escaped ($\{...}) so MQ's own top-level
    -- parser leaves it alone instead of trying to resolve "E3N...." as a
    -- real MQ TLO (which doesn't exist) before /e3echo ever sees the text.
    -- '$\\{' in this Lua source produces the literal characters $\{ here.
    -- /squelch suppresses MQ's own "command received:" echo of this line;
    -- it can't suppress /e3echo's own printed result (that's E3's output,
    -- not MQ's), so the PullerE3Check:... line will still show.
    mq.cmd('/squelch /e3echo PullerE3Check:$\\{E3N.State.ClearXTargets.Enabled}:' ..
        '$\\{E3N.State.ClearXTargets.MobToAttack}:$\\{E3N.State.ClearXTargets.StickTarget}')
end

-- Purely a bonus signal, not a hard dependency: returns "nothing to
-- report" (false, 0, false) if E3Next isn't running, the reply never
-- arrived, or it's gone stale, so this degrades safely to the
-- cooldown-only fallback.
local function clearXTargetsInfo()
    if os.clock() - state.e3UpdatedAt > E3_STALE_AFTER then
        return false, 0, false
    end
    return state.e3Enabled, state.e3MobToAttack, state.e3Sticking
end

-- Minimum time between the FIGHTING sweep announcing two different adds --
-- see the sweep itself for why this is a cooldown and not a hard gate.
local ENGAGE_ANNOUNCE_COOLDOWN = 3.0

-- How long melee will keep trying to reach/see its current chase target
-- before giving up on THAT ONE SPECIFICALLY and switching to a different
-- hostile already on XTarget (confirmed live: stuck on an LOS-blocked
-- target -- "You cannot see your target." repeating -- while two other
-- XTarget hostiles sat there unaddressed, actively hitting the player, the
-- whole time). meleeCloseOnTarget itself has no give-up logic of its own;
-- this wraps it with one at the FIGHTING-block level instead.
local MELEE_CHASE_STUCK_SEC = 15

-- Fires the on-engage command for one mob, once -- state.engagedIds tracks
-- which ids have already been announced this encounter so a multi-mob pull
-- (an add, an AE pull) gets the command fired once per mob instead of once
-- for the whole pull. Targets the mob first since a "stick"-style combat
-- command typically acts on whatever's currently targeted.
-- Returns true if this call actually fired (a genuinely new id), false if
-- it was already announced. Used by the FIGHTING sweep to stagger multiple
-- simultaneous new mobs rather than rapid-firing /target + the command
-- several times in the same instant, which could outrun a combat script
-- that isn't built to handle a burst of them.
local function announceEngage(id)
    if not id or id <= 0 or state.engagedIds[id] then return false end
    state.engagedIds[id] = true
    if not cfg.onEngageCommand or cfg.onEngageCommand == '' then return true end
    if mq.TLO.Target.ID() ~= id then mq.cmdf('/target id %d', id) end
    -- Visible on purpose: onEngageCommand otherwise runs completely silently,
    -- so there was no way to tell "never fired" apart from "fired but the
    -- combat script didn't react" from the logs alone.
    local nm = ''
    pcall(function() nm = mq.TLO.Spawn(id).CleanName() or '' end)
    printf('Engaging #%d (%s) via onEngageCommand.', id, nm ~= '' and nm or '?')
    mq.cmd(cfg.onEngageCommand)
    return true
end

-- Enters FIGHTING and fires the configured on-engage command exactly once
-- for the mob that triggered it, regardless of which transition got us here
-- (Camp or Hunt). Centralizing this keeps the command a single, deliberate
-- call per pull instead of something driven by a repeating external
-- condition. Always fires immediately, unlike the FIGHTING sweep below --
-- this is the "pull just landed, go fight" signal.
local function enterFighting(id)
    -- A gather ending (count reached, summon, HP abort, nothing left) left
    -- pullTargetId on whichever candidate it was still WALKING to -- often
    -- far off and not even aggro'd yet -- and melee then chased that one
    -- across the zone with a pile already on XTarget. Drop it so melee's
    -- reselect picks the nearest actual hater instead.
    if not id and state.pullState == 'GATHER' then state.pullTargetId = 0 end
    if id then state.pullTargetId = id end
    state.pullState = 'FIGHTING'
    -- Camp mode: an add that aggroed from out past the Camp Safe Radius
    -- isn't handed to the combat script yet -- the FIGHTING block picks it
    -- up (and fires onEngageCommand) once it walks into camp.
    local announced = id and inCampSafeZone(id)
    if announced then announceEngage(id) end
    -- Sync melee's own chase-switch tracker (FIGHTING block, below) to
    -- whatever's becoming the active target right now -- whether id was
    -- given here (it was just announced on the line above) or this is a
    -- Camp-mode arrival where id is nil and pullTargetId was already set
    -- by TO_CAMP's drag (the FIGHTING sweep will announce it on its very
    -- next tick instead). Either way, without this, the melee block's own
    -- "did the active target change" check still sees lastChaseId at its
    -- old/zeroed value on the first FIGHTING tick and fires onEngageCommand
    -- a SECOND time for the exact same fresh engagement.
    -- Only when id was actually announced above, though: with id nil (a
    -- swarm gather ending, a Camp arrival), nothing has fired for
    -- pullTargetId yet. For Melee the FIGHTING sweep no longer announces
    -- (the chase block owns onEngageCommand), so lastChaseId has to stay 0
    -- here or the chase block would think its first target was already
    -- handed off and never fire for it at all.
    state.lastChaseId = announced and state.pullTargetId or 0
    state.meleeChaseStuckSince = nil
end

-- Manual escape hatch for a pull stuck in range but unable to land a hit
-- because of line of sight (navTowardId's auto-retry eventually gives up
-- and moves on, but this skips straight to fighting right now instead of
-- waiting on that -- for when you've walked around the corner yourself and
-- just want the script to take over). Shared by /puller force and the
-- "Force Engage" button; defined up here (not down by cmd_puller) so both
-- can call it without a forward-reference to a not-yet-defined local.
local function forceEngage()
    local id = 0
    pcall(function() id = mq.TLO.Target.ID() or 0 end)
    if id <= 0 or not isHostileNpc(id) then id = state.pullTargetId end
    if not id or id <= 0 or not isHostileNpc(id) then
        printf('No valid hostile target to force -- target the mob first.')
        return
    end
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
    if mq.TLO.Target.ID() ~= id then mq.cmdf('/target id %d', id) end
    state.engagedIds = {}
    state.lastAnnounceAt = 0
    -- "Fight this now" means now, wherever it is -- Camp Safe Radius or not.
    state.campSafeBypassId = id
    enterFighting(id) -- also syncs lastChaseId to id
    printf('Forced engagement on #%d.', id)
end

-- Shared by /puller stop|pause and the UI Stop button; defined up here (not
-- down by cmd_puller) so both can call it without a forward-reference to a
-- not-yet-defined local, same reasoning as forceEngage() above.
-- Previously both call sites just flipped cfg.enabled, leaving any in-flight
-- nav command running and leftover chase/gather/engage bookkeeping in place
-- for the next /puller start to pick back up as if nothing happened.
local function stopPulling()
    cfg.enabled = false
    saveCfg()
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
    state.pullState = 'IDLE'
    state.pullTargetId = 0
    state.lastChaseId = 0
    state.meleeChaseStuckSince = nil
    state.engagedIds = {}
    state.lastAnnounceAt = 0
    state.swarmSkip = {}
    state.swarmSummoned = false
    state.swarmTagged = false
    state.swarmAggroSince = nil
    state.campSafeBypassId = 0
    state.lootWaitSince = nil
end

-- Periodic console status line, gated behind cfg.debugEnabled (Settings tab
-- checkbox) -- for seeing live WHY nothing seems to be happening (what
-- state it's in, what it's chasing, whether it has LOS/is in range, what
-- XTarget actually shows) without needing a screenshot each time.
local function printDebugStatus()
    local now = os.clock()
    if now - state.lastDebugAt < 2.0 then return end
    state.lastDebugAt = now

    local tgtId = state.pullTargetId or 0
    local tgtName, tgtDist, tgtLos = '-', 0, '-'
    if tgtId > 0 then
        pcall(function() tgtName = mq.TLO.Spawn(tgtId).CleanName() or '?' end)
        tgtDist = distToId(tgtId)
        tgtLos = hasLos(tgtId) and 'yes' or 'no'
    end

    local combat, autofire = false, false
    pcall(function() combat = mq.TLO.Me.Combat() end)
    pcall(function() autofire = mq.TLO.Me.AutoFire() end)

    local xtHostiles = 0
    local slots = mq.TLO.Me.XTargetSlots() or 13
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        if xt() and (xt.ID() or 0) > 0 and isHostileNpc(xt.ID()) then xtHostiles = xtHostiles + 1 end
    end

    local swarmInfo = ''
    if cfg.swarmEnabled then
        swarmInfo = string.format(' | swarmHaters=%d/%d', countSwarmHaters(), cfg.swarmCount or 1)
    end

    -- Printed every line (not just once) on purpose: this is exactly the
    -- info needed to answer "why did it pull THAT mob" (wrong anchor?
    -- radius bigger than I think? an arc I forgot was still set?) without
    -- having to separately check the UI mid-fight.
    local anchor, radius, arcWidth, arcHeading = currentAnchor()
    local anchorInfo = anchor
        and string.format('anchor=(%.0f,%.0f) r=%.0f arc=%.0f@%.0f', anchor.y, anchor.x, radius or 0,
            arcWidth or 0, arcHeading or 0)
        or (radius and string.format('anchor=none r=%.0f(scan cap)', radius) or 'anchor=none r=unrestricted')

    printf('DEBUG enabled=%s resting=%s mode=%s %s state=%s target=#%d(%s) dist=%.0f los=%s combat=%s autofire=%s xtHostiles=%d%s hp=%d%%',
        tostring(cfg.enabled), tostring(state.resting), cfg.pullMode, anchorInfo, state.pullState, tgtId, tgtName, tgtDist, tgtLos,
        tostring(combat), tostring(autofire), xtHostiles, swarmInfo, math.floor(mq.TLO.Me.PctHPs() or 0))
end

-- Starts a post-fight loot wait (no-op unless Wait for loot is on).
local function beginLootWait()
    if not cfg.lootWaitEnabled then return end
    state.lootWaitSince = os.clock()
    state.lootSeenAt = nil
end

-- True while IDLE should hold for looting. Phases, in order:
--   1. LootWnd open -> looting right now.
--   2. Seen open this wait and closed less than lootGapGrace ago -> the
--      looter is on its way to the next corpse.
--   3. Nothing seen yet, still inside lootStartGrace, and NPC corpses are
--      nearby -> give the looter its chance to start (E3 waits ~2s after a
--      fight). With no corpses in range there's nothing to wait for.
-- lootMaxWait caps the whole thing. The radius/height match E3's own
-- corpse search (Loot_CorpseSeekRadius 50, Z within 20).
local function lootWaitActive()
    if not cfg.lootWaitEnabled or not state.lootWaitSince then return false end
    local now = os.clock()
    local elapsed = now - state.lootWaitSince
    local open = false
    pcall(function() open = mq.TLO.Window('LootWnd').Open() == true end)
    if open then state.lootSeenAt = now end

    local hold = false
    if elapsed < (cfg.lootMaxWait or 180) then
        if open then
            hold = true
        elseif state.lootSeenAt then
            hold = (now - state.lootSeenAt) < (cfg.lootGapGrace or 5)
        elseif elapsed < (cfg.lootStartGrace or 4) then
            local corpses = 0
            pcall(function()
                corpses = mq.TLO.SpawnCount(string.format('npccorpse radius %d zradius 20',
                    cfg.lootCorpseRadius or 50))() or 0
            end)
            hold = corpses > 0
        end
    end
    if not hold then
        if state.lootSeenAt then printf('Looting finished -- resuming pulls.') end
        state.lootWaitSince = nil
        state.lootSeenAt = nil
    end
    return hold
end

-- ----------------------------------------------------------------------------
-- Main state machine: IDLE -> TO_MOB -> TO_CAMP -> FIGHTING -> IDLE
-- ----------------------------------------------------------------------------
local function pullTick()
    if cfg.debugEnabled then printDebugStatus() end
    syncMapCircle()
    syncAutoAttack()
    if not cfg.enabled then return end
    if checkRestGate() then return end

    -- Camp mode needs a drop-off point; Hunt mode does not. Auto-init the
    -- same way the original did: Waypoint 1 if patrolling, else here.
    if cfg.pullMode == 'Camp' and not cfg.campLoc then
        local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
        -- Captured here too (not just the UI button/command), so a stale
        -- heading from a previous camp spot never lingers against a newly
        -- auto-initialized one.
        cfg.campHeading = mq.TLO.Me.Heading.Degrees()
        state.arcAiming.Camp = false
        if cfg.useWaypoints and cfg.waypoints and #cfg.waypoints > 0 then
            local wp1 = cfg.waypoints[1]
            cfg.campLoc = { x = wp1.x, y = wp1.y, z = wp1.z, zone = currentZoneShortName() }
            printf('Camp location initialized to Waypoint 1.')
        elseif x and y and z then
            cfg.campLoc = { x = x, y = y, z = z, zone = currentZoneShortName() }
            printf('Camp location initialized to current position.')
        else
            return
        end
        saveCfg()
        return
    end

    if state.pullState == 'IDLE' then
        local addId = firstHostileXtarget()
        if not addId and currentTargetHasAggro() then
            -- XTarget fallback: nothing showed up on the XTarget scan above,
            -- but the current target is hostile and genuinely fighting back
            -- (confirmed live: a mob landing hits with an empty XTarget list
            -- the whole time). Without this, FIGHTING never triggers and
            -- the script just sits in IDLE while you're actively attacked.
            pcall(function() addId = mq.TLO.Target.ID() end)
        end
        if not addId then
            -- Harder case: something neither on XTarget NOR currently
            -- targeted is hitting you. Resolved from the actual combat log.
            addId = recentUnknownAttacker()
        end
        if addId then
            state.lootWaitSince = nil -- being attacked ends any loot wait
            if isSittingOrDucking() then mq.cmd('/stand') end
            state.engagedIds = {}
            state.lastAnnounceAt = 0
            enterFighting(addId) -- also syncs lastChaseId to addId
            return
        end
        -- Fix: a full combat check, not bare Me.Combat() -- Ranged/Spell/Item
        -- pulls can be mid-fight with no melee swing up.
        if inCombat() then return end

        -- Wait for loot: hold everything below (next pull, patrol, Return
        -- to AP, sitting) while a looter is working through the corpses.
        if lootWaitActive() then return end

        -- lastScanAt only advances on an EMPTY scan: pullWait is meant to
        -- throttle "still nothing up" re-checks, not to delay the next pick
        -- right after a pull was dropped (con-blocked, unreachable).
        local id = nil
        if os.clock() - state.lastScanAt >= (cfg.pullWait or 0) then
            id = findPullTarget()
            if not id then state.lastScanAt = os.clock() end
        end
        if id then
            if isSittingOrDucking() then mq.cmd('/stand') end
            mq.cmdf('/target id %d', id)
            state.pullTargetId = id
            state.navBestDist = 9999
            state.navBestAt = os.clock()
            state.navUnstuckTried = false
            state.navLosBackoffCount = 0
            state.engagedIds = {}
            state.lastAnnounceAt = 0
            state.lastChaseId = 0
            state.meleeChaseStuckSince = nil
            if cfg.swarmEnabled then
                state.pullState = 'GATHER'
                state.swarmSkip = {}
                state.swarmSummoned = false
                state.swarmTagged = false
                state.swarmAggroSince = nil
                state.swarmChaseUntil = os.clock() + (cfg.swarmMaxChase or 45)
            else
                state.pullState = 'TO_MOB'
            end
            return
        end

        if cfg.useWaypoints and cfg.waypoints and #cfg.waypoints > 0 then
            if isSittingOrDucking() then mq.cmd('/stand') end -- need to stand to walk the patrol
            patrolTick()
            return
        end

        -- Nothing to pull and not patrolling: walk back to the camp/anchor
        -- point first (if asked to and one's actually set), THEN fall
        -- through to the sit check below once close enough -- so idling
        -- means regenerating at your checkpoint, not wherever the last
        -- mob happened to die.
        if cfg.returnToAnchor then
            local anchor = cfg.pullMode == 'Camp' and cfg.campLoc or cfg.huntAnchor
            if anchor and distToLoc(anchor.x, anchor.y, anchor.z) > 10 then
                if isSittingOrDucking() then mq.cmd('/stand') end
                navTowardLoc(anchor.x, anchor.y, anchor.z, 10)
                return
            end
        end

        -- Nothing to pull and nowhere to patrol to: sit and regen instead
        -- of just standing there doing nothing.
        if cfg.idleSit and canSitNow() and not isSittingOrDucking() then
            mq.cmd('/sit')
        end
        return
    end

    if state.pullState == 'GATHER' then
        -- Summon (e.g. a riposte on a body pull) ends the gather right now,
        -- below cfg.swarmCount if it has to -- same safety valve as
        -- tac/swarm_pull.lua's "Fight when summoned".
        if state.swarmSummoned then
            state.swarmSummoned = false
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            printf('Summoned -- ending the gather early and %s.',
                cfg.pullMode == 'Hunt' and 'fighting' or 'heading back to camp')
            if cfg.pullMode == 'Hunt' then enterFighting(nil) else state.pullState = 'TO_CAMP' end
            return
        end

        -- Same idea, triggered by your own HP instead: something (an add, a
        -- trap, unlucky proximity aggro) is chewing on you while you're
        -- still out gathering more -- stop gathering and deal with it now
        -- rather than finishing the batch first.
        if cfg.swarmHpAbortEnabled and (mq.TLO.Me.PctHPs() or 100) <= (cfg.swarmHpAbortPct or 60) then
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            printf('HP at or below %d%% -- ending the gather early and %s.', cfg.swarmHpAbortPct or 60,
                cfg.pullMode == 'Hunt' and 'fighting' or 'heading back to camp')
            if cfg.pullMode == 'Hunt' then enterFighting(nil) else state.pullState = 'TO_CAMP' end
            return
        end

        -- Something neither on XTarget nor currently targeted is hitting
        -- you (confirmed live: countSwarmHaters() stayed 0 the whole time
        -- "a haunted chest" was landing repeated hits). Resolved from the
        -- combat log -- unlike the two aborts above, we actually know WHO
        -- it is, so hand it straight to enterFighting instead of nil, same
        -- as Force Engage does.
        local unknownId = recentUnknownAttacker()
        if unknownId then
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            printf('Something not on XTarget is attacking -- ending the gather early and %s.',
                cfg.pullMode == 'Hunt' and 'fighting' or 'heading back to camp')
            if cfg.pullMode == 'Hunt' then
                enterFighting(unknownId)
            else
                state.pullTargetId = unknownId
                state.pullState = 'TO_CAMP'
            end
            return
        end

        local haters = countSwarmHaters()
        if haters >= math.max(1, cfg.swarmCount or 1) then
            -- Every OTHER way out of GATHER (summon, HP abort, unknown
            -- attacker) stops in-flight navigation before transitioning --
            -- this, the normal "hit the count" path, was missing the same
            -- call. Without it, MQ2Nav just kept walking toward wherever it
            -- was already headed (the last candidate picked) even after the
            -- script moved on internally, picking up proximity aggro from
            -- everything along the way until it actually arrived.
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            printf('Gathered %d -- engaging.', haters)
            if cfg.pullMode == 'Hunt' then enterFighting(nil) else state.pullState = 'TO_CAMP' end
            return
        end

        -- Still chasing a candidate from last tick? Drop it if it's dead,
        -- gone, or already aggro'd (XTarget -- whether that happened
        -- naturally or via swarmTagCmd, either way it's done; move on).
        local id = state.pullTargetId
        if id > 0 and (not isHostileNpc(id) or isOnXTarget(id)) then
            id = 0
        end
        if id > 0 then
            state.pullTargetId = id
        else
            state.pullTargetId = 0
            state.swarmAggroSince = nil
            state.swarmTagged = false
        end

        if state.pullTargetId <= 0 then
            -- Same pullWait throttle as IDLE's scan -- without it, "nothing
            -- left to gather yet, waiting for something to spawn" would
            -- re-run the NearestSpawn scan every single tick instead of
            -- waiting cfg.pullWait between tries. Shared timestamp with
            -- IDLE's own scan is fine: IDLE and GATHER are never active at
            -- the same time. Like IDLE, only an EMPTY scan starts the wait --
            -- otherwise every candidate that aggro'd quickly left you
            -- standing still for up to pullWait seconds before walking to
            -- the next one, with the batch so far chewing on you.
            if os.clock() - state.lastScanAt < (cfg.pullWait or 0) then return end
            -- extraExclude: skip anything already aggro'd this batch (would
            -- just be found again instantly) and anything that already
            -- failed to aggro/reach for this batch.
            local nextId = findPullTarget(function(sid) return isOnXTarget(sid) or state.swarmSkip[sid] end)
            if not nextId then
                state.lastScanAt = os.clock()
                if haters > 0 then
                    -- Same nav-stop gap as the count-reached path above --
                    -- the dropped previous candidate's nav command can
                    -- still be active here.
                    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
                    printf('Nothing left to gather -- fighting the %d I have.', haters)
                    if cfg.pullMode == 'Hunt' then enterFighting(nil) else state.pullState = 'TO_CAMP' end
                end
                return
            end
            mq.cmdf('/target id %d', nextId)
            state.pullTargetId = nextId
            -- navTowardId's own stall-tracking (shared with TO_MOB) has to
            -- reset for each new candidate too, same as TO_MOB does on a
            -- fresh pull target -- otherwise a stale navBestDist left over
            -- from the PREVIOUS candidate's chase (e.g. it was very close
            -- when we gave up on it) can make the new, farther-away
            -- candidate look like zero progress from tick one.
            state.navBestDist = 9999
            state.navBestAt = os.clock()
            state.navUnstuckTried = false
            state.navLosBackoffCount = 0
            state.swarmChaseUntil = os.clock() + (cfg.swarmMaxChase or 45)
            state.swarmAggroSince = nil
            state.swarmTagged = false
            return
        end

        -- Same con check TO_MOB runs. Without it the faction filter never
        -- applied during a gather at all: nothing ever sent /consider, so
        -- conCache stayed empty and findPullTarget's cached-tier check let
        -- every tier through (an Amiable mob just burned swarmAggroWait).
        if not verifyTargetCon(state.pullTargetId) then
            printf('Gather candidate blocked by con filter -- skipping it.')
            state.swarmSkip[state.pullTargetId] = true
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            state.pullTargetId = 0
            state.swarmAggroSince = nil
            state.swarmTagged = false
            return
        end

        local arrived, stillGoing = navTowardId(state.pullTargetId, cfg.swarmPullRange or 15)
        if not stillGoing or os.clock() > state.swarmChaseUntil then
            printf('Could not reach a candidate in time -- skipping it for this batch.')
            state.swarmSkip[state.pullTargetId] = true
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            state.pullTargetId = 0
            state.swarmAggroSince = nil
            state.swarmTagged = false
            return
        end
        if arrived then
            -- In range: a body pull by default (swarmTagCmd blank) relies
            -- purely on EQ's own proximity/faction aggro -- no damage dealt,
            -- so nothing here gets a chance to summon us mid-gather. If a
            -- tag command IS set, it's sent once per candidate (your own
            -- risk/reward call, same as swarm_pull.lua's optional pullCmd).
            if cfg.swarmTagCmd ~= '' and not state.swarmTagged then
                mq.cmd('/face fast')
                mq.cmd(cfg.swarmTagCmd)
                state.swarmTagged = true
            end
            if not state.swarmAggroSince then
                state.swarmAggroSince = os.clock()
            elseif os.clock() - state.swarmAggroSince > (cfg.swarmAggroWait or 3) then
                printf('A candidate did not aggro -- skipping it for this batch.')
                state.swarmSkip[state.pullTargetId] = true
                state.pullTargetId = 0
                state.swarmAggroSince = nil
                state.swarmTagged = false
            end
        end
        return
    end

    if state.pullState == 'TO_MOB' then
        local id = state.pullTargetId

        -- Something else is already attacking us while we're still on the
        -- way to the original target -- that's the real threat now. Drop
        -- the pull and deal with whatever's actually hitting us instead of
        -- blindly continuing to chase a mob that isn't even swinging on us.
        local aggroId = firstHostileXtarget()
        if aggroId and aggroId ~= id then
            printf('Attacked by something else while pulling -- switching to #%d.', aggroId)
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            mq.cmdf('/target id %d', aggroId)
            if cfg.pullMode == 'Hunt' then
                enterFighting(aggroId)
            else
                state.pullTargetId = aggroId
                state.pullState = 'TO_CAMP'
            end
            return
        end

        if not isHostileNpc(id) then
            state.pullState = 'IDLE'; state.pullTargetId = 0
            return
        end
        if not verifyTargetCon(id) then
            printf('Target blocked by con filter -- picking a different mob.')
            state.pullState = 'IDLE'; state.pullTargetId = 0
            return
        end

        local arrived, stillGoing = navTowardId(id, pullReach(id), pullApproach(id))
        if not stillGoing then
            printf('Giving up on an unreachable mob -- will retry it later.')
            state.tempIgnore[id] = os.clock() + 60
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            state.pullState = 'IDLE'; state.pullTargetId = 0
            return
        end
        if arrived then
            fireTag(id)
            if haveAggro(id) then
                -- Hunt fights where it's tagged; Camp drags it home.
                if cfg.pullMode == 'Hunt' then
                    enterFighting(id)
                else
                    state.pullState = 'TO_CAMP'
                end
            end
        end
        return
    end

    if state.pullState == 'TO_CAMP' then
        if cfg.swarmEnabled then
            -- A swarm drag always has multiple simultaneous attackers by
            -- design -- that's not an anomaly to react to the way the
            -- single-target aggro-switch below would, so skip it entirely.
            -- "Done" means nothing from the batch is hating us anymore, not
            -- just that state.pullTargetId's one specific member died (the
            -- others could still be very much alive and chasing). Also
            -- checks recentUnknownAttacker(): countSwarmHaters() is
            -- XTarget-only, and XTarget can fail to show a mob that's
            -- genuinely still hitting you (the whole reason this abort
            -- path exists) -- without this, arriving here with only an
            -- XTarget-invisible attacker left would read as "done" and
            -- drop you straight back to IDLE mid-fight.
            if countSwarmHaters() == 0 and not recentUnknownAttacker() then
                state.pullState = 'IDLE'; state.pullTargetId = 0
                beginLootWait()
                return
            end
        else
            -- Same idea as TO_MOB: something else attacked us on the way
            -- back. Keep dragging toward camp (Camp mode) or switch to
            -- fighting in place (Hunt mode), but track the thing actually
            -- hitting us.
            local aggroId = firstHostileXtarget()
            if aggroId and aggroId ~= state.pullTargetId then
                printf('Attacked by something else while returning to camp -- switching to #%d.', aggroId)
                mq.cmdf('/target id %d', aggroId)
                if cfg.pullMode == 'Hunt' then
                    enterFighting(aggroId)
                    return
                end
                state.pullTargetId = aggroId
                -- stays TO_CAMP with the new target
            end

            if not isHostileNpc(state.pullTargetId) then
                state.pullState = 'IDLE'; state.pullTargetId = 0
                return
            end
        end
        local c = cfg.campLoc
        if not c then
            -- Mode was switched to Hunt (no camp needed) mid-drag; just
            -- fight the mob where it stands instead of crashing on a nil camp.
            enterFighting(nil)
            return
        end
        if navTowardLoc(c.x, c.y, c.z, 15) then
            enterFighting(nil)
        end
        return
    end

    if state.pullState == 'FIGHTING' then
        -- Announce every hostile on XTarget, not just the original pull
        -- target: a multi-mob pull (an add, an AE pull) otherwise only
        -- ever stuck/engaged the one mob enterFighting() happened to fire
        -- for, leaving the rest unaddressed by the combat script. Skips
        -- anything E3Next's ClearXTargets already has (clearXTargetsInfo),
        -- the precise signal; falls back to a cooldown-gated announce for
        -- anything it doesn't. Not gated on "not currently attacking":
        -- Combat()/AutoFire() are sticky on/off toggles, not a per-swing
        -- flag, so a hard "only while idle" gate could block an add from
        -- ever being announced for as long as melee auto-attack stays on --
        -- which looks exactly like "something's hitting me and nothing
        -- reacts." The cooldown instead guarantees it eventually fires,
        -- just not instantly for every simultaneous add.
        local slots = mq.TLO.Me.XTargetSlots() or 13
        local nowEngage = os.clock()
        local e3nEnabled, e3nMob, e3nSticking = clearXTargetsInfo()
        for i = 1, slots do
            local xt = mq.TLO.Me.XTarget(i)
            if xt() then
                local xid = xt.ID() or 0
                if xid > 0 and isHostileNpc(xid) and not state.engagedIds[xid] then
                    if cfg.pullStyle == 'Melee' then
                        -- Melee's chase block below already re-fires
                        -- onEngageCommand every time its active target
                        -- changes. Announcing here too meant /target-ing
                        -- each add and firing the command on it (e.g.
                        -- /assistme sending the group to slot 1) while
                        -- melee snapped straight back to its own target
                        -- the same tick -- the group hopped to a new add
                        -- every cooldown window, never on what you were
                        -- actually hitting. Just mark it seen.
                        state.engagedIds[xid] = true
                    elseif not inCampSafeZone(xid) then
                        -- Camp mode, still outside the Camp Safe Radius:
                        -- left unannounced so it's handed off once it
                        -- actually reaches camp, not while it's still
                        -- 100 units out pulling the fight away from camp.
                    elseif e3nEnabled and e3nSticking and xid == e3nMob then
                        -- E3Next's ClearXTargets already has this one targeted
                        -- and is actively stuck to it; nothing to announce,
                        -- and no cooldown spent since we didn't send a command.
                        state.engagedIds[xid] = true
                    elseif nowEngage - (state.lastAnnounceAt or 0) >= ENGAGE_ANNOUNCE_COOLDOWN then
                        if announceEngage(xid) then
                            state.lastAnnounceAt = nowEngage
                            break -- one new engage per cooldown window; the rest follow later
                        end
                    end
                end
            end
        end

        -- Melee is the one style this script stays responsible for closing
        -- distance on even after FIGHTING begins (Ranged/Spell/Item/E3Next
        -- are left to you/your combat script from here, per the file's own
        -- design). meleeCloseOnTarget actively navigates in (with the same
        -- point-blank LOS backoff used while pulling) instead of only
        -- checking whether you happen to already be there.
        --
        -- state.pullTargetId has to be re-validated as a LIVE hostile every
        -- tick before chasing it: once it dies, distToId/LineOfSight still
        -- happily answer for its corpse (you're standing right on it --
        -- "in range" and "LOS" both still true), so without this check the
        -- old code kept re-issuing /attack on against a dead body forever.
        -- That alone kept Me.Combat() on, which kept inCombat() true, which
        -- kept the state machine from ever leaving FIGHTING -- a fully
        -- self-sustaining stuck-attack loop. Falls back to another hostile
        -- XTarget (an add) if the original died but the fight isn't over.
        if cfg.pullStyle == 'Melee' then
            local chaseId = state.pullTargetId
            if chaseId <= 0 or not isHostileNpc(chaseId) or not inCampSafeZone(chaseId) then
                -- nearestHostileXtargetNotIgnored() first (the normal case,
                -- skipping anything just abandoned as unreachable below --
                -- otherwise a mob given up on seconds ago gets immediately
                -- re-picked the moment whatever replaced it dies); if
                -- XTarget doesn't show anything, recentUnknownAttacker()
                -- covers a mob that's genuinely hitting you but invisible
                -- to XTarget (same gap this whole fallback chain exists for).
                -- Camp mode: only mobs already inside the Camp Safe Radius
                -- (inCampSafeZone is a no-op filter in Hunt mode).
                chaseId = nearestHostileXtargetNotIgnored(inCampSafeZone)
                if not chaseId then
                    local unk = recentUnknownAttacker()
                    if unk and inCampSafeZone(unk) then chaseId = unk end
                end
                state.pullTargetId = chaseId or 0
            end
            if chaseId and chaseId > 0 and isHostileNpc(chaseId) then
                local tgtId = 0
                pcall(function() tgtId = mq.TLO.Target.ID() or 0 end)
                if tgtId ~= chaseId then mq.cmdf('/target id %d', chaseId) end

                -- onEngageCommand (the sweep above) only fires once per
                -- unique mob ID, on purpose -- a still-alive add shouldn't
                -- get re-announced every tick. But something like /assistme
                -- (start the combat rotation on whatever's targeted) needs
                -- to fire again every time melee's ACTUAL active target
                -- changes, even to a mob already seen once as an add --
                -- "have I ever mentioned this mob" and "is this what I'm
                -- swinging at right now" are different questions, so this
                -- is tracked separately from engagedIds.
                if chaseId ~= state.lastChaseId then
                    state.lastChaseId = chaseId
                    state.meleeChaseStuckSince = nil
                    if cfg.onEngageCommand and cfg.onEngageCommand ~= '' then
                        local nm = ''
                        pcall(function() nm = mq.TLO.Spawn(chaseId).CleanName() or '' end)
                        printf('Melee switching to #%d (%s) -- re-firing onEngageCommand.', chaseId, nm ~= '' and nm or '?')
                        mq.cmd(cfg.onEngageCommand)
                    end
                end

                local arrivedNow = meleeCloseOnTarget(chaseId)
                if arrivedNow then
                    state.meleeChaseStuckSince = nil
                    if not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
                else
                    -- meleeCloseOnTarget has no give-up logic of its own --
                    -- confirmed live: stuck LOS-blocked on one XTarget
                    -- hostile while a different one sat there unaddressed,
                    -- actively hitting the player. If this chaseId still
                    -- hasn't been "arrived" at after MELEE_CHASE_STUCK_SEC
                    -- and a different hostile is available, switch to it
                    -- instead of retrying the same stuck one forever.
                    state.meleeChaseStuckSince = state.meleeChaseStuckSince or os.clock()
                    if os.clock() - state.meleeChaseStuckSince > MELEE_CHASE_STUCK_SEC then
                        local altId = nearestHostileXtargetExcept(chaseId, inCampSafeZone)
                        if altId then
                            local nm = ''
                            pcall(function() nm = mq.TLO.Spawn(chaseId).CleanName() or '' end)
                            printf('Could not reach/see #%d (%s) for %ds -- switching to a different hostile.',
                                chaseId, nm ~= '' and nm or '?', MELEE_CHASE_STUCK_SEC)
                            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
                            -- Same 60s tempIgnore window the pulling-phase
                            -- give-up uses -- without this, nearestHostileXtar-
                            -- getNotIgnored() above has nothing to skip and
                            -- this exact mob gets re-picked (and re-stuck-
                            -- on) the instant altId stops being eligible.
                            state.tempIgnore[chaseId] = os.clock() + 60
                            state.pullTargetId = altId
                            state.meleeChaseStuckSince = nil
                        else
                            -- No alternative on XTarget -- switching targets
                            -- isn't an option (this IS the only mob left).
                            -- navBackoffFromId already exists for exactly
                            -- this kind of "can't get LOS" problem, but it
                            -- only ever fires when already point-blank
                            -- (within NAV_LOS_POINTBLANK) -- too narrow for
                            -- something like a mob up on a raised bed where
                            -- you may never get that close. Use it here
                            -- too, not gated on distance, since "push
                            -- straight at it" has clearly had 15+ seconds
                            -- to work and hasn't -- back off and let the
                            -- next approach retry from a different angle.
                            -- Keeps retrying every MELEE_CHASE_STUCK_SEC
                            -- rather than giving up, since giving up here
                            -- means doing nothing at all.
                            local nm = ''
                            pcall(function() nm = mq.TLO.Spawn(chaseId).CleanName() or '' end)
                            printf('Still stuck on #%d (%s) with nothing else to switch to -- backing off to try a different angle.',
                                chaseId, nm ~= '' and nm or '?')
                            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
                            navBackoffFromId(chaseId, pullReach(chaseId) + 20)
                            state.meleeChaseStuckSince = os.clock()
                        end
                    end
                end
            elseif cfg.pullMode == 'Camp' and cfg.campLoc then
                -- Nothing inside the Camp Safe Radius yet (the rest are
                -- still on their way in): hold at the camp point and let
                -- them come, rather than running out to meet them.
                local c = cfg.campLoc
                navTowardLoc(c.x, c.y, c.z, 10)
            end
        end
        if not inCombat() then
            state.pullState = 'IDLE'; state.pullTargetId = 0
            state.engagedIds = {}
            state.lastAnnounceAt = 0
            state.lastChaseId = 0
            state.meleeChaseStuckSince = nil
            state.campSafeBypassId = 0
            beginLootWait()
        end
        return
    end
end

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------
local function statusLine()
    local c = cfg.pullMode == 'Camp' and cfg.campLoc or cfg.huntAnchor
    local anchorLabel = cfg.pullMode == 'Camp' and 'camp' or 'anchor'
    local stateLabel = state.pullState
    if stateLabel == 'GATHER' then
        stateLabel = string.format('GATHER (%d/%d)', countSwarmHaters(), cfg.swarmCount or 1)
    elseif stateLabel == 'IDLE' and state.lootWaitSince then
        stateLabel = 'IDLE (loot wait)'
    end
    return string.format('%s %s | target: %s | %s: %s | %s',
        cfg.pullMode, stateLabel,
        state.pullTargetId > 0 and ('#' .. state.pullTargetId) or '-',
        anchorLabel, c and string.format('%.0f,%.0f', c.y, c.x) or 'not set',
        state.resting and 'RESTING' or (cfg.enabled and 'active' or 'stopped'))
end

-- Quick-glance color for the status line: gray while stopped, cyan while
-- resting, yellow while traveling (TO_MOB/TO_CAMP/GATHER), red while
-- FIGHTING (the state that most needs your attention), green otherwise
-- (enabled and IDLE -- waiting, nothing wrong).
local function statusColor()
    if not cfg.enabled then return 0.55, 0.55, 0.55, 1.0 end
    if state.resting then return 0.35, 0.75, 0.95, 1.0 end
    if state.pullState == 'FIGHTING' then return 0.95, 0.35, 0.35, 1.0 end
    if state.pullState == 'TO_MOB' or state.pullState == 'TO_CAMP' or state.pullState == 'GATHER' then
        return 0.95, 0.8, 0.35, 1.0
    end
    return 0.55, 0.85, 0.55, 1.0
end

-- A slider paired with small -/+ buttons for one-click precise nudging --
-- dragging a slider exactly to a specific number with the mouse is fiddly.
-- (Ctrl+click or double-click on the slider itself also works, via Dear
-- ImGui's own built-in direct-entry gesture, but that's not very
-- discoverable, hence the buttons.) Same calling convention as
-- ImGui.SliderInt: pass the current value, get the new one back.
local function preciseSlider(label, value, minV, maxV, step)
    step = step or 1
    local id = label:match('##(.+)$') or label
    local text = label:match('^(.-)##') or label
    ImGui.Text(text)
    ImGui.SameLine()
    if ImGui.SmallButton('-##' .. id .. 'Dec') then
        value = math.max(minV, value - step)
    end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)
    local v = ImGui.SliderInt('##' .. id, value, minV, maxV)
    ImGui.SameLine()
    if ImGui.SmallButton('+##' .. id .. 'Inc') then
        v = math.min(maxV, v + step)
    end
    return v
end

-- Draws a circle with a filled pie-slice wedge for the pull arc, rotated
-- live to the given heading (degrees). Wedge-drawing mechanics (PathLineTo/
-- PathArcTo/PathFillConvex) verified against tac/buttons.lua's SLOT.sweep()
-- cooldown-sweep; the heading-to-screen-angle mapping below is calibrated
-- against a live in-game reading (see inPullArc above for why).
local function drawArcPreview(headingDeg, widthDeg, size, showDot)
    size = size or 200
    local dl = ImGui.GetWindowDrawList()
    local px, py = ImGui.GetCursorScreenPos()
    local cx, cy = px + size / 2, py + size / 2
    ImGui.Dummy(size, size)
    local center = ImVec2(cx, cy)
    local radius = size / 2 - 6

    dl:AddCircle(center, radius, ImGui.GetColorU32(0.4, 0.4, 0.4, 0.8), 48, 1.5)
    dl:AddLine(ImVec2(cx - radius, cy), ImVec2(cx + radius, cy), ImGui.GetColorU32(0.3, 0.3, 0.3, 0.6), 1)
    dl:AddLine(ImVec2(cx, cy - radius), ImVec2(cx, cy + radius), ImGui.GetColorU32(0.3, 0.3, 0.3, 0.6), 1)

    -- Screen mapping: north-up, east-right, heading increasing clockwise
    -- (0=N, 90=E, 180=S, 270=W) -> screen dx = sin(h), screen dy = -cos(h)
    -- (screen Y grows downward, so "up"/North is -screenY). Calibrated
    -- directly against a live in-game heading reading (facing East showed
    -- ~90) rather than against EQ's internal world-axis convention, which
    -- inPullArc above handles separately.
    local hRad = math.rad(headingDeg or 0)
    local sdx, sdy = math.sin(hRad), -math.cos(hRad)
    local centerAngle = math.atan2(sdy, sdx)

    if widthDeg and widthDeg > 0 and widthDeg < 360 then
        local half = math.rad(widthDeg / 2)
        local aMin, aMax = centerAngle - half, centerAngle + half
        if dl.PathLineTo and dl.PathArcTo and dl.PathFillConvex then
            dl:PathLineTo(center)
            dl:PathArcTo(center, radius, aMin, aMax, 48)
            dl:PathFillConvex(ImGui.GetColorU32(0.25, 0.7, 0.3, 0.45))
        end
        dl:AddLine(center, ImVec2(cx + radius * math.cos(aMin), cy + radius * math.sin(aMin)),
            ImGui.GetColorU32(0.3, 0.85, 0.35, 1.0), 2)
        dl:AddLine(center, ImVec2(cx + radius * math.cos(aMax), cy + radius * math.sin(aMax)),
            ImGui.GetColorU32(0.3, 0.85, 0.35, 1.0), 2)
    else
        dl:AddCircleFilled(center, radius, ImGui.GetColorU32(0.25, 0.7, 0.3, 0.3))
    end

    if showDot then
        local fx, fy = cx + radius * math.cos(centerAngle), cy + radius * math.sin(centerAngle)
        dl:AddCircleFilled(ImVec2(fx, fy), 5, ImGui.GetColorU32(1.0, 0.85, 0.25, 1.0))
    end

    dl:AddText(ImVec2(cx - 4, cy - radius - 16), ImGui.GetColorU32(0.6, 0.6, 0.6, 1.0), 'N')
    dl:AddText(ImVec2(cx - radius - 16, cy - 7), ImGui.GetColorU32(0.6, 0.6, 0.6, 1.0), 'W')
    dl:AddText(ImVec2(cx + radius + 6, cy - 7), ImGui.GetColorU32(0.6, 0.6, 0.6, 1.0), 'E')
    dl:AddText(ImVec2(cx - 4, cy + radius + 4), ImGui.GetColorU32(0.6, 0.6, 0.6, 1.0), 'S')
end

local function drawArcTab()
    local isCamp = cfg.pullMode == 'Camp'
    local modeKey = isCamp and 'Camp' or 'Hunt'
    local width = isCamp and cfg.campArcWidth or cfg.huntArcWidth
    local heading = isCamp and cfg.campHeading or cfg.huntHeading

    -- Aiming (live-tracking, shows the facing dot) vs locked (frozen on the
    -- committed heading, no dot -- nothing left to aim). Decided once per
    -- mode the first time this tab is drawn: aiming by default if there's
    -- no heading committed yet (new setup), locked by default if one's
    -- already set (the common "just checking it" case), then only changes
    -- via the buttons below.
    if state.arcAiming[modeKey] == nil then
        state.arcAiming[modeKey] = (heading == nil)
    end
    local aiming = state.arcAiming[modeKey]

    ImGui.TextDisabled(string.format('%s mode -- arc is centered on a facing heading, independent of', cfg.pullMode))
    ImGui.TextDisabled(string.format('the %s location itself.', isCamp and 'camp' or 'anchor'))
    ImGui.Spacing()

    local label = isCamp and 'Pull Arc Width (0 = full circle)##campArcWidth2' or 'Hunt Arc Width (0 = full circle)##huntArcWidth2'
    local w = preciseSlider(label, width, 0, 360)
    if w ~= width then
        if isCamp then cfg.campArcWidth = w else cfg.huntArcWidth = w end
        saveCfg()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Like KissAssist\'s /setpullarc: restricts pulls to a cone facing a committed\n' ..
            'heading. Turn to aim, then click "Lock Heading" below to commit it.')
    end

    if aiming then
        if ImGui.Button('Lock Heading##arcLock') then
            local newHeading = mq.TLO.Me.Heading.Degrees()
            if isCamp then cfg.campHeading = newHeading else cfg.huntHeading = newHeading end
            saveCfg()
            state.arcAiming[modeKey] = false
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Commits your CURRENT facing as the arc\'s heading, without moving the\n' ..
                (isCamp and 'camp' or 'anchor') .. ' location itself.')
        end
    else
        if ImGui.Button('Re-aim##arcReaim') then
            state.arcAiming[modeKey] = true
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Switch back to live-tracking your facing so you can turn to a new heading.')
        end
    end

    ImGui.TextDisabled(string.format('Locked-in heading: %s   |   live facing: %.0f',
        heading and string.format('%.0f', heading) or 'not set yet', mq.TLO.Me.Heading.Degrees() or 0))
    ImGui.Spacing()

    if aiming then
        drawArcPreview(mq.TLO.Me.Heading.Degrees(), width, 220, true)
        ImGui.TextDisabled('Yellow dot = current facing, rotates live as you turn.')
        ImGui.TextDisabled('Turn to aim, then click "Lock Heading" above to freeze it.')
    else
        drawArcPreview(heading, width, 220, false)
        ImGui.TextDisabled('Locked -- click "Re-aim" above to adjust.')
    end
end

local function drawGUI_()
    openGUI, drawGUI = ImGui.Begin('Puller##' .. myName, openGUI)
    if drawGUI then
        local scR, scG, scB, scA = statusColor()
        ImGui.TextColored(scR, scG, scB, scA, statusLine())
        ImGui.Separator()
        ImGui.Spacing()

        if cfg.enabled then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.18, 0.18, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.68, 0.24, 0.24, 1.0)
        else
            ImGui.PushStyleColor(ImGuiCol.Button, 0.18, 0.5, 0.22, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.24, 0.62, 0.28, 1.0)
        end
        if ImGui.Button(cfg.enabled and 'Stop##pullEnable' or 'Start##pullEnable', 100, 24) then
            if cfg.enabled then
                stopPulling()
            else
                cfg.enabled = true
                saveCfg()
            end
        end
        ImGui.PopStyleColor(2)
        ImGui.SameLine()
        if ImGui.Button('Force Engage##forceEngage', 110, 24) then
            forceEngage()
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('For a pull stuck in range but unable to land a hit (usually line of sight --\n' ..
                'walk around the corner yourself first). Skips straight to fighting your\n' ..
                'current target right now instead of waiting on the auto-retry.')
        end
        ImGui.Spacing()
        ImGui.TextDisabled('Mode:')
        ImGui.SameLine()
        if ImGui.RadioButton('Camp##pullModeCamp', cfg.pullMode == 'Camp') then
            cfg.pullMode = 'Camp'; saveCfg()
        end
        ImGui.SameLine()
        if ImGui.RadioButton('Hunt##pullModeHunt', cfg.pullMode == 'Hunt') then
            cfg.pullMode = 'Hunt'; saveCfg()
        end

        if cfg.pullMode == 'Camp' then
            if ImGui.Button('Set Camp Here') then
                local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
                if x and y and z then
                    cfg.campLoc = { x = x, y = y, z = z, zone = currentZoneShortName() }
                    cfg.campHeading = mq.TLO.Me.Heading.Degrees()
                    state.arcAiming.Camp = false
                    saveCfg()
                end
            end
            ImGui.SameLine()
            if ImGui.Button('Clear Camp') then
                cfg.campLoc = nil
                saveCfg()
            end
        else
            if ImGui.Button('Set Hunt Anchor Here') then
                local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
                if x and y and z then
                    cfg.huntAnchor = { x = x, y = y, z = z, zone = currentZoneShortName() }
                    cfg.huntHeading = mq.TLO.Me.Heading.Degrees()
                    state.arcAiming.Hunt = false
                    saveCfg()
                end
            end
            ImGui.SameLine()
            if ImGui.Button('Clear Anchor (roam unrestricted)') then
                cfg.huntAnchor = nil
                saveCfg()
            end
        end

        local idleSit = ImGui.Checkbox('Sit while idle (nothing to pull)##idleSit', cfg.idleSit)
        if idleSit ~= cfg.idleSit then cfg.idleSit = idleSit; saveCfg() end
        ImGui.SameLine()
        local returnAnchor = ImGui.Checkbox('Return to AP (nothing to kill)##returnAnchor', cfg.returnToAnchor)
        if returnAnchor ~= cfg.returnToAnchor then cfg.returnToAnchor = returnAnchor; saveCfg() end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('When idle with nothing to pull (and not patrolling waypoints), walks back\n' ..
                'to the camp/anchor point before sitting -- so you regen at your checkpoint\n' ..
                'instead of wherever the last mob happened to die.\n' ..
                'Does nothing if no camp/anchor is set yet.')
        end
        ImGui.SameLine()
        local dbg = ImGui.Checkbox('Debug##debugEnabled', cfg.debugEnabled)
        if dbg ~= cfg.debugEnabled then cfg.debugEnabled = dbg; saveCfg() end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Prints a status line to the MQ console every couple seconds: state,\n' ..
                'what it\'s chasing, distance/LOS to it, combat flags, how many hostiles\n' ..
                'XTarget actually shows, and your HP -- for seeing live why nothing seems\n' ..
                'to be happening instead of needing a screenshot.')
        end
        ImGui.Spacing()
        ImGui.Separator()

        if ImGui.BeginTabBar('##pullerTabs') then
        if ImGui.BeginTabItem('Pull Method') then
            ImGui.TextDisabled('How to tag a mob once you\'re in range: melee swing, a ranged item,')
            ImGui.TextDisabled('a spell, or an inventory clicky -- plus what to hand off to once it lands.')
            ImGui.Spacing()

            for i, style in ipairs(PULL_STYLES) do
                if i > 1 then ImGui.SameLine() end
                if ImGui.RadioButton(style .. '##pullStyle', cfg.pullStyle == style) then
                    cfg.pullStyle = style
                    saveCfg()
                end
            end
            if cfg.pullStyle == 'Spell' then
                ImGui.SetNextItemWidth(220)
                local v, changed = ImGui.InputText('Pull Spell##pullSpell', cfg.pullSpell)
                if changed then cfg.pullSpell = v; saveCfg() end
            elseif cfg.pullStyle == 'Item' then
                ImGui.SetNextItemWidth(220)
                local v, changed = ImGui.InputText('Pull Item##pullItem', cfg.pullItem)
                if changed then cfg.pullItem = v; saveCfg() end
            end
            if cfg.pullStyle ~= 'Melee' then
                local v = preciseSlider('Engage Distance##engageDist', cfg.engageDist, 20, 200)
                if v ~= cfg.engageDist then cfg.engageDist = v; saveCfg() end
            end

            ImGui.SetNextItemWidth(220)
            local oe, oeChanged = ImGui.InputText('On Engage Command##onEngageCommand', cfg.onEngageCommand)
            if oeChanged then cfg.onEngageCommand = oe; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Runs once, the instant the fight actually begins (Camp or Hunt).\nFor handing off to a combat script, e.g. /cleartargets stick.\nLeave blank to do nothing.')
            end
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Text('Wait for loot')
            ImGui.TextDisabled('After a fight, waits for looting (E3 autoloot, another script, or you)')
            ImGui.TextDisabled('to finish before the next pull -- detected from the loot window.')

            local le = ImGui.Checkbox('Enabled##lootWaitEnabled', cfg.lootWaitEnabled)
            if le ~= cfg.lootWaitEnabled then cfg.lootWaitEnabled = le; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Holds the next pull, Return to AP and sitting while the loot window is\n' ..
                    'open or was open a moment ago. Anything attacking you ends the wait.')
            end
            local cr = preciseSlider('Corpse Radius##lootCorpseRadius', cfg.lootCorpseRadius or 50, 10, 200)
            if cr ~= cfg.lootCorpseRadius then cfg.lootCorpseRadius = cr; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Only waits for looting to start if NPC corpses are within this distance\n' ..
                    '(and 20 up/down). Match E3\'s Loot Corpse Seek Radius (default 50).')
            end
            local sg = preciseSlider('Start Wait (s)##lootStartGrace', cfg.lootStartGrace or 4, 0, 15)
            if sg ~= cfg.lootStartGrace then cfg.lootStartGrace = sg; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('How long after a fight to give the looter a chance to start.\n' ..
                    'E3 autoloot starts about 2-3 seconds after combat ends.')
            end
            local gg = preciseSlider('Between Corpses (s)##lootGapGrace', cfg.lootGapGrace or 5, 1, 15)
            if gg ~= cfg.lootGapGrace then cfg.lootGapGrace = gg; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('How long the loot window can stay closed before looting counts as done\n' ..
                    '(time to walk to the next corpse and open it).')
            end
            local mw = preciseSlider('Max Wait (s)##lootMaxWait', cfg.lootMaxWait or 180, 10, 600)
            if mw ~= cfg.lootMaxWait then cfg.lootMaxWait = mw; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Longest a single wait can last, no matter what -- a backstop for a loot\n' ..
                    'window left open. A big swarm (20+ corpses) can take well over a minute.')
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Targeting') then
            ImGui.TextDisabled('Where to look for mobs, what level/faction range counts as pullable,')
            ImGui.TextDisabled('and whether to mark the search area on the in-game map.')
            ImGui.Spacing()

            if cfg.pullMode == 'Camp' then
                local r = preciseSlider('Pull Radius##campRadius', cfg.campRadius, 10, 1000)
                if r ~= cfg.campRadius then cfg.campRadius = r; saveCfg() end
                local z = preciseSlider('Pull Height Diff (Z)##campZ', cfg.campZ, 10, 300)
                if z ~= cfg.campZ then cfg.campZ = z; saveCfg() end
                local sr = preciseSlider('Camp Safe Radius (0 = off)##campSafeRadius', cfg.campSafeRadius or 30, 0, 200)
                if sr ~= cfg.campSafeRadius then cfg.campSafeRadius = sr; saveCfg() end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip('Once back at camp, mobs aren\'t engaged until they come within this\n' ..
                        'distance of the camp point -- you hold at camp and let them come to you\n' ..
                        'instead of running back out after the nearest one. Green circle on the\n' ..
                        'EQ map. Force Engage ignores it.')
                end
            else
                local r = preciseSlider('Hunt Radius (0 = unrestricted)##huntRadius', cfg.huntRadius, 0, 1000)
                if r ~= cfg.huntRadius then cfg.huntRadius = r; saveCfg() end
                local z = preciseSlider('Hunt Height Diff (Z)##huntZ', cfg.huntZ, 10, 300)
                if z ~= cfg.huntZ then cfg.huntZ = z; saveCfg() end
            end
            local showCircle = ImGui.Checkbox('Show radius on EQ map##showMapCircle', cfg.showMapCircle)
            if showCircle ~= cfg.showMapCircle then cfg.showMapCircle = showCircle; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Uses MQ2Map\'s /maploc to draw a red circle pinned to the camp/anchor point itself\n(stays put while you travel, unlike a player-centered circle).\nHidden when there\'s no anchor to show (Hunt roaming unrestricted, or no camp set yet).')
            end
            local pw = preciseSlider('Pull Wait (sec, 0 = every tick)##pullWait', cfg.pullWait, 0, 60)
            if pw ~= cfg.pullWait then cfg.pullWait = pw; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Time to wait between scans for mobs once nothing\'s up (you killed\n' ..
                    'everything). Mainly for camping a named -- no point re-scanning every\n' ..
                    'tick while waiting out a long repop. Never delays reacting to something\n' ..
                    'that actually attacks you, or picking up a mob the moment one IS found.')
            end
            -- Mutually clamped: Min > Max would make every mob fail the
            -- level filter forever, with no visible error -- the script
            -- just sits IDLE no matter what spawns in range (exactly what
            -- happened before this clamp existed).
            local minL = preciseSlider('Min Level##minLevel', cfg.minLevel, 1, 125)
            if minL ~= cfg.minLevel then
                cfg.minLevel = math.min(minL, cfg.maxLevel)
                saveCfg()
            end
            local maxL = preciseSlider('Max Level##maxLevel', cfg.maxLevel, 1, 125)
            if maxL ~= cfg.maxLevel then
                cfg.maxLevel = math.max(maxL, cfg.minLevel)
                saveCfg()
            end

            ImGui.TextDisabled('Faction consideration (pullable tiers, worst to best):')
            for i, tier in ipairs(CON_TIERS) do
                if (i - 1) % 3 ~= 0 then ImGui.SameLine() end
                local c = CON_TIER_COLORS[i]
                ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], 1.0)
                local checked = ImGui.Checkbox(tier .. '##con' .. tier, cfg.conFilter[tier] ~= false)
                ImGui.PopStyleColor(1)
                if checked ~= (cfg.conFilter[tier] ~= false) then
                    cfg.conFilter[tier] = checked
                    saveCfg()
                end
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Waypoints') then
            ImGui.TextDisabled('An optional patrol route, walked in order while there\'s nothing to pull --')
            ImGui.TextDisabled('scanned for targets along the way, under either Pull Mode.')
            ImGui.Spacing()

            local use = ImGui.Checkbox('Use Waypoints##useWaypoints', cfg.useWaypoints)
            if use ~= cfg.useWaypoints then cfg.useWaypoints = use; saveCfg() end
            ImGui.SameLine()
            if ImGui.Button('Add Waypoint Here') then
                local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
                if x and y and z then
                    table.insert(cfg.waypoints, { x = x, y = y, z = z, name = 'WP ' .. (#cfg.waypoints + 1), cmd = '', delay = 0 })
                    saveCfg()
                end
            end
            ImGui.SameLine()
            if ImGui.Button('Clear Waypoints') then
                cfg.waypoints = {}
                state.wpIndex = 1
                state.wpArrivedIdx = nil
                saveCfg()
            end

            if ImGui.RadioButton('Loop##wpLoop', cfg.waypointLoop) then
                cfg.waypointLoop = true; saveCfg()
            end
            ImGui.SameLine()
            if ImGui.RadioButton('Ping-pong##wpPingpong', not cfg.waypointLoop) then
                cfg.waypointLoop = false; saveCfg()
            end

            local sr = preciseSlider('Scan Radius##wpScanRadius', cfg.waypointScanRadius, 20, 300)
            if sr ~= cfg.waypointScanRadius then cfg.waypointScanRadius = sr; saveCfg() end
            local ar = preciseSlider('Arrival Radius##wpRadius', cfg.waypointRadius, 5, 100)
            if ar ~= cfg.waypointRadius then cfg.waypointRadius = ar; saveCfg() end

            if #cfg.waypoints == 0 then
                ImGui.TextDisabled('No waypoints saved.')
            else
                for i, wp in ipairs(cfg.waypoints) do
                    ImGui.PushID('wp' .. i)
                    ImGui.Text(i .. '.')
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(100)
                    local nameV, nameChanged = ImGui.InputText('##name', wp.name or ('WP ' .. i))
                    if nameChanged then wp.name = nameV; saveCfg() end
                    ImGui.SameLine()
                    ImGui.TextDisabled(string.format('(%.0f, %.0f)', wp.y, wp.x))
                    ImGui.SameLine()
                    if ImGui.SmallButton('Move Here') then
                        local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
                        if x and y and z then wp.x = x; wp.y = y; wp.z = z; saveCfg() end
                    end
                    ImGui.SameLine()
                    if i > 1 then
                        if ImGui.SmallButton('Up') then
                            cfg.waypoints[i], cfg.waypoints[i - 1] = cfg.waypoints[i - 1], cfg.waypoints[i]
                            saveCfg()
                        end
                        ImGui.SameLine()
                    end
                    if i < #cfg.waypoints then
                        if ImGui.SmallButton('Down') then
                            cfg.waypoints[i], cfg.waypoints[i + 1] = cfg.waypoints[i + 1], cfg.waypoints[i]
                            saveCfg()
                        end
                        ImGui.SameLine()
                    end
                    if ImGui.SmallButton('Remove') then
                        table.remove(cfg.waypoints, i)
                        if state.wpIndex > #cfg.waypoints then state.wpIndex = 1 end
                        state.wpArrivedIdx = nil -- indexes shifted
                        saveCfg()
                        ImGui.PopID()
                        break
                    end
                    -- Second line: what to do on arrival. Both optional --
                    -- blank command and 0 delay just walk straight through.
                    ImGui.Indent(20)
                    ImGui.SetNextItemWidth(160)
                    local cmdV, cmdChanged = ImGui.InputText('Cmd##cmd', wp.cmd or '')
                    if cmdChanged then wp.cmd = cmdV; saveCfg() end
                    if ImGui.IsItemHovered() then
                        ImGui.SetTooltip('Runs once when you arrive at this waypoint. Blank = nothing.\n' ..
                            'For several commands: /multiline ; /cmd1;/cmd2')
                    end
                    ImGui.SameLine()
                    local curDelay = tonumber(wp.delay) or 0
                    local dl = preciseSlider('Delay (s)##delay', curDelay, 0, 120)
                    if dl ~= curDelay then wp.delay = dl; saveCfg() end
                    if ImGui.IsItemHovered() then
                        ImGui.SetTooltip('Seconds to hold at this waypoint before moving on (0 = none).\n' ..
                            'Still pulls anything that shows up while waiting.')
                    end
                    ImGui.Unindent(20)
                    ImGui.PopID()
                end
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Resource Gate') then
            ImGui.TextDisabled('Pauses pulling below a threshold and sits to recover, same idea as')
            ImGui.TextDisabled('triune\'s MedBreak -- resumes once back above the Stop %.')
            ImGui.Spacing()

            local en = ImGui.Checkbox('Enabled##restEnabled', cfg.restEnabled)
            if en ~= cfg.restEnabled then cfg.restEnabled = en; saveCfg() end

            local hpOn = ImGui.Checkbox('HP##hpOn', cfg.hpOn)
            if hpOn ~= cfg.hpOn then cfg.hpOn = hpOn; saveCfg() end
            if cfg.hpOn then
                local s = preciseSlider('Start %##hpStart', cfg.hpStart, 1, 99)
                if s ~= cfg.hpStart then cfg.hpStart = s; saveCfg() end
                local p = preciseSlider('Stop %##hpStop', cfg.hpStop, 1, 100)
                if p ~= cfg.hpStop then cfg.hpStop = p; saveCfg() end
            end

            local mpOn = ImGui.Checkbox('Mana##manaOn', cfg.manaOn)
            if mpOn ~= cfg.manaOn then cfg.manaOn = mpOn; saveCfg() end
            if cfg.manaOn then
                local s = preciseSlider('Start %##manaStart', cfg.manaStart, 1, 99)
                if s ~= cfg.manaStart then cfg.manaStart = s; saveCfg() end
                local p = preciseSlider('Stop %##manaStop', cfg.manaStop, 1, 100)
                if p ~= cfg.manaStop then cfg.manaStop = p; saveCfg() end
            end

            local epOn = ImGui.Checkbox('Endurance##endOn', cfg.endOn)
            if epOn ~= cfg.endOn then cfg.endOn = epOn; saveCfg() end
            if cfg.endOn then
                local s = preciseSlider('Start %##endStart', cfg.endStart, 1, 99)
                if s ~= cfg.endStart then cfg.endStart = s; saveCfg() end
                local p = preciseSlider('Stop %##endStop', cfg.endStop, 1, 100)
                if p ~= cfg.endStop then cfg.endStop = p; saveCfg() end
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Swarm Pull') then
            ImGui.TextDisabled('Gathers several mobs onto XTarget before engaging, instead of')
            ImGui.TextDisabled('tagging and fighting one at a time.')
            ImGui.Spacing()

            local se = ImGui.Checkbox('Enabled##swarmEnabled', cfg.swarmEnabled)
            if se ~= cfg.swarmEnabled then cfg.swarmEnabled = se; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Hunt mode: gathers the count below, then fights them all in place.\n' ..
                    'Camp mode: gathers the count below, then drags the whole group home\n' ..
                    '(they all follow whoever they\'re hating, same as any pull).')
            end

            local sc = preciseSlider('Pull Count##swarmCount', cfg.swarmCount, 1, 20)
            if sc ~= cfg.swarmCount then cfg.swarmCount = sc; saveCfg() end

            ImGui.SetNextItemWidth(220)
            local tc, tcChanged = ImGui.InputText('Tag Command (blank = body pull)##swarmTagCmd', cfg.swarmTagCmd)
            if tcChanged then cfg.swarmTagCmd = tc; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Sent once per candidate, in range, while gathering. Leave blank for a\n' ..
                    'pure body pull -- walk into range and let EQ\'s own proximity/faction\n' ..
                    'aggro do it, no damage dealt, so nothing gets a chance to summon you\n' ..
                    'before the batch is complete. Set this (e.g. /attack on) only if you\n' ..
                    'specifically want to tag with damage during the gather -- your own\n' ..
                    'summon risk to accept, same as a normal single pull.')
            end

            local sfs = ImGui.Checkbox('Fight when summoned##swarmFightOnSummon', cfg.swarmFightOnSummon)
            if sfs ~= cfg.swarmFightOnSummon then cfg.swarmFightOnSummon = sfs; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('If something summons you mid-gather, stop gathering and fight (or\n' ..
                    'head back to camp) right away with whatever\'s already aggro\'d, even\n' ..
                    'below Pull Count.')
            end

            local sha = ImGui.Checkbox('Stop gathering below HP %##swarmHpAbortEnabled', cfg.swarmHpAbortEnabled)
            if sha ~= cfg.swarmHpAbortEnabled then cfg.swarmHpAbortEnabled = sha; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Same idea, triggered by your own HP instead of a summon -- an add, a\n' ..
                    'trap, or unlucky proximity aggro chewing on you while you\'re still out\n' ..
                    'gathering more.')
            end
            if cfg.swarmHpAbortEnabled then
                local hap = preciseSlider('HP %##swarmHpAbortPct', cfg.swarmHpAbortPct, 1, 99)
                if hap ~= cfg.swarmHpAbortPct then cfg.swarmHpAbortPct = hap; saveCfg() end
            end

            if ImGui.CollapsingHeader('Advanced##swarmAdv') then
                local pr = preciseSlider('Pull Range##swarmPullRange', cfg.swarmPullRange, 5, 100)
                if pr ~= cfg.swarmPullRange then cfg.swarmPullRange = pr; saveCfg() end
                local aw = preciseSlider('Aggro Wait (sec)##swarmAggroWait', cfg.swarmAggroWait, 1, 15)
                if aw ~= cfg.swarmAggroWait then cfg.swarmAggroWait = aw; saveCfg() end
                local mc = preciseSlider('Max Chase (sec)##swarmMaxChase', cfg.swarmMaxChase, 10, 180)
                if mc ~= cfg.swarmMaxChase then cfg.swarmMaxChase = mc; saveCfg() end
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Priority List') then
            ImGui.TextDisabled('Rare/named mobs that jump the queue when up, instead of waiting their')
            ImGui.TextDisabled('turn behind whatever happens to be closer. Saved per zone.')
            ImGui.Spacing()

            local pe = ImGui.Checkbox('Enabled##priorityEnabled', cfg.priorityEnabled)
            if pe ~= cfg.priorityEnabled then cfg.priorityEnabled = pe; saveCfg() end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('When a mob on this zone\'s list is up and otherwise pullable (still has\n' ..
                    'to pass level/faction/anchor-radius/arc like anything else -- this only\n' ..
                    'changes WHICH mob gets picked, not what\'s allowed), it\'s pulled before\n' ..
                    'anything else, regardless of distance.')
            end

            local zoneName = currentZoneShortName()
            ImGui.TextDisabled('Current zone: ' .. (zoneName ~= '' and zoneName or '(unknown)'))
            ImGui.Spacing()

            ImGui.SetNextItemWidth(220)
            local pin, pinChanged = ImGui.InputText('##priorityInput', state.priorityInput)
            if pinChanged then state.priorityInput = pin end
            ImGui.SameLine()
            if ImGui.Button('Add##priorityAdd') then
                local name = (state.priorityInput or ''):gsub('^%s+', ''):gsub('%s+$', '')
                if name ~= '' then
                    local list = ensurePriorityList()
                    if list then
                        local already = false
                        for _, n in ipairs(list) do if n:lower() == name:lower() then already = true; break end end
                        if not already then table.insert(list, name); saveCfg() end
                        state.priorityInput = ''
                    end
                end
            end

            local tName, tType = nil, nil
            pcall(function() tName = mq.TLO.Target.CleanName(); tType = mq.TLO.Target.Type() end)
            if tName and tType == 'NPC' then
                if ImGui.Button('Add Current Target (' .. tName .. ')##priorityAddTarget') then
                    local list = ensurePriorityList()
                    if list then
                        local already = false
                        for _, n in ipairs(list) do if n:lower() == tName:lower() then already = true; break end end
                        if not already then table.insert(list, tName); saveCfg() end
                    end
                end
            end

            ImGui.Spacing()
            local list = zoneName ~= '' and cfg.priorityLists[zoneName] or nil
            if not list or #list == 0 then
                ImGui.TextDisabled('No priority names saved for this zone.')
            else
                for i, n in ipairs(list) do
                    ImGui.PushID('prio' .. i)
                    ImGui.Text(n)
                    ImGui.SameLine()
                    if ImGui.SmallButton('Remove') then
                        table.remove(list, i)
                        saveCfg()
                        ImGui.PopID()
                        break
                    end
                    ImGui.PopID()
                end
            end
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem('Pull Arc') then
            drawArcTab()
            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
        end
    end
    ImGui.End()
end

-- ----------------------------------------------------------------------------
-- Commands + main loop
-- ----------------------------------------------------------------------------
local function cmd_puller(sub, arg1)
    sub = sub and sub:lower() or 'help'
    if sub == 'start' or sub == 'resume' then
        cfg.enabled = true; saveCfg()
        printf('Pulling started.')
    elseif sub == 'stop' or sub == 'pause' then
        stopPulling()
        printf('Pulling stopped.')
    elseif sub == 'setcamp' then
        local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
        if x and y and z then
            cfg.campLoc = { x = x, y = y, z = z, zone = currentZoneShortName() }
            cfg.campHeading = mq.TLO.Me.Heading.Degrees()
            state.arcAiming.Camp = false
            saveCfg()
            printf('Camp set to current position.')
        end
    elseif sub == 'clearcamp' then
        cfg.campLoc = nil; saveCfg()
        printf('Camp cleared.')
    elseif sub == 'addwp' then
        local x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
        if x and y and z then
            table.insert(cfg.waypoints, { x = x, y = y, z = z, name = 'WP ' .. (#cfg.waypoints + 1), cmd = '', delay = 0 })
            saveCfg()
            printf('Waypoint %d added at current position.', #cfg.waypoints)
        end
    elseif sub == 'clearwp' then
        cfg.waypoints = {}; state.wpIndex = 1; state.wpArrivedIdx = nil; saveCfg()
        printf('Waypoints cleared.')
    elseif sub == 'mode' then
        local m = arg1 and arg1:lower()
        if m == 'camp' then
            cfg.pullMode = 'Camp'; saveCfg(); printf('Pull mode: Camp.')
        elseif m == 'hunt' then
            cfg.pullMode = 'Hunt'; saveCfg(); printf('Pull mode: Hunt.')
        else
            printf('Usage: /puller mode camp|hunt (current: %s)', cfg.pullMode)
        end
    elseif sub == 'status' then
        printf('%s', statusLine())
    elseif sub == 'force' or sub == 'forceengage' then
        forceEngage()
    else
        printf('/puller start|stop|setcamp|clearcamp|addwp|clearwp|mode camp|mode hunt|status|force')
    end
end

if not navLoaded() then
    printf('MQ2Nav does not appear to be loaded -- pulling needs it to travel to/from camp.')
end

-- One-time cleanup: an earlier version of this script drew the radius with
-- MQ2Map's player-centered CastRadius filter instead of a pinned /maploc.
-- That filter persists in MQ2Map.ini across sessions/script versions, so a
-- character that ever ran that version would otherwise keep showing a
-- circle around themselves forever, on top of the pinned one below.
mq.cmd('/mapfilter castradius 0')

mq.imgui.init('pullerGUI', drawGUI_)
mq.bind('/puller', cmd_puller)
mq.bind('/pullerexit', function() running = false end)

printf('Loaded. /puller start to begin, /puller help for commands.')

local lastZoneId = mq.TLO.Zone.ID()

-- Camp/anchor points saved before they carried a zone tag: assume they
-- belong to the zone the script is started in (the usual case), so the
-- zone-change pause below has something to compare against.
do
    local zs = currentZoneShortName()
    if zs ~= '' then
        local tagged = false
        for _, loc in ipairs({ cfg.campLoc or false, cfg.huntAnchor or false }) do
            if loc and not loc.zone then loc.zone = zs; tagged = true end
        end
        if tagged then saveCfg() end
    end
end

while running do
    mq.doevents()

    -- Spawn IDs are per-zone-instance, so tempIgnore entries from the last
    -- zone are meaningless here; conCache/conAskedAt are name-keyed and
    -- would otherwise just grow for as long as the script runs. Clearing
    -- all three on zone change is both the correctness fix (stale ids/
    -- considers from elsewhere) and what keeps them from growing without
    -- bound over a long session.
    -- pullTargetId/lastChaseId/lastHitById are the exact same kind of
    -- per-zone-instance id -- a stale one left pointing at whatever
    -- numeric id it last held can, after zoning, resolve to a different,
    -- unrelated spawn that happens to reuse that id in the new zone (or to
    -- nothing at all). Reset alongside the caches above for the same
    -- reason; cfg.enabled is left alone so pulling just continues fresh in
    -- the new zone instead of needing a manual /puller start every zone.
    local zoneId = mq.TLO.Zone.ID()
    if zoneId ~= lastZoneId then
        lastZoneId = zoneId
        state.tempIgnore = {}
        state.conCache = {}
        state.pullState = 'IDLE'
        state.pullTargetId = 0
        state.lastChaseId = 0
        state.lastHitById = 0
        state.lastHitAt = 0
        state.meleeChaseStuckSince = nil
        state.engagedIds = {}
        state.swarmSkip = {}
        state.swarmSummoned = false
        state.swarmTagged = false
        state.swarmAggroSince = nil
        state.conAskedAt = {}
        -- The old /maploc marker belonged to the previous zone; forget it so
        -- syncMapCircle redraws here instead of assuming it's still shown.
        state.mapLocLoc = nil
        state.mapLocRadius = nil
        state.safeLocLoc = nil
        state.safeLocRadius = nil
        state.lootWaitSince = nil
        -- campLoc/huntAnchor are coordinates in the zone they were set in.
        -- Carrying on here would scan around (and, with Return to AP, walk
        -- toward) a meaningless spot in this zone, so pause instead.
        local anchor = cfg.pullMode == 'Camp' and cfg.campLoc or cfg.huntAnchor
        local zs = currentZoneShortName()
        if cfg.enabled and anchor and anchor.zone and zs ~= '' and anchor.zone ~= zs then
            stopPulling()
            printf('Zoned out of %s (where the %s is set) -- pulling paused. Set a new one here, then /puller start.',
                anchor.zone, cfg.pullMode == 'Camp' and 'camp' or 'hunt anchor')
        end
    end

    -- Backstop for long sessions that never zone: sweep out tempIgnore
    -- entries whose 60s window already passed instead of waiting on a
    -- zone change to flush them.
    local nowPrune = os.clock()
    if nowPrune - (state.lastPruneAt or 0) >= 300 then
        state.lastPruneAt = nowPrune
        for id, expiresAt in pairs(state.tempIgnore) do
            if expiresAt <= nowPrune then state.tempIgnore[id] = nil end
        end
    end

    -- Only useful during an actual fight (that's the only place the FIGHTING
    -- sweep reads it), and only while there's something unannounced to
    -- decide on -- querying continuously for a fight's whole duration (or
    -- in IDLE/TO_MOB/TO_CAMP too) just printed /e3echo's visible chat
    -- output once a second the entire time, most of it telling us nothing
    -- new.
    if state.pullState == 'FIGHTING' and hasUnannouncedHostile() then
        queryE3State() -- throttled internally; safe to call every pass
    end
    pullTick()
    mq.delay(200)
end

removeMapLocCircle()
if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
mq.unbind('/puller')
mq.unbind('/pullerexit')
mq.exit()
