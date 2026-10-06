-- Fortune's Favor -- luck reaching the WILD ENCOUNTER pick, and only the
-- pick. All arithmetic lives in lib/Luck.lua (system 3); this file is the
-- seam onto the engine, and its whole job is to reweight WITHIN a map's own
-- table without ever disturbing anything else that lives on that seam.
--
-- ------- the seam, and who else is standing on it
--
-- The engine wraps its wild pick in TWO hooks (OverworldController:3456):
--
--   encounter.roll     around the bare Encounter.roll -- return nil to
--                      suppress, a table without calling next to force
--   encounter.species  a transform of a non-nil roll, before repel
--
-- Both have owners on this install, checked before this file was designed
-- (the ShinyRate lesson: this mod once clobbered a Shiny.setOdds pin it did
-- not set, and the fix was to ask first and defer):
--
--   * overworld_wild_spawns wraps encounter.roll at default priority 0 and
--     SUPPRESSES the classic roll while its visible-spawn system owns
--     encounters (it returns nil without calling next).
--   * SPRITE_VARIETY wraps encounter.species at priority 10 and may
--     SUBSTITUTE the species for its own placed one-time wilds.
--
-- So this file wraps encounter.roll at priority -10 -- the INNERMOST link,
-- directly around the engine's own table roll, because Hooks sorts a chain
-- descending by priority and runs it outside-in. That position is the whole
-- deference story:
--
--   * if Wilds of Kanto suppresses, its link returns before ours ever runs:
--     we cannot resurrect an encounter it vetoed;
--   * whatever we return flows onward to encounter.species exactly as a
--     vanilla pick would, so Sprite Variety's substitution sees the same
--     shape it always saw and still wins afterwards, as it should;
--   * our next() is the bare vanilla roll, so a non-nil result really is a
--     pick from THIS map's table -- and `fromTable` below re-checks that
--     against the slots anyway, so even a future re-ordering that handed us
--     somebody's forced encounter would see it pass through untouched.
--
-- ------- what a re-pick does and does not touch
--
-- next() ran the WHOLE vanilla roll: the rate gate (does anything jump out
-- on this step) and the slot pick. We only act when that roll produced an
-- encounter, and we only move it to another slot OF THE SAME TABLE, drawn
-- from the vanilla widths with the missing slots' widths multiplied
-- (Luck.wildWeights). The rate is therefore untouched at every tier, a
-- fully-caught map is untouched, NORMAL and REALISTIC are untouched, and
-- no species can appear anywhere its map does not list it -- the weights
-- array simply has no entry to express that.
--
-- When the bias is a no-op (boost 1, nothing missing, everything missing --
-- the last is the same distribution scaled), we return before drawing, so
-- those paths consume NO extra randomness and the game's roll stream is
-- byte-identical to vanilla. Only a genuinely mixed table at a boosted tier
-- draws one extra number.

local WildLuck = {}

-- Innermost on the chain: below overworld_wild_spawns' 0 and far below
-- SPRITE_VARIETY's encounter.species 10 (a different chain, listed for the
-- map of the neighbourhood).
local PRIORITY = -10

local installed = false
local loggedActive = false

function WildLuck.installed() return installed end

local function engineGame()
  local ok, Game = pcall(require, "src.core.Game")
  if ok and type(Game) == "table" then return Game end
  return nil
end

-- The engine's own dex: save.pokedex.owned, the set the dex screen draws
-- the ball glyph from. Seen-but-not-caught is missing on purpose.
--
-- This is the answer for every tier EXCEPT MISSINGNO. That tier is the
-- completion hunt and asks lib/Holdings.lua, which consults Sprite Variety's
-- per-cartridge artwork and Dramatic Shape's finish through their published
-- entry points -- see `missingTest` below for why the two differ.
local function ownedSet()
  local Game = engineGame()
  local save = Game and Game.save
  local dex = save and save.pokedex
  local owned = dex and dex.owned
  if type(owned) == "table" then return owned end
  return nil
end

-- The cumulative thresholds this map's roll used: its own table if it
-- carries one, else the merged dataset's encounterBuckets -- resolved the
-- same way Encounter.load resolves it, so the widths we scale are exactly
-- the widths the engine rolled.
local function liveBuckets(grass)
  if type(grass.buckets) == "table" then return grass.buckets end
  local ok, FieldDefaults = pcall(require, "src.world.FieldDefaults")
  if not ok or type(FieldDefaults) ~= "table" then return nil end
  local Game = engineGame()
  local okC, buckets = pcall(FieldDefaults.constant,
    Game and Game.data, "encounterBuckets")
  if okC and type(buckets) == "table" then return buckets end
  return nil
end

-- Did this encounter come from this table? True only when some slot carries
-- exactly this species AND level. Anything else was forced in by another
-- hand and is not ours to move -- the ShinyRate rule again: defer, don't
-- trample.
local function fromTable(enc, slots, buckets)
  for i = 1, #buckets do
    local s = slots[i]
    if type(s) == "table" and s.species == enc.species and s.level == enc.level then
      return true
    end
  end
  return false
end

-- ------- what "missing" means, and the one tier where it means more
--
-- Every tier but MISSINGNO asks the dex: `owned[species]`, the bit the WILD
-- row's help text describes, unchanged. MISSINGNO is the COMPLETION HUNT and
-- asks lib/Holdings.lua instead, which answers at the finest granularity the
-- install supports -- species x cartridge x finish where Sprite Variety and
-- Dramatic Shape are both up, one axis coarser for each that is not, and the
-- plain dex bit when neither is. So a species you hold as a shiny Yellow
-- Charizard is still MISSING its ten other cartridges and both of everything
-- else, and keeps the lean until the collection is genuinely finished.
--
-- The PLACEMENT RULE is untouched by any of this. Holdings only ever changes
-- WHICH of a table's own slots are called missing; the weights array still
-- has one entry per bucket of THIS map's table and no way to name a species
-- that is not in it.
--
-- Degrading is silent and safe by construction: a coarser answer marks
-- FEWER cells missing, never more, so the failure direction is the bias
-- doing less than it could.
-- Returns the test to use, and -- at the completion hunt only -- a COARSER
-- one to fall back to when the fine answer turns out to say nothing.
--
-- ------- why the fallback has to exist
--
-- "Wanted" at collection granularity means "some cartridge x finish cell of
-- this species is still empty", and a cell is a creature the player is
-- HOLDING. A finished species is therefore twenty-two creatures in the party
-- and the boxes at once -- and the boxes hold 240 (src/pokemon/Boxes.lua: 12
-- x 20), so a save can carry at most ten finished species and a normal one
-- carries none. Every species on every map is wanted, always.
--
-- `wildWeights` then reports missing == present, `rebias` reads that as "the
-- boosted distribution IS the vanilla one scaled" -- which is true -- and
-- returns. Correct arithmetic, and a tier that silently does nothing.
--
-- Measured on ROUTE_22 with a mid-game save (60,000 encounters, real chain,
-- real tables), RATTATA's share of the picks:
--
--     NORMAL 0.454    HORSESHOE x8 0.087    MISSINGNO x16 0.454
--
-- MISSINGNO is the rung ABOVE HORSESHOE and it was landing exactly on
-- vanilla while the rung below it leaned hard -- an inversion in the one
-- direction `luck_test` asserts can never happen, invisible because the
-- ladder is monotone in the TABLE and only inverts in what reaches the
-- table.
--
-- So when the fine answer degenerates, the coarse one is asked instead. It
-- costs nothing anywhere else, it cannot break the placement rule (both
-- tests only ever label slots THIS map's table already carries), and it puts
-- the ladder back: MISSINGNO is now never weaker than HORSESHOE.
local function missingTest(ctx)
  local owned = ownedSet()
  local dexTest = owned and function(species) return not owned[species] end or nil

  if ctx.Holdings and ctx.Luck.isCompletionHunt(ctx.tier()) then
    local snap = ctx.Holdings.snapshot(ctx)
    if snap then
      return function(species) return snap.wanted(species) end, dexTest
    end
  end
  return dexTest, nil
end

-- ctx = { Luck, Holdings, log, mod, enabled() -> bool, tier() -> string }
-- Returns a replacement encounter table, or nil for "leave the vanilla
-- pick exactly as it is".
local function rebias(ctx, enc, encDef, hookCtx)
  if not ctx.enabled() then return nil end
  local Luck = ctx.Luck
  local boost = Luck.wildBoost(ctx.tier())
  if boost <= 1 then return nil end

  local grass = encDef and encDef.grass
  local slots = grass and grass.slots
  if type(slots) ~= "table" then return nil end
  local buckets = liveBuckets(grass)
  if type(buckets) ~= "table" or #buckets == 0 then return nil end

  local isMissing, coarser = missingTest(ctx)
  if not isMissing then return nil end
  if not fromTable(enc, slots, buckets) then return nil end

  local weights, total, missing, present = Luck.wildWeights(
    slots, buckets, isMissing, boost)
  -- EVERYTHING missing: the boosted distribution IS the vanilla one scaled,
  -- so this table has learned nothing from the fine answer. At the completion
  -- hunt that is the NORMAL case rather than a corner (see `missingTest`), so
  -- ask the coarser question before giving up on the table. No randomness has
  -- been drawn yet -- `wildWeights` is pure -- so a second pass costs one walk
  -- of ten slots and nothing at all from the roll stream.
  if coarser and missing == present and present > 0 then
    weights, total, missing, present = Luck.wildWeights(
      slots, buckets, coarser, boost)
  end
  -- nothing missing: luck has nothing to lean toward, and that is correct.
  -- everything missing even after the fallback: genuinely a scaled vanilla.
  -- Both leave the pick -- and the roll stream -- untouched.
  if total <= 0 or missing == 0 or missing == present then return nil end

  local rng = (hookCtx and hookCtx.rng)
    or (love and love.math and love.math.random)
  if not rng then return nil end
  local i = Luck.wildPick(weights, total, rng(0, total - 1))
  local slot = i and slots[i]
  if not (type(slot) == "table" and slot.species ~= nil) then return nil end

  if not loggedActive and ctx.log then
    loggedActive = true
    ctx.log:info(
      "wild luck live: missing species weighted x%d within each map's own table",
      boost)
  end
  -- a fresh table, the same shape Encounter.roll builds; never the slot
  -- itself and never a mutation of the vanilla enc
  return { species = slot.species, level = slot.level }
end

-- ------- THE RODS, which used to be a different seam entirely
--
-- A hooked encounter never reaches `encounter.roll`. `OverworldState:
-- goFishing` (OverworldController.lua:1638-1650) builds its own pick and
-- offers it on a chain of its own:
--
--   encounter.fishing   (next, rod, mapId, pool) -> encounter or nil
--
-- so before this, neither half of the tier reached a rod: the wild lean
-- never applied, and the shiny yield was never armed. The direction was safe
-- -- the shiny force simply stood -- but it was inconsistent, and rods are a
-- legitimate route to species you may be missing. KRABBY's ONLY route in Red
-- is the Super Rod, on eighteen maps and nowhere else.
--
-- It is coverable from here without touching `src/`, so it is covered. We are
-- the only owner of that chain on this install (checked, the ShinyRate rule),
-- and the position is the same one the grass takes: innermost, around the
-- vanilla pick, acting only on a pick that already happened.
--
-- ------- what a rod's pool is, and why `Luck.wildWeights` still fits
--
-- The rejection loop the engine ports (item_effects.asm ReadSuperRodData,
-- OverworldController.lua:1603-1616) draws a byte, gives up on an odd one,
-- and takes a TWO-BIT index, rerolling until it lands inside the group. So
-- every entry has the SAME share, only the first four are reachable at all,
-- and the bite odds are size/(size+4).
--
-- Cumulative widths of one apiece are therefore the exact vanilla weights,
-- which means the grass's own `Luck.wildWeights` and `Luck.wildPick` do the
-- arithmetic here too -- the same functions, with the same exhaustive
-- placement-rule sweep already behind them. The cap at four is not decoration:
-- a fifth entry is unreachable in vanilla, and re-picking into one would be
-- this file inventing an encounter, which is the one thing it may never do.
--
-- The BITE RATE is untouched at every tier, exactly as the step rate is: we
-- only ever act on a pick `next` already made, so "nothing bit" keeps its
-- vanilla probability and the Old Rod's guaranteed MAGIKARP -- a `pool` of
-- nil and an `always` we never see -- has nothing to re-pick among.
local FISH_MAX = 4

local function rebiasFish(ctx, enc, pool)
  if not ctx.enabled() then return nil end
  local Luck = ctx.Luck
  local boost = Luck.wildBoost(ctx.tier())
  if boost <= 1 then return nil end
  if type(pool) ~= "table" then return nil end
  local n = math.min(#pool, FISH_MAX)
  -- one reachable entry is not a distribution
  if n < 2 then return nil end

  -- the same "is this pick even ours to move" test the grass makes
  local mine = false
  for i = 1, n do
    local s = pool[i]
    if type(s) == "table" and s.species == enc.species and s.level == enc.level then
      mine = true
    end
  end
  if not mine then return nil end

  local buckets = {}
  for i = 1, n do buckets[i] = i end

  local isMissing, coarser = missingTest(ctx)
  if not isMissing then return nil end

  local weights, total, missing, present =
    Luck.wildWeights(pool, buckets, isMissing, boost)
  -- the completion hunt's degeneracy, and its coarse fallback -- identical
  -- reasoning to `rebias` above, and pure, so it costs no randomness
  if coarser and missing == present and present > 0 then
    weights, total, missing, present =
      Luck.wildWeights(pool, buckets, coarser, boost)
  end
  if total <= 0 or missing == 0 or missing == present then return nil end

  -- `rollFishingGroup` draws on love.math.random and the fishing chain
  -- carries no ctx of its own, so this is the same stream the engine used.
  local rng = love and love.math and love.math.random
  if not rng then return nil end
  local i = Luck.wildPick(weights, total, rng(0, total - 1))
  local slot = i and pool[i]
  if not (type(slot) == "table" and slot.species ~= nil) then return nil end
  return { species = slot.species, level = slot.level }
end

local fishingInstalled = false

function WildLuck.fishingInstalled() return fishingInstalled end

-- ctx as `install`, plus ctx.armHooked. Idempotent; called from the
-- heartbeat until it takes.
function WildLuck.installFishing(ctx)
  if fishingInstalled then return true end
  local mod, outer = ctx.mod, ctx
  local ok = pcall(function()
    mod.hooks:wrap("encounter.fishing", function(next, rod, mapId, pool)
      local enc = next(rod, mapId, pool)
      if enc == nil then return nil end
      -- A bite. Arm the yield STICKILY: the battle this becomes is two
      -- player-paced text boxes away, so a one-frame arm would always be
      -- dead by the time the creature is built (lib/ShinyRate.lua).
      if outer.armHooked then pcall(outer.armHooked) end
      local okB, out = pcall(rebiasFish, outer, enc, pool)
      if okB and type(out) == "table" then return out end
      return enc
    end, PRIORITY)
  end)
  fishingInstalled = ok and true or false
  return fishingInstalled
end

-- ctx as above. Idempotent; called from the heartbeat until it takes.
function WildLuck.install(ctx)
  if installed then return true end
  local mod, outer = ctx.mod, ctx
  local ok = pcall(function()
    mod.hooks:wrap("encounter.roll", function(next, encDef, hookCtx)
      local enc = next(encDef, hookCtx)
      if enc == nil then return nil end
      -- A wild encounter is about to be BUILT. Tell the shiny yield so it
      -- can act on this one construction and no other (lib/ShinyRate.lua).
      -- Armed before the re-pick, because a re-pick that declines still
      -- produced a wild encounter.
      if outer.armWild then pcall(outer.armWild) end
      local okB, out = pcall(rebias, outer, enc, encDef, hookCtx)
      if okB and type(out) == "table" then return out end
      return enc
    end, PRIORITY)
  end)
  installed = ok and true or false
  return installed
end

return WildLuck
