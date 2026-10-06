-- Fortune's Favor -- a save-file LUCK STAT, tunable up or down, wired into
-- three systems: the Game Corner slot machine, the shiny rate, and a new
-- LOTTO TICKET sold at every Poke Mart.
--
-- ------- the prime rule
--
-- If it is a vanilla Gen 1 feature, do not break its core functionality.
--
-- At the default tier, NORMAL, every one of these systems behaves EXACTLY as
-- it does with this mod absent. That is not "close to vanilla": it is a code
-- path that never touches the vanilla numbers, guarded by one early-out per
-- system, and `tests/luck_test.lua` asserts that the mod's own slot-flag
-- function returns what the engine's would have returned for all 6,144
-- reachable state/roll pairs.
--
-- ------- the happy discovery this mod is built on
--
-- Vanilla ALREADY HAS a luck stat. src/ui/SlotMachine.lua is a faithful port
-- of pokered including SlotMachine_SetFlags, so the Game Corner already
-- carries exactly the dial this mod wants to turn. Scaling a dial the game
-- shipped is what makes "don't break it" achievable instead of a promise.
--
-- ------- where the state lives
--
-- The luck tier is a SAVE-FILE stat (PLAN.md): it travels with the save, not
-- with the install, so two save slots can differ. It is read from
-- `mod.save` first and falls back to `mod.options` -- which is also where it
-- is written, to BOTH homes, because the engine's mod API has
-- `mod.options:get` and `mod.options:define` but NO `mod.options:set`.
-- See `setOption` below.
--
-- ------- what this mod never does
--
-- It edits no other mod's source. Dramatic Shape is reached only through
-- `mod.find("DRAMATIC_SHAPE").exports.lib`, the engine's own inter-mod seam,
-- and every call through it is wrapped. update-extras.sh re-installs those
-- mods from GitHub and would discard any edit at the next update.

local mod = ...

local MOD_ID = "FORTUNES_FAVOR"

-- ------- loading our own libs
--
-- `mod:read` + `load` rather than `require`, because the mod folder is not
-- on the Lua path and `require` inside a mod is the engine's namespace, not
-- ours. Each lib is a plain module returning a table.
local function lib(name)
  local ok, src = pcall(function() return mod:read("lib/" .. name .. ".lua") end)
  if not (ok and src) then
    mod.log:error("lib/%s.lua is missing", name)
    return nil
  end
  local chunk, err = load(src, "@mods/" .. MOD_ID .. "/lib/" .. name .. ".lua")
  if not chunk then
    mod.log:error("lib/%s.lua did not compile: %s", name, tostring(err))
    return nil
  end
  local built, module = pcall(chunk)
  if not (built and type(module) == "table") then
    mod.log:error("lib/%s.lua did not return a module: %s", name, tostring(module))
    return nil
  end
  return module
end

local Luck = lib("Luck")
if not Luck then
  error(MOD_ID .. ": lib/Luck.lua is the whole mod and it did not load")
end

-- ------- the settings rows
--
-- Labels are EIGHT characters, uppercase letters and spaces only. Font.encode
-- silently substitutes a space for `# $ % & * + < = > @ \ ^ _ ` { | } ~`, so
-- a label carrying punctuation loses characters with no error at all.

local ROWS = {
  {
    key = "tier", label = "LUCK", type = "choice",
    values = Luck.TIERS, default = Luck.DEFAULT_TIER,
    help = "How lucky you are. Lives in the SAVE, so two save files can "
        .. "differ.\n\n"
        .. "NORMAL is the default and is vanilla exactly -- the slot machine, "
        .. "the shiny rate and the lottery all behave as if this mod were not "
        .. "installed.\n\n"
        .. "REALISTIC is the only rung BELOW vanilla, on purpose. Real slot "
        .. "machines and real scratch cards lose you money; that is the joke, "
        .. "and it is what makes tuning DOWN mean something. It wins about 1 "
        .. "ticket in 4.4 and returns about half of what it costs.\n\n"
        .. "Above NORMAL: LUCKY SOCKS, RABBITS FOOT and HORSESHOE each pay "
        .. "out more often AND bigger, at every prize, on both the slots and "
        .. "the lottery. In the wild, Pokemon still missing from your "
        .. "POKEDEX also turn up more often -- always from the area's own "
        .. "list, never from outside it. See the WILD row.\n\n"
        .. "The top two rungs are both spoiled rotten on the slots and the "
        .. "lottery -- every spin winnable in seven-and-bar mode, every "
        .. "ticket the jackpot -- and differ only in what they do to the "
        .. "wilds.\n\n"
        .. "MISSINGNO is short for MISSINGNO. SMILES ON YOU, and it is the "
        .. "COMPLETION HUNT. Shiny FIRST: while any cartridge shiny of a "
        .. "species is still missing from your collection, its wild "
        .. "encounters come up shiny. Once you hold every one of them, that "
        .. "species starts coming up NORMAL again so you can fill the other "
        .. "half. It counts artwork and finish, not just the POKEDEX, so a "
        .. "species you hold as one shiny cartridge is still wanted.\n\n"
        .. "STARDUST is A TRAIL OF STARDUST, and it is pure shiny: every "
        .. "encounter shiny, always, with no stepping aside. Pick this one "
        .. "if shinies are the whole point and you do not want normals back.",
  },
  {
    key = "prize", label = "PRIZE", type = "choice",
    values = Luck.PRIZE_MODES, default = Luck.DEFAULT_PRIZE_MODE,
    help = "What a winning LOTTO TICKET pays.\n\n"
        .. "MONEY pays cash, floored at 0 and capped at 999,999.\n\n"
        .. "CANDY pays RARE CANDY instead. It is the SAME draw with the SAME "
        .. "odds -- only the prize changes. Winnings are banked as credit at "
        .. "the RARE CANDY's own shop price of 4,800, and turn into candy the "
        .. "moment the credit passes it.\n\n"
        .. "That means CANDY is worth exactly what MONEY is worth, at every "
        .. "tier. At NORMAL that is one candy per 48 tickets -- which is what "
        .. "4,800 a candy and 100 a ticket has to mean. At HORSESHOE it is "
        .. "one per 10.\n\n"
        .. "If the bag is full, or the stack would pass 99, the candy STAYS "
        .. "BANKED and is paid out next time. Nothing is lost.",
  },
  {
    key = "tickets", label = "TICKETS", type = "toggle", default = true,
    help = "Sell the LOTTO TICKET at every Poke Mart, for 100.\n\n"
        .. "Cheaper than anything else on the counter (a POKE BALL is 200, a "
        .. "POTION 300), so it reads as spare change rather than a decision.\n\n"
        .. "At NORMAL a ticket is worth exactly what it costs. Buy a hundred "
        .. "and you are where you started, minus the variance. That is what "
        .. "keeps the default tier honest: a lottery with an edge either way "
        .. "would quietly change a playthrough's economy.\n\n"
        .. "Switch this off and the ticket vanishes from every counter. "
        .. "Tickets already in the bag still work.",
  },
  {
    key = "slots", label = "SLOTS", type = "toggle", default = true,
    help = "Let luck reach the Game Corner slot machine.\n\n"
        .. "Vanilla Gen 1 already has a hidden luck stat in there: one "
        .. "machine per visit is lucky, each spin rolls for whether a match "
        .. "is allowed at all, and a rare roll arms 60 guaranteed-winnable "
        .. "spins. This scales those numbers.\n\n"
        .. "It changes WHICH OUTCOMES ARE PERMITTED and nothing else. The "
        .. "reels, the bet menu, the payout drip, the ONE MORE GO prompt and "
        .. "the 9,999 coin cap are untouched.\n\n"
        .. "At NORMAL this row does nothing whichever way it is set.",
  },
  {
    key = "shiny", label = "SHINY", type = "toggle", default = true,
    -- Hidden entirely when Dramatic Shape is not reachable. Shiny is not a
    -- vanilla Gen 1 feature and this mod must never imply it is.
    help = "Let luck reach the shiny rate.\n\n"
        .. "Shiny is not a Gen 1 feature -- it comes from Dramatic Shape, "
        .. "which derives it from DVs. This row only exists while that mod "
        .. "is present and running.\n\n"
        .. "This mod owns the RATE. Whether shiny is shown at all belongs to "
        .. "Dramatic Mini Modifications, and OFF beats any rate.\n\n"
        .. "Rates: REALISTIC 1:8192 (the standard Pokemon odds), LUCKY SOCKS "
        .. "1:2048, RABBITS FOOT 1:512, HORSESHOE 1:128, and 1:1 at both "
        .. "MISSINGNO and STARDUST.\n\n"
        .. "At MISSINGNO that 1:1 YIELDS: once you hold every cartridge shiny "
        .. "of a species, its wilds come up normal so you can finish the "
        .. "other half of the collection. That counts what is in your PC and "
        .. "in EXTENDED STORAGE as well as what you are carrying, so putting "
        .. "a finished species away does not restart the hunt for it. Hooked "
        .. "Pokemon yield too. STARDUST never yields. Switch this row off and "
        .. "neither does anything.\n\n"
        .. "At NORMAL this mod pins nothing, so Dramatic Shape's own SHINY "
        .. "ODDS row keeps working. At any other tier this mod takes that "
        .. "row over until you come back to NORMAL.",
  },
  {
    key = "wild", label = "WILD", type = "toggle", default = true,
    help = "Let luck reach the wild grass, the caves, the water and the "
        .. "FISHING RODS.\n\n"
        .. "Above NORMAL, wild Pokemon you have not caught yet turn up more "
        .. "often. Every area keeps its own local list, and luck only leans "
        .. "WITHIN that list: the ones on it that are missing from your "
        .. "POKEDEX get a heavier share of the picks, nothing from outside "
        .. "the area is ever invited in, and how often something jumps out "
        .. "at all is untouched.\n\n"
        .. "Caught means caught. A Pokemon you have only seen still counts "
        .. "as missing, and each one you catch takes itself off the lean.\n\n"
        .. "The RODS lean the same way, within each rod's own catch list. "
        .. "How often something bites is untouched, and the OLD ROD still "
        .. "hooks a MAGIKARP every time -- it has nothing else to offer. The "
        .. "SUPER ROD is where this matters: KRABBY has no other route in "
        .. "RED.\n\n"
        .. "The lean per tier: LUCKY SOCKS doubles every missing local's "
        .. "share of the table, RABBITS FOOT weighs it 4 times, HORSESHOE 8, "
        .. "MISSINGNO 16. Even at MISSINGNO a rare local is only easier to "
        .. "find, never certain, and an area you have fully caught behaves "
        .. "exactly as vanilla.\n\n"
        .. "At MISSINGNO the lean counts your COLLECTION rather than your "
        .. "POKEDEX: a species is wanted until you hold every cartridge and "
        .. "both finishes of it. Every other tier counts the POKEDEX, as "
        .. "before.\n\n"
        .. "Because that wants nearly everything nearly always, an area where "
        .. "it wants EVERY local falls back to the POKEDEX for that area. So "
        .. "MISSINGNO is never a weaker lean than HORSESHOE -- it is the same "
        .. "lean at 16 instead of 8, and sharper wherever your collection can "
        .. "tell two locals apart.\n\n"
        .. "At NORMAL and REALISTIC this row does nothing whichever way it "
        .. "is set.",
  },
  {
    key = "mastershop", label = "MB SHOP", type = "toggle", default = true,
    help = "Stock one MASTER BALL offer at the bottom of ordinary POKE MART "
        .. "buy lists, including CELADON department-store clerks. It is ON "
        .. "by default while Fortune's Favor is enabled; OFF keeps existing "
        .. "stock unchanged. Specialty vendors are not changed.\n\n"
        .. "The Yellow price is 4,900: half the highest sold ordinary-mart "
        .. "item price, 9,800 for vitamins on CELADON 5F. Unsold internal "
        .. "prices are not used. Other items and resale prices stay unchanged. "
        .. "The normal money, quantity and bag checks still apply.\n\n"
        .. "Changes apply when opening a new shop. An already-open offer "
        .. "keeps its displayed price until that shop closes.",
  },
  {
    key = "capture", label = "CAPTURE", type = "choice",
    values = { "VANILLA", "Y LEGACY" }, default = "Y LEGACY",
    help = "Y LEGACY uses Yellow Legacy version 1.0.10 catching behavior "
        .. "for Gen 1 battles. It is the default while Fortune's Favor is on. "
        .. "Choose VANILLA to keep the usual catching rules.\n\n"
        .. "The shipped Legacy game boosts POKE, GREAT, ULTRA and SAFARI "
        .. "BALLS. All four ignore the target's remaining HP when deciding "
        .. "a successful catch. This also affects POKE and GREAT BALLS, "
        .. "not just ULTRA and SAFARI. MASTER BALL stays guaranteed.\n\n"
        .. "In the Safari Zone, eating Pokemon are less likely to flee. "
        .. "Rocks still make them angry, but increase fleeing less than "
        .. "usual. Bait still halves the catch rate; rocks still double it. "
        .. "Their duration and reset rules stay the same.\n\n"
        .. "Species catch rates, status bonuses and your LUCK and SHINY "
        .. "choices stay the same. This follows the released game, including "
        .. "its all-ball HP quirk. It does not change Gen 2 battles.",
  },
}

mod.options:define(ROWS)

local function schemaRow(key)
  for _, row in ipairs(ROWS) do if row.key == key then return row end end
  return nil
end

-- ------- reading a setting
--
-- The tier is a SAVE stat (PLAN.md) but the engine's settings plumbing is
-- install-wide, so both are consulted, save first:
--
--   mod.save   -> loader.modSave, which Game:adoptSave points AT
--                 save.modData, so this really is per-save-slot state
--   mod.options-> loader.modOptions, the install-wide options file, which
--                 is what a fresh save inherits and what the title screen
--                 sees before any save is loaded
--
-- Every read is pcall'd and every unrecognised value falls back to the
-- schema default: this is data another version of the mod may have written,
-- and a settings row is not worth a crash.
local function rawGet(key)
  local ok, v = pcall(function() return mod.save:get(key) end)
  if ok and v ~= nil then return v end
  local ok2, v2 = pcall(function() return mod.options:get(key) end)
  if ok2 and v2 ~= nil then return v2 end
  local row = schemaRow(key)
  return row and row.default
end

local function value(key, default)
  local v = rawGet(key)
  if type(v) == "string" and v ~= "" then return v end
  local row = schemaRow(key)
  return (row and row.default) or default
end

local function toggle(key)
  local v = rawGet(key)
  if v == nil then
    local row = schemaRow(key)
    return not row or row.default ~= false
  end
  return v ~= false
end

-- Only the new preference is read; no migration rewrites existing saves or
-- options. An absent key inherits the requested Y LEGACY default.
do
  local capture = lib("LegacyCapture")
  if capture then
    capture.install(mod, function() return value("capture") == "Y LEGACY" end)
  end
end

-- Missing preference defaults ON, without writing saves or enabling a disabled
-- mod. Buy-only quotes require the engine seam; missing support fails closed.
do
  local shop = lib("MasterShop")
  if shop then
    local ok, installed, why = pcall(shop.install, mod,
      function() return toggle("mastershop") end)
    if not ok or installed == nil then
      mod.log:warn("Master Ball shop unavailable: %s", tostring(ok and why or installed))
    end
  end
end

-- ------- writing a setting
--
-- There is NO `mod.options:set` on the public mod API (Loader.lua:683-701
-- defines `define` and `get` and nothing else). A setting therefore has to
-- be written to BOTH of its homes by hand:
--
--   game.save.options.modOptions[MOD_ID][key]  what persists to disk
--   game.mods.modOptions[MOD_ID][key]          what mod.options:get reads
--                                              back THIS frame
--
-- Writing one and not the other gives a row that either forgets on restart
-- or does not take effect until one. (Shape borrowed from DRAMATIC_MINI's
-- setWant, itself borrowed from DECK_TILT's Setting.lua.)
--
-- `mod.save:set` is the third write and the authoritative one: it lands in
-- save.modData, which is what makes the tier travel with the save.
local function setOption(game, key, v)
  pcall(function() mod.save:set(key, v) end)
  local opts = game and game.save and game.save.options
  if opts then
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[MOD_ID] = opts.modOptions[MOD_ID] or {}
    opts.modOptions[MOD_ID][key] = v
  end
  local loader = game and game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[MOD_ID] = loader.modOptions[MOD_ID] or {}
    loader.modOptions[MOD_ID][key] = v
  end
end

-- ------- the candy bank
--
-- Save-file state, not an option: it is progress, not a preference.
local function getBank()
  local ok, v = pcall(function() return mod.save:get("candyBank", 0) end)
  if ok and type(v) == "number" then return v end
  return 0
end

local function setBank(v)
  pcall(function() mod.save:set("candyBank", math.max(0, math.floor(v or 0))) end)
end

-- A save written before this mod existed has no bank. `since` is the version
-- the migration upgrades FROM; the loader runs it against save.meta.
mod.migrations:add("0.0.0", function(modSave)
  if type(modSave) ~= "table" then return end
  if modSave.candyBank == nil then modSave.candyBank = 0 end
  if modSave.tier == nil then modSave.tier = Luck.DEFAULT_TIER end
  if modSave.prize == nil then modSave.prize = Luck.DEFAULT_PRIZE_MODE end
end)

-- ------- the ticket item
--
-- Registered in the entry chunk, because the content registries freeze at
-- the merge boundary. No `index`: the byte indices are a ROM table and every
-- one is spoken for. The only thing that reads `def.index` is the .sav
-- exporter (GenSave.lua:402), which simply skips an item without one -- so a
-- LOTTO TICKET does not try to cross onto a real cartridge, which is
-- correct, because it is not a real item.
--
-- No `effect` either: `items.effect` points at the `item_effects` registry
-- and NOTHING IN THE ENGINE READS EITHER OF THEM (verified by search).
-- lib/Lottery.lua wraps ItemEffects.use instead, which is the function the
-- bag actually calls. Naming a dangling effect id here would only earn a
-- cross-validation error.
mod.content.items:register(Luck.TICKET_ID, {
  id = Luck.TICKET_ID,
  name = Luck.TICKET_NAME,
  price = Luck.TICKET_PRICE,
  tossable = true,
})

-- ------- shared context for the three systems

local Lottery = lib("Lottery")
-- Optional: with no art in assets/tickets/ this loads, finds nothing, and
-- every entry point becomes a no-op. The mod is unchanged without it.
local TicketArt = lib("TicketArt")
local Slots = lib("Slots")
local ShinyRate = lib("ShinyRate")
local WildLuck = lib("WildLuck")
-- Optional, like TicketArt: without it the completion hunt falls back to the
-- plain dex bit and nothing else changes.
local Holdings = lib("Holdings")

local rng = (love and love.math and love.math.random) or math.random

local ctx = {
  Luck = Luck,
  log = mod.log,
  mod = mod,
  -- Cosmetic only; Lottery.install calls begin() through this if present.
  ticketArt = TicketArt,
  tier = function() return value("tier", Luck.DEFAULT_TIER) end,
  prizeMode = function() return value("prize", Luck.DEFAULT_PRIZE_MODE) end,
  enabled = function() return toggle("slots") end,
  getBank = getBank,
  setBank = setBank,
  -- lib/Luck.lua's draw() wants [0,1); the slot flag roll wants an integer
  -- 0..255, the way the asm rolls it. love.math.random answers both shapes.
  random = function(a, b)
    if a == nil then return rng() end
    return rng(a, b)
  end,
}

local shinyCtx = {
  Luck = Luck, log = mod.log, mod = mod,
  tier = ctx.tier,
  enabled = function() return toggle("shiny") end,
}

-- Wild encounters read the tier and the WILD toggle live, per roll, so
-- there is nothing to re-apply when either changes.
local wildCtx = {
  Luck = Luck, log = mod.log, mod = mod,
  Holdings = Holdings,
  tier = ctx.tier,
  enabled = function() return toggle("wild") end,
  -- MISSINGNO's shiny yield is armed here, on the wild seam, so it can never
  -- be spent on a starter, a gift or a trade. ShinyRate owns the flag; this
  -- is only the wire between the two.
  armWild = function()
    if ShinyRate and toggle("shiny") then ShinyRate.armWild() end
  end,
  -- A rod's bite is separated from the battle it becomes by two player-paced
  -- text boxes, so its arm has to survive frames. STICKY, and bounded by the
  -- wild-battle scope rather than by the heartbeat -- see lib/ShinyRate.lua.
  armHooked = function()
    if ShinyRate and toggle("shiny") then ShinyRate.armWild(true) end
  end,
}

-- The yield reads the SHINY row (it is a shiny-rate behaviour) and the tier.
local yieldCtx = {
  Luck = Luck, log = mod.log, mod = mod,
  Holdings = Holdings,
  tier = ctx.tier,
  enabled = function() return toggle("shiny") end,
}

-- The SHINY row is not offered at all when Dramatic Shape is not reachable.
-- Resolved fresh on every menu build, never cached as absent: load order is
-- not ours to choose.
schemaRow("shiny").visible = function()
  return ShinyRate ~= nil and ShinyRate.available(mod)
end

-- ------- stocking the marts
--
-- On `mods.loaded`, which the loader emits with the merged `data` once every
-- entry chunk has run and every registry has folded home. Held onto so the
-- TICKETS row can add and remove the ticket inside a session.
local liveData = nil

local function syncMarts()
  if not (Lottery and liveData) then return end
  if toggle("tickets") then
    local n = Lottery.stockMarts(liveData, Luck.TICKET_ID)
    if n > 0 then mod.log:info("LOTTO TICKET stocked in %d marts", n) end
  else
    local n = Lottery.unstockMarts(liveData, Luck.TICKET_ID)
    if n > 0 then mod.log:info("LOTTO TICKET withdrawn from %d marts", n) end
  end
end

mod.events:on("mods.loaded", function(payload)
  liveData = payload and payload.data
  syncMarts()
end)

-- ------- the heartbeat
--
-- This install runs a git checkout that reports 0.0.0-dev, and that build
-- emits no "game.update" anywhere -- the bus is real, the name is simply
-- never fired. So the retries hang off `render.hud`, which Game:draw calls
-- once per frame for as long as anyone wraps it. The wrap is a pure
-- pass-through; it adds no drawing and changes no argument.
--
-- Everything below is idempotent and cheap once it has taken: two booleans
-- and, for the shiny rate, one comparison against what was last applied.
local installsDone = false

-- The body of the beat, named so it can also be run ONCE BEFORE THE FIRST
-- FRAME.  Everything in it is startup work -- installing the lottery, the
-- slots, the wild-luck seam and the rods, and reading the ticket art -- and
-- the beat it hangs off is a DRAWN FRAME, so all of it used to land on draw
-- 1: the frame the copyright logo arrives on.  MEASURED 2026-09-04
-- (tests/drivers/p0_firstframe_attr.lua): this mod's link was ~13.6ms of an
-- instrumented draw 1, of which the two ticket images alone were 11.68ms.
--
-- The beat is unchanged and still runs every frame: `installsDone` and each
-- installer's own sentinel make a second call free, so `game.ready` is a head
-- start, not a replacement -- an install that needs a mod which came up after
-- us is still retried from the frame exactly as before.
local function heartbeat()
  if not installsDone then
    local lotteryOk = (not Lottery) or Lottery.installed() or Lottery.install(ctx)
    local slotsOk = (not Slots) or Slots.installed() or Slots.install(ctx)
    local wildOk = (not WildLuck) or WildLuck.installed() or WildLuck.install(wildCtx)
    -- The rods live on their OWN chain (`encounter.fishing`) and never reach
    -- the one above, so they are a second install rather than a second link.
    local fishOk = (not WildLuck) or WildLuck.fishingInstalled()
      or WildLuck.installFishing(wildCtx)
    -- Ticket art is cosmetic and OPTIONAL: it is never part of the readiness
    -- test above, so a missing ListMenu or an empty assets/tickets/ folder
    -- can never hold back the lottery or the slots.
    if TicketArt and not TicketArt.installed() then
      pcall(function()
        local okLM, ListMenu = pcall(require, "src.ui.ListMenu")
        if okLM and type(ListMenu) == "table" then
          TicketArt.install(ListMenu, mod, mod.log)
        end
      end)
    end
    if lotteryOk and slotsOk and wildOk and fishOk then
      installsDone = true
      mod.log:info("systems installed (lottery %s, slots %s, wild %s, rods %s)",
        Lottery and "yes" or "no", Slots and "yes" or "no",
        WildLuck and "yes" or "no",
        (WildLuck and WildLuck.fishingInstalled()) and "yes" or "no")
    end
  end
  -- The shiny rate is re-applied rather than installed: Dramatic Shape may
  -- come up after us, the player may change tier, and another mod may take
  -- the pin. A no-op unless the wanted denominator differs from the applied.
  if ShinyRate then pcall(ShinyRate.apply, shinyCtx) end
  -- The MISSINGNO yield wraps Pokemon.new and must land OUTSIDE Dramatic
  -- Shape's wrap, so it is retried from here until that mod has taken it.
  -- Its own sentinel makes a second call free.
  if ShinyRate and Holdings then pcall(ShinyRate.installYield, yieldCtx) end
  -- And the scope that says WHICH constructions the yield may be spent on.
  -- Ahead of the disarm below because it is what makes a sticky arm legal:
  -- a rod's bite is armed frames before its battle exists.
  if ShinyRate then pcall(ShinyRate.installWildScope, yieldCtx) end
  -- An armed yield that no construction consumed dies here rather than
  -- waiting for the next Pokemon.new, which could be a gift. One frame is
  -- longer than the gap between the roll and the battle it starts.
  if ShinyRate then pcall(ShinyRate.disarm) end
end

mod.hooks:wrap("render.hud", function(next, ...)
  heartbeat()
  return next(...)
end)

-- `game.ready` is the last thing Game:load emits before it pushes the splash
-- (src/core/Game.lua:110 vs :121-131), so this runs while the window is still
-- black and love.draw has never been called.
mod.events:on("game.ready", function() pcall(heartbeat) end)

-- ------- the menu

local SCREEN = "FortunesFavorMenu"

-- If our page cannot be built, this is what the player gets instead. It
-- exists because Screens.push's degrade path for a failed MOD screen is
-- `builtinFor(id)`, i.e. `require("src.ui.FortunesFavorMenu")` -- a module
-- that does not and will not exist, so the "safe" fallback would itself
-- throw. Returning something rather than nil keeps that path unreachable.
local function stubScreen(game)
  return {
    isOpaque = true,
    update = function(self)
      local input = game.input
      if input:wasPressed("b") or input:wasPressed("a")
          or input:wasPressed("start") then
        game.stack:pop()
      end
    end,
    draw = function()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, 160, 144)
      love.graphics.setColor(0, 0, 0, 1)
      local Font = require("src.render.Font")
      Font.draw("FORTUNE'S FAVOR", 8, 8)
      Font.draw("SETTINGS PAGE", 8, 32)
      Font.draw("FAILED TO LOAD", 8, 40)
      Font.draw("B: BACK", 8, 136)
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

mod.content.screens:register(SCREEN, {
  new = function(game)
    local SettingsMenu = lib("SettingsMenu")
    if not (SettingsMenu and SettingsMenu.new) then return stubScreen(game) end
    local built, page = pcall(SettingsMenu.new, game, {
      rows = ROWS,
      value = value,
      toggle = toggle,
      setValue = setOption,
      setToggle = setOption,
      -- Every step guarded: a help page is a convenience, and a fault in one
      -- must cost the page, never the settings screen the player is standing
      -- on.
      help = function(g, title, body)
        local HelpScreen = lib("HelpScreen")
        if not (HelpScreen and HelpScreen.new) then return end
        local ok, page = pcall(HelpScreen.new, g, title, body)
        if ok and page then pcall(function() g.stack:push(page) end) end
      end,
      changed = function(key)
        if key == "tickets" then syncMarts() end
        if ShinyRate then pcall(ShinyRate.apply, shinyCtx) end
      end,
    })
    if not (built and type(page) == "table") then
      mod.log:error("settings page failed to build: %s", tostring(page))
      return stubScreen(game)
    end
    return page
  end,
})

-- The row's own value line: the tier, which is the one thing worth seeing
-- without opening the page. 16 columns, so the longest tier name fits.
local function summary()
  local tier = Luck.tierOf(value("tier", Luck.DEFAULT_TIER))
  if tier == "NORMAL" then return "NORMAL" end
  return tier
end

mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  -- ONE row, which OPENS THIS MOD'S OWN PAGE, at position 1. OPTIONS shows
  -- four rows at a time and this install has well over thirty; DECK_TILT's
  -- notes record its row landing at "row 38 of 38" and being reported as
  -- missing when it was merely unreachable.
  table.insert(out, 1, {
    id = MOD_ID .. ":root",
    -- The full name fits: OptionRows.draw:40 puts the LABEL line at x=16,
    -- which is tile 2, and tile 19 is the box border -- 17 columns, and
    -- "FORTUNE'S FAVOR" is 15. (The VALUE line starts a tile further in at
    -- x=24, so it only has 16, which is why the tier name is abbreviated.)
    -- The apostrophe is a real glyph, not a Font.encode casualty: the game's
    -- own text carries 771 of them, TRAINER'S among them.
    label = "FORTUNE'S FAVOR",
    value = summary,
    activate = function(g) mod.ui.push(g, SCREEN) end,
  })
  return out
end)

-- ------- 0.2.36 moved the front door again: keep it at the front of the
-- VIEW, not just the flat list
--
-- `groupRows()` (src/ui/OptionsMenu.lua) runs AFTER the hook above and
-- rebuilds the screen the player actually sees: it emits nine fixed engine
-- entries first (its `ORDER` table -- the four group openers, PERFORMANCE,
-- RULESET, MODS...) and only THEN appends whatever `ORDER` does not name, in
-- the FLAT LIST's order. Position 1 in `out` above used to mean position 1
-- on screen; from 0.2.36 on it means row 12 of 49, measured on this install
-- in `review/w12-rows-2026-08-29/rows.tsv` -- the same "row nobody can find"
-- failure DECK_TILT documents for its own row above, reopened by an engine
-- change neither mod controls.
--
-- The hook cannot fix this: it only ever sees the flat list, never the
-- rebuilt view. So this wraps the SCREEN CONSTRUCTOR instead, and moves the
-- row actually drawn.
--
-- Group sub-pages are untouched: `OptionsMenu.new(g, { rows = members })`
-- (the way a GROUP OPTIONS row opens its own page) sets `self.sub = true`
-- and returns before `groupRows` ever runs, so this skips anything with
-- `self.sub` set.
--
-- Fails open: a row not found (a build that dropped or renamed it) leaves
-- `self` unmodified -- never a crash, never a vanished row. A future engine
-- that drops `groupRows` turns this into a no-op reorder (index 1 to index
-- 1) every time OPTIONS opens.
do
  local ok, OptionsMenu = pcall(require, "src.ui.OptionsMenu")
  if ok and type(OptionsMenu) == "table" and type(OptionsMenu.new) == "function" then
    local ctor = OptionsMenu.new
    OptionsMenu.new = function(game, opts)
      local self = ctor(game, opts)
      if self and not self.sub and type(self.view) == "table" then
        for i, row in ipairs(self.view) do
          if row.id == MOD_ID .. ":root" then
            if i > 1 then
              table.remove(self.view, i)
              table.insert(self.view, 1, row)
            end
            break
          end
        end
      end
      return self
    end
  end
end

-- The manager's own auto-UI writes through mod.options and emits this; the
-- page above writes and persists on its own. Either way the systems that
-- cache anything are told.
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  if payload.key == "tickets" then syncMarts() end
  if ShinyRate then pcall(ShinyRate.apply, shinyCtx) end
end)

-- Published so another mod can read the tier without guessing at our save
-- keys, and so a future pooled-lottery build has somewhere to attach.
mod.exports.luck = {
  version = 1,
  tier = ctx.tier,
  prizeMode = ctx.prizeMode,
  tiers = Luck.TIERS,
  jackpot = function() return Luck.jackpotValue() end,
  expectedTicketValue = function() return Luck.expectedValue(ctx.tier()) end,
  -- the weight a missing species' table slots carry at the current tier;
  -- 1 means the wilds are untouched
  wildBoost = function()
    if not toggle("wild") then return 1 end
    return Luck.wildBoost(ctx.tier())
  end,
}
