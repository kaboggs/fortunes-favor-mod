-- Fortune's Favor -- the whole of the mod's ARITHMETIC, and nothing else.
--
-- This file is PURE LUA. It requires nothing, touches no global, and knows
-- about neither LOVE nor the engine. That is deliberate and it is the whole
-- point of the split: every claim this mod makes about odds, expected value
-- and clamping is decided here, so every claim can be checked by
-- `luajit tests/luck_test.lua` with no game running.
--
-- The engine-facing files (Lottery.lua, Slots.lua, ShinyRate.lua) contain no
-- arithmetic worth arguing about; they call in here for it.
--
-- ------- the prime rule
--
-- At tier NORMAL this mod must not change the game. That is enforced twice:
--
--   * `Luck.isVanilla(tier)` is the single early-out every caller asks
--     first, and the engine-facing wrappers return the untouched vanilla
--     value when it answers true;
--   * the NORMAL rows of the tables below are a literal transcription of
--     the vanilla numbers, so even if a caller forgets the early-out the
--     answer is still the vanilla one. `luck_test.lua` asserts that.
--
-- ------- REALISTIC sits BELOW NORMAL
--
-- The ladder is NOT monotonic, on purpose (PLAN.md, decision 4). REALISTIC
-- is real-world gambling: a losing proposition. It is the only rung below
-- vanilla and every table below is ordered so that it reads that way.

local Luck = {}

Luck.MOD_ID = "FORTUNES_FAVOR"

-- ------- tiers
--
-- These strings are BOTH the stored value and the label drawn on the
-- settings row, so they are uppercase letters and spaces only: Font.encode
-- silently substitutes a space for `# $ % & * + < = > @ \ ^ _ ` { | } ~`
-- and would eat an apostrophe's neighbours without an error. "RABBIT'S
-- FOOT" therefore ships as RABBITS FOOT.
--
-- OptionRows draws a row's value at x = 24 on a 160px screen, which is 16
-- characters. "MISSINGNO. SMILES ON YOU" (the name PLAN.md picked) is 24,
-- so the row says MISSINGNO and the full name lives on its help page.
Luck.TIERS = {
  "REALISTIC",     -- below vanilla, deliberately
  "NORMAL",        -- vanilla, untouched. The default.
  "LUCKY SOCKS",
  "RABBITS FOOT",
  "HORSESHOE",
  "MISSINGNO",     -- "MISSINGNO. SMILES ON YOU" -- the COMPLETION HUNT
  "STARDUST",      -- "A TRAIL OF STARDUST" -- pure shiny, nothing else
}
Luck.DEFAULT_TIER = "NORMAL"

-- ------- the two top rungs, and why there are two
--
-- They used to be one. MISSINGNO pinned the shiny rate to 1:1 AND weighted
-- the wilds x16, and those two jobs fight each other: with every encounter
-- shiny by definition you can never catch a NORMAL, so the half of a living
-- dex that is not shiny is unreachable at the very tier that is supposed to
-- be the most generous. Splitting them is what makes both jobs possible:
--
--   MISSINGNO   the COMPLETION HUNT. Shiny FIRST -- while any cartridge's
--               shiny of a species is unheld the roll is forced shiny -- and
--               then it YIELDS: once every one of that species' shinies is
--               held, its encounters come up normal so the gaps can fill.
--               The wild weighting is finish-aware to match (see
--               lib/Holdings.lua): a species you hold only as a shiny Yellow
--               Charizard is still MISSING its ten other cartridges and its
--               normals, and still gets the lean.
--   STARDUST    PURE SHINY, and exactly what MISSINGNO used to be: 1:1, no
--               yield, species-level. "I only want shinies" is a real want
--               and splitting the tiers is what keeps it available.
--
-- STARDUST matches MISSINGNO on every OTHER system (slots, lottery, wild
-- boost) rather than inventing a rung above a maximum: MISSINGNO already
-- forces the slot machine open and makes every ticket the jackpot, and
-- there is nothing above "always". The ladder therefore stays monotone
-- non-decreasing everywhere, which is what `luck_test` asserts.
--
-- STARDUST is a Gen 1 item (it sells for 1000 at the Celadon department
-- store's fourth floor), it is eight characters, and every character is on
-- the Gen 1 font's safe list -- Font.encode silently eats
-- `# $ % & * + < = > @ \ ^ _ { | } ~`, so a tier name carrying one of those
-- would lose characters on the settings row with no error at all.

-- Does this tier hunt a COLLECTION rather than a species list? Only
-- MISSINGNO does. Every other tier -- STARDUST included -- keeps the
-- species-level meaning of "missing" that the WILD row's help text
-- describes, so nothing below the top of the ladder changes behaviour.
function Luck.isCompletionHunt(tier)
  return Luck.tierOf(tier) == "MISSINGNO"
end

function Luck.isTier(tier)
  for _, t in ipairs(Luck.TIERS) do if t == tier then return true end end
  return false
end

-- Every unknown value collapses to the default rather than throwing: this
-- is read from a save file that another version of the mod may have
-- written, and a settings row is not worth a crash.
function Luck.tierOf(value)
  if Luck.isTier(value) then return value end
  return Luck.DEFAULT_TIER
end

function Luck.isVanilla(tier) return Luck.tierOf(tier) == "NORMAL" end

function Luck.tierIndex(tier)
  tier = Luck.tierOf(tier)
  for i, t in ipairs(Luck.TIERS) do if t == tier then return i end end
  return 2
end

-- ------- money, the two hard limits
--
-- Gen 1 stores money as 3-byte BCD. Underflow is a corrupt save, not a
-- funny outcome, and the cap is what GenSave.lua:858 already truncates to
-- on write -- so a payout above it is not "extra money", it is money that
-- silently disappears the next time the player saves.
Luck.MONEY_FLOOR = 0
Luck.MONEY_CAP = 999999

function Luck.clampMoney(v)
  v = math.floor(tonumber(v) or 0)
  if v < Luck.MONEY_FLOOR then return Luck.MONEY_FLOOR end
  if v > Luck.MONEY_CAP then return Luck.MONEY_CAP end
  return v
end

-- Returns the new balance AND what actually moved, because the caller has
-- to tell the player the truth: winning 200,000 with 900,000 in the bag
-- pays 99,999, and saying otherwise is a lie the save file will contradict.
function Luck.applyMoney(current, delta)
  local before = Luck.clampMoney(current)
  local after = Luck.clampMoney(before + math.floor(tonumber(delta) or 0))
  return after, after - before
end

-- ------- the ticket
Luck.TICKET_ID = "FF_LOTTO_TICKET"
Luck.TICKET_NAME = "LOTTO TICKET"
Luck.TICKET_PRICE = 100

-- ------- the jackpot
--
-- PLAN.md calibrates max luck to "the max money needed to buy the most
-- expensive Pokemon at the casino store outright" and wants it computed
-- from the live prize table rather than hardcoded.
--
-- DEVIATION, recorded on purpose: the prize windows are FILE-LOCAL tables
-- in data/scripts/story3.lua (RED_PRIZE_WINDOWS and friends, lines 709-749).
-- They are not published on `game.data` and there is no accessor, so a mod
-- cannot read them without editing engine source -- which this mod does not
-- do. What IS reachable is the coin economy the prizes are priced in, and
-- it is the same economy on all three versions:
--
--     coin case caps at 9,999 (story3.lua's math.min(9999, ...))
--     coins cost 1,000 yen per 50 (story3.lua:648)
--
-- so the money needed to fill a coin case is ceil(9999/50) * 1000 = 200,000.
-- That is exactly the Red and Yellow figure (PORYGON, 9,999 coins). On Blue
-- the priciest prize is 6,500 coins = 130,000, so the jackpot over-delivers
-- by 70,000 -- an error in the player's favour on the tier whose entire
-- premise is being spoiled rotten.
Luck.COIN_CAP = 9999
Luck.COINS_PER_BATCH = 50
Luck.BATCH_PRICE = 1000

function Luck.jackpotValue(opts)
  opts = opts or {}
  local cap = opts.coinCap or Luck.COIN_CAP
  local per = opts.coinsPerBatch or Luck.COINS_PER_BATCH
  local price = opts.batchPrice or Luck.BATCH_PRICE
  if per <= 0 then return Luck.MONEY_CAP end
  return Luck.clampMoney(math.ceil(cap / per) * price)
end

-- ------- the lottery
--
-- Denominations are PLAN.md's, unchanged: 5 / 10 / 20 / 100 / 500 / 1000,
-- plus the jackpot. Losses come from "no prize at all" rather than from a
-- negative, so a 100 yen ticket can never cost the player more than the
-- 100 yen they paid at the counter -- which is the other half of the money
-- floor rule (a loss that subtracted could underflow a save at 0 yen).
Luck.DENOMS = { 5, 10, 20, 100, 500, 1000 }

-- P[tier][i] = probability of winning DENOMS[i] on one ticket.
--
-- Read this table COLUMN-wise: every column is monotone from REALISTIC up
-- to HORSESHOE, so a higher tier is more likely to pay out at every single
-- denomination, not merely on average. `luck_test.lua` asserts exactly
-- that, because "the ladder goes up" is the mod's central promise and an
-- average can hide a rung that got worse.
Luck.PRIZE_P = {
  ["REALISTIC"]    = { 0.070, 0.045, 0.030, 0.030, 0.020, 0.030 },
  ["NORMAL"]       = { 0.150, 0.100, 0.080, 0.100, 0.050, 0.050 },
  ["LUCKY SOCKS"]  = { 0.160, 0.110, 0.090, 0.120, 0.060, 0.065 },
  ["RABBITS FOOT"] = { 0.170, 0.120, 0.100, 0.140, 0.075, 0.090 },
  ["HORSESHOE"]    = { 0.180, 0.130, 0.110, 0.170, 0.100, 0.130 },
  -- every ticket is the jackpot, so no denomination can ever be drawn
  ["MISSINGNO"]    = { 0, 0, 0, 0, 0, 0 },
  -- STARDUST matches it: there is nothing above "every ticket wins the top
  -- prize", and pretending otherwise would put a fake rung on the ladder.
  ["STARDUST"]     = { 0, 0, 0, 0, 0, 0 },
}

-- Jackpot probability. NORMAL is deliberately absent: its jackpot chance is
-- SOLVED at runtime so the expected value of a ticket is exactly the ticket
-- price, on every version, whatever the jackpot turns out to be worth. That
-- is what keeps the default tier honest -- a lottery with an edge either
-- way would quietly change a playthrough's economy, which the prime rule
-- forbids.
Luck.JACKPOT_P = {
  ["REALISTIC"]    = 1 / 50000,
  ["NORMAL"]       = nil,       -- solved; see jackpotChance below
  ["LUCKY SOCKS"]  = 1 / 8000,
  ["RABBITS FOOT"] = 1 / 3000,
  ["HORSESHOE"]    = 1 / 750,
  ["MISSINGNO"]    = 1.0,
  ["STARDUST"]     = 1.0,
}

local function prizeRow(tier)
  return Luck.PRIZE_P[Luck.tierOf(tier)] or Luck.PRIZE_P[Luck.DEFAULT_TIER]
end

-- Expected value of the small prizes alone, in yen.
function Luck.smallPrizeEV(tier)
  local row, ev = prizeRow(tier), 0
  for i, d in ipairs(Luck.DENOMS) do ev = ev + (row[i] or 0) * d end
  return ev
end

function Luck.jackpotChance(tier, jackpot)
  tier = Luck.tierOf(tier)
  jackpot = jackpot or Luck.jackpotValue()
  local fixed = Luck.JACKPOT_P[tier]
  if fixed then return fixed end
  -- NORMAL: solve EV == ticket price.
  if jackpot <= 0 then return 0 end
  local p = (Luck.TICKET_PRICE - Luck.smallPrizeEV(tier)) / jackpot
  if p < 0 then return 0 end
  if p > 1 then return 1 end
  return p
end

function Luck.expectedValue(tier, jackpot)
  jackpot = jackpot or Luck.jackpotValue()
  return Luck.smallPrizeEV(tier) + Luck.jackpotChance(tier, jackpot) * jackpot
end

-- Return on the 100 yen a ticket costs. 1.0 is break-even.
function Luck.rtp(tier, jackpot)
  return Luck.expectedValue(tier, jackpot) / Luck.TICKET_PRICE
end

function Luck.winRate(tier, jackpot)
  local row, p = prizeRow(tier), 0
  for i = 1, #Luck.DENOMS do p = p + (row[i] or 0) end
  return p + Luck.jackpotChance(tier, jackpot)
end

-- One ticket. `rnd` is a function returning [0,1) -- injected so the tests
-- can drive it deterministically and so the engine can hand over
-- love.math.random without this file ever naming it.
--
-- Rank 0 is a loss, 1..6 index DENOMS, and "JACKPOT" is its own rank so a
-- caller never has to compare a money amount to decide which text to show.
-- The jackpot is tested FIRST and the denominations big-to-small, so the
-- rarest outcome owns the bottom of the [0,1) line and rounding noise in
-- the common ranks can never eat it.
function Luck.draw(tier, jackpot, rnd)
  tier = Luck.tierOf(tier)
  jackpot = jackpot or Luck.jackpotValue()
  local r = rnd()
  local acc = Luck.jackpotChance(tier, jackpot)
  if r < acc then
    return { rank = "JACKPOT", money = jackpot }
  end
  local row = prizeRow(tier)
  for i = #Luck.DENOMS, 1, -1 do
    acc = acc + (row[i] or 0)
    if r < acc then
      return { rank = i, money = Luck.DENOMS[i] }
    end
  end
  return { rank = 0, money = 0 }
end

-- ------- prize mode: money, or RARE CANDY
--
-- The candy option is NOT a second lottery. It is the SAME draw, with the
-- SAME odds at every tier, banked at the RARE CANDY's own vanilla shop
-- price instead of being paid in cash.
--
-- Why the price and not a hand-written candy ladder: data/generated/items
-- prices RARE_CANDY at 4,800 yen on red, blue AND yellow. That is a real
-- in-game exchange rate the game already ships, and using it means:
--
--   * candy mode is edge-neutral at NORMAL BY CONSTRUCTION, not by a table
--     somebody has to keep balanced. Whatever money mode pays, candy mode
--     pays the same value. The prime rule survives the new feature.
--   * candy mode inherits REALISTIC's deliberately bad odds EXACTLY -- it
--     pays 48% of the money, so it banks 48% of the candy. No second set of
--     numbers to argue about, and no way for the two modes to disagree
--     about how unlucky REALISTIC is.
--   * a 5 yen win is not silently thrown away. It could not buy a candy on
--     its own, and a scratch card that pays "nothing" 4 times out of 5 is
--     a worse toy than one that pays "not yet".
--
-- The bank is the piece that makes it work: winnings accumulate as credit
-- and convert the moment the credit passes 4,800. At NORMAL that is one
-- candy per ~48 tickets, which is exactly what "a candy is worth 4,800 yen
-- and a ticket costs 100" means. It arrives far faster up the ladder.
--
-- The bank is capped at 99 candies' worth because 99 is the per-slot
-- quantity cap Bag.add enforces; credit beyond that could never be spent.
Luck.CANDY_ID = "RARE_CANDY"
Luck.CANDY_PRICE = 4800
Luck.CANDY_STACK_CAP = 99
Luck.BANK_CAP = Luck.CANDY_STACK_CAP * Luck.CANDY_PRICE

Luck.PRIZE_MODES = { "MONEY", "CANDY" }
Luck.DEFAULT_PRIZE_MODE = "MONEY"

function Luck.prizeModeOf(value)
  for _, m in ipairs(Luck.PRIZE_MODES) do if m == value then return m end end
  return Luck.DEFAULT_PRIZE_MODE
end

-- Add winnings to the candy bank. Returns the new bank and how much was
-- forfeited at the cap, so the caller can say so rather than quietly
-- losing it.
function Luck.bankAdd(bank, amount)
  bank = math.max(0, math.floor(tonumber(bank) or 0))
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  local wanted = bank + amount
  if wanted > Luck.BANK_CAP then
    return Luck.BANK_CAP, wanted - Luck.BANK_CAP
  end
  return wanted, 0
end

-- How many whole candies the bank is currently worth.
function Luck.candiesInBank(bank)
  return math.floor(math.max(0, math.floor(tonumber(bank) or 0)) / Luck.CANDY_PRICE)
end

-- Take `n` candies out of the bank. The caller takes them one at a time so
-- it can stop the instant Bag.add refuses (a full bag, or a stack that
-- would pass 99); whatever it could not fit STAYS BANKED and is paid out
-- the next time there is room. Nothing is ever lost to a full bag, which is
-- the answer to "what happens when the bag is full" for every tier
-- including MISSINGNO, where 41 candies land at once, every ticket.
function Luck.bankTake(bank, n)
  bank = math.max(0, math.floor(tonumber(bank) or 0))
  n = math.max(0, math.floor(tonumber(n) or 0))
  local affordable = math.min(n, Luck.candiesInBank(bank))
  return bank - affordable * Luck.CANDY_PRICE, affordable
end

-- Expected candies per ticket, for the tests and the help page.
function Luck.candyEV(tier, jackpot)
  return Luck.expectedValue(tier, jackpot) / Luck.CANDY_PRICE
end

-- ------- system 1: the slot machine
--
-- A faithful transcription of SlotMachine:setFlags (src/ui/SlotMachine.lua,
-- itself a port of SlotMachine_SetFlags + game_corner_slots.asm), with the
-- four vanilla constants lifted out into a per-tier row.
--
-- The mod turns a dial the game already shipped. It decides WHICH OUTCOMES
-- ARE PERMITTED and nothing else -- never the reels, the bet menu, the
-- payout drip, the 9,999 coin cap or the paylines-per-bet rule. Those are
-- the machine's presentation and its accounting, and both are untouched.
--
--   luckyChance / plainChance  wSlotMachineSevenAndBarModeChance. One
--                              machine per Game Corner visit is "lucky".
--                              r > chance arms seven-and-bar mode.
--   matchThreshold             r > this (and <= chance) allows a match.
--   streakBelow                r < this arms the allow-matches counter.
--                              Vanilla is r == 0, i.e. 1 of 256.
--   streakLen                  wSlotMachineAllowMatchesCounter, vanilla 60.
--
-- The NORMAL row is 250 / 253 / 210 / 1 / 60, which IS vanilla.
--
-- A tuning trap worth writing down, found by simulation rather than by
-- reading: the allow-matches streak SUPPRESSES seven-and-bar mode. The asm
-- (and the port) returns as soon as it sees a live counter, so no
-- seven-and-bar roll happens while a streak is running. An early draft
-- raised streakBelow with the tier -- 2, 4, then 8 of 256 -- which made the
-- top tiers spend ~79% of their spins inside a streak and therefore win
-- MORE OFTEN but for LESS (15 and 8, not 300 and 100). Every tier now keeps
-- vanilla's 1-in-256 arming and grows only the streak length, which leaves
-- room for the seven-and-bar band to grow with the tier. Measured
-- seven-and-bar occupancy is monotone across the ladder; see
-- tests/simulate.lua section 4.
Luck.SLOTS = {
  ["REALISTIC"]    = { luckyChance = 254, plainChance = 255,
                       matchThreshold = 240, streakBelow = 0, streakLen = 60 },
  ["NORMAL"]       = { luckyChance = 250, plainChance = 253,
                       matchThreshold = 210, streakBelow = 1, streakLen = 60 },
  ["LUCKY SOCKS"]  = { luckyChance = 244, plainChance = 248,
                       matchThreshold = 190, streakBelow = 1, streakLen = 70 },
  ["RABBITS FOOT"] = { luckyChance = 230, plainChance = 236,
                       matchThreshold = 160, streakBelow = 1, streakLen = 80 },
  ["HORSESHOE"]    = { luckyChance = 200, plainChance = 210,
                       matchThreshold = 110, streakBelow = 1, streakLen = 90 },
  -- seven-and-bar mode forced on, matches always allowed. That is the
  -- strongest thing the vanilla machine can be told to do without touching
  -- a reel, and it is what PLAN.md's "every spin is a 7-7-7" cashes out to.
  ["MISSINGNO"]    = { force = true },
  ["STARDUST"]     = { force = true },
}

-- state = { sevenBar = bool, canWin = bool, counter = int }
-- r is love.math.random(0, 255) -- an integer 0..255, as the asm rolls it.
-- Returns a NEW state table; the caller writes it back. Pure, so the test
-- can run a million spins without a game.
function Luck.slotFlags(tier, state, r, lucky)
  local row = Luck.SLOTS[Luck.tierOf(tier)] or Luck.SLOTS[Luck.DEFAULT_TIER]
  local out = {
    sevenBar = state.sevenBar or false,
    canWin = state.canWin or false,
    counter = state.counter or 0,
  }
  if row.force then
    out.sevenBar, out.canWin = true, true
    return out
  end
  -- seven-and-bar mode, once armed, is sticky (the asm returns early while
  -- the bit is set); it is cleared by a BAR win, or half the time by a 300.
  if out.sevenBar then return out end
  if out.counter > 0 then
    out.canWin = true
    return out
  end
  if r < row.streakBelow then
    -- this spin's flags are left untouched, exactly as the asm returns
    -- before writing them
    out.counter = row.streakLen
    return out
  end
  local chance = lucky and row.luckyChance or row.plainChance
  if r > chance then
    out.sevenBar = true
    return out
  end
  if r > row.matchThreshold then
    out.canWin = true
    return out
  end
  out.canWin = false
  return out
end

-- The share of the 256 rolls that makes THIS spin winnable on the spot,
-- for one machine, ignoring the allow-matches streak. Closed form, so the
-- test has an exact number to hold the simulation against; the simulation
-- then measures the true long-run rate, which is higher because the streak
-- carries permission forward for streakLen spins.
--
-- The streak range (r < streakBelow, at most 8) never overlaps the canWin
-- range (r > matchThreshold, at least 110), so the two counts do not
-- interact and the arithmetic stays this simple.
function Luck.slotPermitRate(tier, lucky)
  local row = Luck.SLOTS[Luck.tierOf(tier)] or Luck.SLOTS[Luck.DEFAULT_TIER]
  if row.force then return 1.0 end
  local chance = math.min(lucky and row.luckyChance or row.plainChance, 255)
  local sevenBar = math.max(0, 255 - chance)              -- r > chance
  local canWin = math.max(0, chance - row.matchThreshold) -- matchThreshold < r <= chance
  return (sevenBar + canWin) / 256
end

-- ------- system 2: shiny rate
--
-- Shiny is NOT a vanilla Gen 1 feature; it comes from Dramatic Shape, which
-- derives it from DVs. Ownership was settled in PLAN.md: the global on/off
-- belongs to Dramatic Mini Modifications, the RATE belongs here, and off
-- beats rate unconditionally. The two mods never write the same value --
-- one owns a boolean, the other a denominator.
--
-- NORMAL is absent from this table on purpose. Dramatic Shape's own
-- `Shiny.setOdds` PINS the denominator, which takes its SHINY ODDS row out
-- of service until something unpins it. At NORMAL this mod pins nothing and
-- Dramatic Shape's row keeps working, which is what "NORMAL touches
-- nothing" has to mean here.
--
-- REALISTIC pins 8192 -- the standard Pokemon rate, per PLAN.md. It is also
-- Dramatic Shape's own default, so the only observable difference at that
-- tier is that the DS row stops moving.
Luck.SHINY_DENOM = {
  ["REALISTIC"]    = 8192,
  ["NORMAL"]       = nil,
  ["LUCKY SOCKS"]  = 2048,
  ["RABBITS FOOT"] = 512,
  ["HORSESHOE"]    = 128,
  -- 1:1 at both top rungs. The DIFFERENCE is what happens afterwards:
  -- MISSINGNO yields the forced shiny once that species' shinies are all
  -- held (lib/ShinyRate.lua), STARDUST never does.
  ["MISSINGNO"]    = 1,
  ["STARDUST"]     = 1,
}

-- ------- system 3: wild encounters
--
-- "Higher luck means better chances to encounter Pokemon you don't have."
--
-- THE PLACEMENT RULE, which outranks everything else in this section: luck
-- reweights WITHIN a map's own encounter table and NEVER puts a species on a
-- map that does not list it. The whole project holds placement authentic --
-- there is a test suite for exactly that -- and a luck feature that walked a
-- missing Mewtwo onto Route 1 would be the precise thing that suite exists
-- to catch. So the mechanism below has no way to express "add a species":
-- it can only scale the widths of the slots the table already has. A map
-- whose table is fully caught is a map this feature does not touch.
--
-- "Don't have" means NOT IN THE POKEDEX'S OWNED SET -- the engine's own
-- save.pokedex.owned, the thing the dex screen itself draws the ball glyph
-- from. Seen-but-never-caught counts as missing: you do not HAVE what you
-- once ran away from. Sprite Variety keeps its own per-cartridge collection;
-- deliberately NOT consulted, because coupling two mods' definitions of
-- "caught" would make this feature change meaning whenever that mod does.
--
-- The dial is a WEIGHT MULTIPLIER on the missing slots, matching the shape
-- of the other three systems: one number per tier, monotone above NORMAL,
-- nothing below it. Vanilla's slot widths are x/256 (encounterBuckets); a
-- missing slot's width is multiplied and the whole table renormalised, so
--
--   P(slot i) = w_i * boost_i / sum(w_j * boost_j),  boost_j in {1, boost}
--
-- Worked example, the Route 1 shape: PIDGEY missing on 131/256 of the
-- table, RATTATA caught on 125/256. At HORSESHOE (x8) PIDGEY's share goes
-- from 51% to 89%; at x16 to 94%. A RARE missing local -- the 3/256 tenth
-- slot -- goes to 48/301 = 16% at x16: found sooner, never guaranteed. The
-- table cannot degenerate, because every caught slot keeps its full vanilla
-- width and every ratio between caught slots is preserved exactly.
--
-- What is NOT scaled, ever:
--   * the encounter RATE (grass.rate) -- how often anything jumps out;
--   * the creature itself -- level comes from the slot, DVs from the same
--     vanilla path as always, so every biased encounter is a Pokemon the
--     cartridge itself could have produced on that exact tile;
--   * the tables -- nothing in data.encounters is written.
--
-- REALISTIC is 1 on purpose. The joke tier is about GAMBLING losing you
-- money; making the wilds hide what you seek would be a different, meaner
-- joke, and it would put a "below vanilla" rung on a ladder the request
-- ("better chances") only defined upward. Shiny set the precedent:
-- REALISTIC there pins the standard rate, i.e. it matches vanilla too.
Luck.WILD_BOOST = {
  ["REALISTIC"]    = 1,
  ["NORMAL"]       = 1,
  ["LUCKY SOCKS"]  = 2,
  ["RABBITS FOOT"] = 4,
  ["HORSESHOE"]    = 8,
  ["MISSINGNO"]    = 16,
  ["STARDUST"]     = 16,
}

function Luck.wildBoost(tier)
  return Luck.WILD_BOOST[Luck.tierOf(tier)] or 1
end

-- Integer weights for one table. `buckets` is the CUMULATIVE threshold list
-- the engine rolls against (vanilla: constants.encounterBuckets, last entry
-- 256; a table may carry its own); slot i's vanilla width is the gap between
-- thresholds. `isMissing(species) -> bool` is injected so this file stays
-- pure of any save shape.
--
-- Returns weights[], total, missingCount, presentCount.
--
-- A bucket with no slot behind it keeps weight 0 HERE and its full width in
-- the engine's own roll: the caller only ever re-picks after the vanilla
-- roll already landed on a real slot, so "this step found nothing" keeps its
-- exact vanilla probability and the re-pick renormalises over real slots
-- only -- which is also what makes weights of integers sum to an integer a
-- fair single draw can span.
function Luck.wildWeights(slots, buckets, isMissing, boost)
  boost = math.max(1, math.floor(tonumber(boost) or 1))
  local weights, total = {}, 0
  local missing, present = 0, 0
  local prev = 0
  for i, threshold in ipairs(buckets) do
    local t = tonumber(threshold) or prev
    local width = math.max(0, t - prev)
    prev = t
    local slot = slots[i]
    local w = 0
    if width > 0 and type(slot) == "table" and slot.species ~= nil then
      present = present + 1
      if isMissing(slot.species) then
        missing = missing + 1
        w = width * boost
      else
        w = width
      end
    end
    weights[i] = w
    total = total + w
  end
  return weights, total, missing, present
end

-- One draw: r is an integer in [0, total-1]. Returns the slot index, or nil
-- on a malformed call (total 0), which the caller treats as "leave the
-- vanilla pick alone".
function Luck.wildPick(weights, total, r)
  if not (total and total > 0 and r and r >= 0 and r < total) then return nil end
  local acc = 0
  for i, w in ipairs(weights) do
    acc = acc + w
    if r < acc then return i end
  end
  return nil
end

return Luck
