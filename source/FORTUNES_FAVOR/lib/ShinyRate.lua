-- Fortune's Favor -- the shiny RATE, and only the rate.
--
-- ------- division of responsibility (PLAN.md, decided)
--
--   global shiny on/off ....... Dramatic Mini Modifications
--   shiny rate ................ this mod
--
-- Off beats rate, unconditionally, and no coordination is needed to make
-- that true: DRAMATIC_MINI intercepts `Shiny.isShiny` (the read every shiny
-- surface makes) while this file writes `Shiny.ODDS_DENOM` (the roll). One
-- owns a boolean, the other owns a denominator, and they never touch the
-- same value. With the boolean off, nothing this file does is visible.
--
-- ------- standalone safety, which is a hard requirement
--
-- Shiny is NOT a vanilla Gen 1 feature. It comes from Dramatic Shape, which
-- derives it from DVs. So this whole file is gated on
-- `mod.find("DRAMATIC_SHAPE")` returning a handle, and that call answers nil
-- when the other mod is absent, disabled, failed, OR HAS SIMPLY NOT RUN YET.
-- All four collapse to the same behaviour: the SHINY row is not offered and
-- no shiny code path is ever entered.
--
-- The handle is resolved lazily and RE-CHECKED, never cached as "absent":
-- load order is not ours to choose, and a mod that gave up on the first miss
-- would be permanently broken by an ordering change.
--
-- The slots and the lottery are vanilla-engine features and work regardless.
--
-- ------- why NORMAL unpins rather than pinning 8192
--
-- Dramatic Shape's `Shiny.setOdds` PINS the denominator (its own comment
-- says so, lib/Shiny.lua:110-125): once pinned, its SHINY ODDS row stops
-- being read. So "NORMAL changes nothing" cannot mean "pin 8192" -- that
-- would silently break another mod's settings row. At NORMAL this file calls
-- `Shiny.unpinOdds()` instead and hands control straight back.
--
-- Every call goes through pcall, so an unfamiliar shape on a future Dramatic
-- Shape version switches the feature off rather than throwing.
--
-- ------- WE ARE NOT THE ONLY CALLER OF setOdds, AND WE USED TO ACT LIKE IT
--
-- `Shiny.setOdds` is documented for "a driver or a test" as much as for us
-- (DRAMATIC_SHAPE/lib/Shiny.lua:109-112), and this install has several: the
-- capture rigs under game/tests/drivers/sv pin 1:1 to make every encounter
-- shiny. Dramatic Shape's own `pinned` flag guards the OPTIONS row -- once
-- anything has pinned, `odds()` stops reading the setting -- but it does NOT
-- guard `setOdds` itself, which is a plain last-writer-wins assignment.
--
-- So this file used to overwrite a pin it did not set. Measured on the real
-- module, headless, before the fix:
--
--   driver: Shiny.setOdds(1)          odds() == 1
--   us:     ShinyRate.apply(...)      odds() == 2048   -- pin gone
--
-- and worse on the NORMAL path, where `unpinOdds` took the pin away AND
-- handed the rate to the player's row (odds() == 512, the stored setting).
-- The cost was real: a test matrix that pins per creature came back with
-- every cell non-shiny and reported the cells UNREACHABLE -- a false
-- negative that looked exactly like a different feature being broken, since
-- the only trace was our own "shiny rate -> 1:2048" line in the log.
--
-- ------- what we do instead: DEFER, AND SAY SO
--
-- Before writing, ask who owns the denominator (`ownership` below) and act
-- on the answer:
--
--   free    nothing is pinned -- take it, exactly as before.
--   ours    we are still holding the value we set -- change it freely.
--   theirs  somebody pinned it, or overwrote what we pinned -- STAND ASIDE.
--           We do not write, we do not unpin, and we log it once. `applied`
--           is cleared so we claim nothing, and because the heartbeat calls
--           us every frame we take the rate again the moment the other
--           holder lets go. Deferring rather than restoring-afterwards is
--           the choice because there is no "afterwards": a pin has no
--           duration, so the only honest reading of someone else's pin is
--           that it is in force until they release it.
--   unknown Dramatic Shape is not the shape we know -- treated as `theirs`,
--           i.e. the feature switches itself off, which is what the rest of
--           this file already does with an unfamiliar shape.
--
-- The player pays nothing for this: with no driver and no other mod, the
-- answer is always `free` or `ours` and the rate moves exactly as it did.
--
-- ------- how ownership is asked, without editing Dramatic Shape
--
-- `pinned` is a local upvalue over there with no getter, and Dramatic Shape
-- is third-party: `update-extras.sh` re-syncs it with `rsync -a --delete`,
-- so a getter added there would be discarded on the next update (the same
-- reason SPRITE_VARIETY/lib/Viewport.lua repairs a dropped return value on
-- our side rather than at its source). The flag is still OBSERVABLE, because
-- `odds()` behaves differently under it -- unpinned it rewrites ODDS_DENOM
-- from the settings row, pinned it leaves the field alone. So park a
-- sentinel in ODDS_DENOM, call `odds()`, and see whether the sentinel
-- survived. That is `pinnedNow`, and it reads the real flag rather than a
-- guess about it.

local ShinyRate = {}

local applied = nil     -- the denominator WE are holding; nil means none
local bound = false
local deferredTo = nil  -- log-once key for what we last stood aside for

local function shinyLib(mod)
  local ok, handle = pcall(function() return mod.find("DRAMATIC_SHAPE") end)
  if not (ok and handle and handle.exports and handle.exports.lib) then
    return nil
  end
  local okM, Shiny = pcall(handle.exports.lib.require, "Shiny")
  if not (okM and type(Shiny) == "table") then return nil end
  return Shiny, handle.version
end

-- Is Dramatic Shape reachable right now? Asked fresh every time, so the row
-- appears the moment the other mod is up and disappears if it is turned off.
function ShinyRate.available(mod)
  return shinyLib(mod) ~= nil
end

-- ------- reading the pin
--
-- The sentinel must be a value the settings row can NEVER hold: if an
-- unpinned `odds()` could write the sentinel back over itself, the probe
-- would read a coincidence as a pin. The row's ladder is the powers of two
-- from 1 to 8192 (lib/Shiny.lua:80) and it can only ever answer with a rung
-- of it -- an unrecognised stored value falls back to the first rung rather
-- than passing through (ModSetting:read -> indexOf -> 1). 8191 is off that
-- ladder. It is also a legal denominator in its own right, so in the
-- impossible case of one being left behind the cost is one slightly wrong
-- roll and never a divide by zero.
local PROBE_DENOM = 8191

-- true / false / nil, where nil means "cannot tell".
--
-- The probe is invisible: when pinned we put the holder's value straight
-- back, and when it is not pinned `odds()` has already refreshed ODDS_DENOM
-- from the row, which is what any other caller of `odds()` would have left
-- there anyway.
--
-- One honest limitation, stated rather than hidden: if Dramatic Shape's
-- settings row is unreadable, `odds()` leaves ODDS_DENOM alone whether it is
-- pinned or not, and the sentinel survives either way -- so an unreadable
-- row reads here as "pinned". That is the safe direction (we stand aside
-- instead of trampling) and it cannot happen on a healthy install: ModSetting
-- pcalls its own read and falls back to the ladder's first rung.
local function pinnedNow(Shiny)
  if type(Shiny.odds) ~= "function" then return nil end
  local saved = Shiny.ODDS_DENOM
  Shiny.ODDS_DENOM = PROBE_DENOM
  local ok = pcall(Shiny.odds)
  if not ok then
    Shiny.ODDS_DENOM = saved
    return nil
  end
  local isPinned = (Shiny.ODDS_DENOM == PROBE_DENOM)
  if isPinned then Shiny.ODDS_DENOM = saved end
  return isPinned
end

-- "free" | "ours" | "theirs" | "unknown" -- see the header.
--
-- "ours" is a pin whose value is still the one we set. If somebody else has
-- written since, the value no longer matches and the answer is "theirs",
-- which is the whole point: we notice being overwritten instead of
-- overwriting back.
--
-- The one case this cannot resolve is another holder pinning the very
-- denominator we asked for. It reads as "ours", and we would eventually
-- change it. Nothing in the seam can separate those two, the values agree so
-- nothing is wrong until we move, and refusing to move would break our own
-- feature on a coincidence.
local function ownership(Shiny)
  local isPinned = pinnedNow(Shiny)
  if isPinned == nil then return "unknown" end
  if not isPinned then return "free" end
  if applied ~= nil and Shiny.ODDS_DENOM == applied then return "ours" end
  return "theirs"
end

-- ctx = { Luck, log, mod, enabled() -> bool, tier() -> string }
--
-- Idempotent and cheap: called from the heartbeat, and does nothing at all
-- unless the wanted denominator differs from the one we are holding. The
-- ownership probe is only reached past that test -- so on a settled install
-- it never runs, and while we are deferring it costs one pcall a frame,
-- which is the price of not silently trampling the other holder.
function ShinyRate.apply(ctx)
  local Luck = ctx.Luck
  local wanted = nil
  if ctx.enabled() then
    wanted = Luck.SHINY_DENOM[Luck.tierOf(ctx.tier())]
  end
  if wanted == applied then return end

  local Shiny, version = shinyLib(ctx.mod)
  if not Shiny then return end
  if not bound then
    bound = true
    if ctx.log then
      ctx.log:info("bound to Dramatic Shape %s for shiny rate", tostring(version))
    end
  end

  -- ------- whose denominator is it?
  local held = ownership(Shiny)
  if held ~= "free" and held ~= "ours" then
    -- Somebody else is holding it. We claim nothing from here on, so the
    -- next ownership test cannot mistake their value for ours.
    applied = nil
    if wanted == nil then
      -- We had nothing to hand back anyway. Silent: NORMAL over someone
      -- else's pin is not an event.
      deferredTo = nil
      return
    end
    -- Log once per situation, not once per frame: the heartbeat calls us
    -- every frame and a deferral can last a whole capture run.
    local theirs = Shiny.ODDS_DENOM
    local key = held .. ":" .. tostring(theirs)
    if deferredTo ~= key then
      deferredTo = key
      if ctx.log then
        ctx.log:info(
          "shiny rate 1:%s deferred -- odds pinned to %s by something else; "
          .. "will apply when it lets go",
          tostring(wanted),
          held == "unknown" and "an unrecognised Dramatic Shape"
            or ("1:" .. tostring(theirs)))
      end
    end
    return
  end
  deferredTo = nil

  if wanted == nil then
    -- NORMAL, or the row switched off: give Dramatic Shape its own row back.
    -- Only ever reached with the pin free or ours, so this can no longer
    -- unpin somebody else's.
    if type(Shiny.unpinOdds) ~= "function" then return end
    if not pcall(Shiny.unpinOdds) then return end
  else
    if type(Shiny.setOdds) ~= "function" then return end
    if not pcall(Shiny.setOdds, wanted) then return end
  end
  applied = wanted
  if ctx.log then
    ctx.log:info("shiny rate -> %s",
      wanted and ("1:" .. wanted) or "Dramatic Shape's own row")
  end
end

-- ------- MISSINGNO's yield: the forced shiny stepping aside
--
-- At 1:1 every wild encounter is shiny BY DEFINITION, so the normal half of
-- a collection is unreachable at the very tier meant to finish one. The two
-- top rungs split that knot (lib/Luck.lua): STARDUST keeps 1:1 forever,
-- MISSINGNO keeps 1:1 only while it is still buying you something.
--
-- The rule, per species: while ANY cartridge's shiny of it is unheld, the
-- force stands -- shiny first, which is what was asked for. Once every one
-- of them is held, the force yields for that species and its encounters come
-- up normal so the gaps can fill. Nothing about the RATE the player chose
-- changes; what changes is that we stop spending a roll on a finish they
-- already own.
--
-- ------- where it has to happen, and why not on the rate
--
-- The denominator is global -- `Shiny.ODDS_DENOM` -- and knows no species,
-- so a per-species decision cannot live there. The verdict is written by
-- Dramatic Shape's own `Pokemon.new` wrapper (lib/ShinyBattle.lua:52), so
-- ours goes OUTSIDE that one and corrects the verdict afterwards, using that
-- mod's OWN `Shiny.set(mon, false)`. That matters for legality: the DVs a
-- yielded creature ends up with are the ones Dramatic Shape's own non-shiny
-- path writes, byte for byte, not something this mod invented. A player who
-- uninstalls every mod is left with an ordinary Gen 1 creature.
--
-- ------- scoped to WILD encounters only
--
-- `Pokemon.new` also builds starters, gifts, trades and every trainer's
-- party. None of those are what the player is hunting, so the yield is ARMED
-- by our own `encounter.roll` link (lib/WildLuck.lua) and consumed by the
-- first construction after it. The arm carries no species: Sprite Variety
-- may substitute one on `encounter.species` after we return, and the
-- creature that actually gets built is the one whose collection we should be
-- reading.
--
-- The arm also EXPIRES. If an encounter is vetoed downstream -- a repel, a
-- suppressing mod -- the flag would otherwise sit there and be spent on
-- whatever was built next, which could be a gift. One frame of life through
-- the heartbeat is far longer than the gap between the roll and the battle's
-- own construction and far shorter than the gap to anything else.
--
-- ------- one frame was NOT tight enough, in both directions
--
-- Two holes, found together, and one mechanism closes both.
--
-- THE LEAK. A repel-vetoed encounter arms the flag and never builds
-- anything, and the veto is decided AFTER our link returns
-- (OverworldController.lua:3598-3603) so we cannot see it. A trainer battle
-- starting in that same frame then calls `Pokemon.new` for every mon in the
-- opponent's party, and the first of them spends the arm. Harmless as it
-- stands -- `newTrainer` overwrites `mon.dvs` with the shared trainer table
-- immediately afterwards (BattleState.lua:684-692), so the yield's write is
-- erased before anything reads it -- but "harmless because a later line
-- happens to overwrite it" is a coincidence, not a design.
--
-- Worth naming, because it is the obvious fix and it does not work: Sprite
-- Variety's `Resolve.isTrainerMon` identifies an opponent EXACTLY, by
-- reference to that shared DV table. It cannot help here. At the moment our
-- wrap runs -- inside `Pokemon.new`, on the way out -- the creature still
-- carries the DVs `Stats.randomDVs` just rolled for it
-- (src/pokemon/Pokemon.lua:63); `newTrainer` replaces them on the NEXT line.
-- So `rawequal(mon.dvs, trainerDvs)` is false for every trainer mon we could
-- ever be asked about, and would be false even if that constant were
-- populated -- which on this install it is not (Red, Blue and Yellow all
-- carry no `data.constants.trainerDvs`, the reason SPRITE_VARIETY's main.lua
-- goes upvalue-hunting for `BattleState`'s file-local instead).
--
-- THE GAP. Fishing reaches the battle through two player-paced text boxes
-- (OverworldController.lua:1660-1676), so its construction is an unbounded
-- number of frames after the bite. A one-frame arm is always dead by then,
-- which is why the yield has never applied to a rod.
--
-- ------- the arm is a WILD BATTLE's, and nobody else's
--
-- So the flag is scoped by WHAT IS BEING BUILT rather than by when. A pass-
-- through wrap on `BattleState.newWild` -- the one and only constructor of a
-- wild battle, and the caller of the `Pokemon.new` we care about
-- (BattleState.lua:595) -- raises a depth on the way in and drops it on the
-- way out. `yieldFor` refuses outside that depth and, crucially, refuses
-- WITHOUT SPENDING the arm: a trainer's party can no longer consume it, and
-- neither can a gift, a starter or a trade.
--
-- That also makes an arm that outlives its frame safe, which is what lets
-- fishing work: `armWild(true)` takes a STICKY arm the heartbeat will not
-- expire, and leaving the wild-battle scope clears it whether it was spent
-- or not. So a sticky arm lives at most until the next wild battle is built
-- -- which is exactly the one it was taken for.
--
-- The depth gate only applies once the wrap is really on. On a build where
-- `BattleState.newWild` cannot be found, everything behaves exactly as it
-- did before this paragraph existed -- one frame, no sticky arms, and the
-- rod gap and the trainer leak both still open -- rather than the yield
-- switching itself off. Sticky arms are refused in that state for the same
-- reason: nothing would be left to bound them.
local armed = false
local sticky = false
local wildDepth = 0

--- Arm the yield. `stick` asks for an arm the frame heartbeat will not
--- expire, which is only granted while the wild-battle scope is there to
--- bound it.
function ShinyRate.armWild(stick)
  armed = true
  sticky = (stick and ShinyRate.scopeInstalled) and true or false
end

function ShinyRate.disarm()
  if sticky then return end
  armed = false
end

function ShinyRate.armedForTest() return armed end
function ShinyRate.stickyForTest() return sticky end
function ShinyRate.wildDepthForTest() return wildDepth end

function ShinyRate.enterWildBattle() wildDepth = wildDepth + 1 end

function ShinyRate.exitWildBattle()
  wildDepth = wildDepth - 1
  if wildDepth <= 0 then
    -- A wild battle has been built. Whether or not it took the arm, the arm's
    -- one job is done, so nothing of it survives to reach a later
    -- construction -- including a sticky one.
    wildDepth = 0
    armed, sticky = false, false
  end
end

-- Wrap `BattleState.newWild` as a pure pass-through that only moves the
-- depth. Idempotent by the same per-instance flag `installYield` uses, and
-- installed from the heartbeat; unlike the yield wrap it has no ordering
-- requirement, because it changes nothing about the value it forwards.
function ShinyRate.installWildScope(ctx)
  if ShinyRate.scopeInstalled then return true end
  local okB, BattleState = pcall(require, "src.battle.BattleState")
  if not (okB and type(BattleState) == "table"
          and type(BattleState.newWild) == "function") then
    return false
  end
  local inner = BattleState.newWild
  BattleState.newWild = function(...)
    ShinyRate.enterWildBattle()
    -- pcall so the depth is dropped even when the engine's own constructor
    -- throws (it asserts on an unknown species); the error is re-raised
    -- unchanged so nothing downstream sees a different failure.
    local ok, battle = pcall(inner, ...)
    ShinyRate.exitWildBattle()
    if not ok then error(battle, 0) end
    return battle
  end
  ShinyRate.scopeInstalled = true
  -- A sentinel a DEVICE driver can see, for the same reason
  -- `Pokemon.fortunesFavorYield` exists: our libs are loaded through
  -- `mod:read` + `load` and are on no package path, so "did this wrap take on
  -- the real build" is otherwise unanswerable from outside.
  BattleState.fortunesFavorWildScope = true
  if ctx and ctx.log then
    ctx.log:info("MISSINGNO yield scoped to the wild battle constructor")
  end
  return true
end

-- ctx as apply(), plus ctx.Holdings. Returns true when the verdict was
-- changed, which is what the test asserts on.
function ShinyRate.yieldFor(ctx, mon)
  if not armed then return false end
  -- Not a wild battle's creature: leave it alone AND leave the arm standing.
  -- Spending it here is the leak -- a trainer's whole party goes through
  -- `Pokemon.new` and the first mon would take an arm meant for the wild
  -- encounter that a repel had just vetoed.
  if ShinyRate.scopeInstalled and wildDepth <= 0 then return false end
  armed, sticky = false, false
  if not ctx.enabled() then return false end
  local Luck = ctx.Luck
  if not Luck.isCompletionHunt(ctx.tier()) then return false end
  if type(mon) ~= "table" or mon.species == nil then return false end

  local Shiny = shinyLib(ctx.mod)
  if not (Shiny and type(Shiny.isShiny) == "function"
          and type(Shiny.set) == "function") then
    return false
  end
  -- only ever turns a shiny OFF; a non-shiny roll is none of our business
  local okIs, isShiny = pcall(Shiny.isShiny, mon)
  if not (okIs and isShiny == true) then return false end

  local Holdings = ctx.Holdings
  if not Holdings then return false end
  local snap = Holdings.snapshot(ctx)
  -- No shiny axis means no collection to complete: never yield, so the tier
  -- behaves exactly as it did before this existed.
  if not (snap and snap.hasShinyAxis) then return false end
  if not snap.shinyComplete(mon.species) then return false end

  if not pcall(Shiny.set, mon, false) then return false end
  if ctx.log and not ShinyRate.loggedYield then
    ShinyRate.loggedYield = true
    ctx.log:info(
      "MISSINGNO yield: %s's shinies are all held, so its wilds come up "
      .. "normal now -- filling the gaps", tostring(mon.species))
  end
  return true
end

-- Wrap Pokemon.new OUTSIDE Dramatic Shape's wrapper. Idempotent by
-- sentinel, the pattern every wrap on this install uses, and installed from
-- the heartbeat so it lands after that mod whatever the load order was.
function ShinyRate.installYield(ctx)
  if ShinyRate.yieldInstalled then return true end
  local okP, Pokemon = pcall(require, "src.pokemon.Pokemon")
  if not (okP and type(Pokemon) == "table" and type(Pokemon.new) == "function") then
    return false
  end
  -- Dramatic Shape stamps this the moment ITS wrap is on. Waiting for it is
  -- what makes ours the outer one, so the verdict exists to be corrected.
  if not Pokemon.dramaticShapeShiny then return false end
  local inner = Pokemon.new
  Pokemon.new = function(data, species, level, rng)
    local mon = inner(data, species, level, rng)
    pcall(ShinyRate.yieldFor, ctx, mon)
    return mon
  end
  ShinyRate.yieldInstalled = true
  -- A sentinel a DEVICE driver can see. The lib modules are loaded through
  -- `mod:read` + `load` and are not on any package path, so "did the wrap
  -- take on the real build" is otherwise unanswerable from outside -- which
  -- is exactly the kind of thing a headless run cannot tell you.
  Pokemon.fortunesFavorYield = true
  if ctx.log then
    ctx.log:info("MISSINGNO shiny yield armed on the wild encounter seam")
  end
  return true
end

-- Called when the mod is being taken out of the picture, so a pinned
-- denominator never outlives the reason for it.
--
-- Only OUR pin is released. A denominator somebody else pinned outlives us
-- on purpose: their reason for it has not gone away just because ours has.
function ShinyRate.release(ctx)
  local Shiny = shinyLib(ctx.mod)
  if Shiny and ownership(Shiny) == "ours"
      and type(Shiny.unpinOdds) == "function" then
    pcall(Shiny.unpinOdds)
  end
  applied = nil
  deferredTo = nil
end

return ShinyRate
