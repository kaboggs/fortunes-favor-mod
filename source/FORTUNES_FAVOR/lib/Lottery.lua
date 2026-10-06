-- Fortune's Favor -- the LOTTO TICKET: getting it into the marts, and what
-- happens when the player scratches one.
--
-- ------- how the ticket reaches every Poke Mart
--
-- Mart stock is ROM-derived and lives at
-- `data.text_pointers[<mapLabel>][<TEXT_CONST>].mart`, an array of item ids.
-- TWO places open a shop from it, not one:
--
--   Commands.open_mart          (src/script/Commands.lua:852) -- scripts that
--                               mix dialogue with shopping, e.g. the Viridian
--                               clerk after the parcel
--   OverworldController         (src/world/OverworldController.lua:2672) --
--                               the ordinary "talk to the clerk" path, which
--                               is how nearly every mart is actually entered
--
-- PLAN.md proposed hooking `script.command` on open_mart. That was checked
-- and rejected: it covers the FIRST site only, so most marts would not stock
-- the ticket. Appending to the stock lists themselves covers both, once, and
-- needs no hook at all.
--
-- The append happens on the `mods.loaded` event, which the loader emits with
-- the merged `data` after every mod's entry chunk has run and every registry
-- has folded home (Loader.lua:1081). Doing it there rather than in the entry
-- chunk means a mod that ADDS a mart still gets a ticket in it.
--
-- It is idempotent, and it never creates a mart that did not exist: only a
-- text entry that already carries a `.mart` array is touched, so no clerk,
-- sign or nurse turns into a shop.
--
-- ------- how a ticket is scratched
--
-- By wrapping `ItemEffects.use`, not by registering an item_effect.
--
-- The engine HAS a `mod.content.item_effects` registry and `items.effect`
-- points at it -- and NOTHING IN src/ READS EITHER. Verified by search: the
-- only references to `item_effects` outside the schema file are comments
-- naming the pokered source file. A registered effect would load clean,
-- validate clean, and never run. `ItemEffects.use` is the single function
-- BagMenu calls for every item (BagMenu.lua:50), and it is reached through
-- the module table, so replacing the field decorates every caller at once --
-- the same shape DRAMATIC_MINI uses on Dramatic Shape's `Shiny.isShiny`.
--
-- The wrap is a pass-through for every item id but ours.

local Lottery = {}

local installed = false

-- ------- text
--
-- Gen 1 text boxes are 18 characters by 2 lines; "\n" is the second line and
-- "\f" is a page break (BagMenu's showMessages joins a message list with \f).
-- Every string below is inside 18 columns.

local function moneyText(name, amount)
  return ("%s got\n¥%d!"):format(name, amount)
end

-- The yen sign is written as the literal UTF-8 character, which is what
-- Font.split expects (it walks UTF-8 sequences, so a raw 0xA5 byte would be
-- an invalid sequence and draw as a space). ShopMenu spells its prices the
-- same way.

-- ------- stocking the marts

-- Returns the number of mart lists the ticket was added to.
function Lottery.stockMarts(data, itemId)
  if type(data) ~= "table" then return 0 end
  local pointers = data.text_pointers
  if type(pointers) ~= "table" then return 0 end
  local added = 0
  for _, perMap in pairs(pointers) do
    if type(perMap) == "table" then
      for _, entry in pairs(perMap) do
        if type(entry) == "table" and type(entry.mart) == "table" then
          local present = false
          for _, id in ipairs(entry.mart) do
            if id == itemId then present = true break end
          end
          if not present then
            entry.mart[#entry.mart + 1] = itemId
            added = added + 1
          end
        end
      end
    end
  end
  return added
end

-- Remove it again, so switching the TICKETS row off inside a session takes
-- effect at the next mart rather than at the next restart.
function Lottery.unstockMarts(data, itemId)
  if type(data) ~= "table" then return 0 end
  local pointers = data.text_pointers
  if type(pointers) ~= "table" then return 0 end
  local removed = 0
  for _, perMap in pairs(pointers) do
    if type(perMap) == "table" then
      for _, entry in pairs(perMap) do
        if type(entry) == "table" and type(entry.mart) == "table" then
          for i = #entry.mart, 1, -1 do
            if entry.mart[i] == itemId then
              table.remove(entry.mart, i)
              removed = removed + 1
            end
          end
        end
      end
    end
  end
  return removed
end

-- ------- scratching one
--
-- ctx = {
--   Luck, log,
--   tier()        -> tier string
--   prizeMode()   -> "MONEY" | "CANDY"
--   getBank()     -> yen of candy credit
--   setBank(n)
--   random()      -> [0,1)
-- }
--
-- Returns the ItemEffects.use contract: "consumed" | "failed", { messages }.
function Lottery.scratch(ctx, data, save)
  local Luck = ctx.Luck
  local tier = Luck.tierOf(ctx.tier())
  local jackpot = Luck.jackpotValue()
  local draw = Luck.draw(tier, jackpot, ctx.random)
  local name = (save.player and save.player.name) or "YOU"

  -- The scratch itself: two beats before the answer, so a ticket reads as
  -- an event rather than as a number appearing.
  local msgs = { "You scratch off\nthe silver panel...", "...and the rest!" }

  if draw.rank == 0 then
    msgs[#msgs + 1] = "No luck this time.\nBetter luck next!"
    return "consumed", msgs
  end

  if draw.rank == "JACKPOT" then
    msgs[#msgs + 1] = "JACKPOT!\nAll seven match!"
  else
    msgs[#msgs + 1] = "A WINNER!"
  end

  if Luck.prizeModeOf(ctx.prizeMode()) == "MONEY" then
    -- Money floor and cap. `moved` is what actually landed, which is what
    -- the player is told: winning 200,000 with 950,000 in the wallet pays
    -- 49,999, and saying otherwise is a lie the save file contradicts on
    -- the next write (GenSave.lua:858 truncates to 999,999).
    local after, moved = Luck.applyMoney(save.money, draw.money)
    save.money = after
    msgs[#msgs + 1] = moneyText(name, moved)
    if moved < draw.money then
      msgs[#msgs + 1] = "But the wallet is\nfull! Some was lost."
    end
    return "consumed", msgs
  end

  -- ------- candy mode
  --
  -- Same draw, same odds. The prize is banked as credit at the RARE CANDY's
  -- own vanilla shop price and converted the moment the credit passes it.
  local bank, forfeited = Luck.bankAdd(ctx.getBank(), draw.money)
  local Bag = require("src.inventory.Bag")
  local given = 0
  -- One candy at a time, stopping the INSTANT the bag refuses. Bag.add
  -- answers false for a full bag (no free slot) and for a stack that would
  -- pass 99, and both mean the same thing here: stop, and leave the rest
  -- banked. Nothing is lost to a full bag.
  while Luck.candiesInBank(bank) > 0 do
    if not Bag.add(save, Luck.CANDY_ID, 1, data) then break end
    local took
    bank, took = Luck.bankTake(bank, 1)
    given = given + took
  end
  ctx.setBank(bank)

  if given > 0 then
    msgs[#msgs + 1] = ("%s got\n%d RARE CANDY!"):format(name, given)
  end
  local pending = Luck.candiesInBank(bank)
  if pending > 0 then
    -- there was credit for a candy and the bag would not take it
    msgs[#msgs + 1] = ("%d RARE CANDY is\nheld for later."):format(pending)
  elseif given == 0 then
    msgs[#msgs + 1] = ("Saved ¥%d toward\na RARE CANDY."):format(bank)
  end
  if forfeited > 0 then
    msgs[#msgs + 1] = "The ticket book is\nfull! Some lost."
  end
  return "consumed", msgs
end

-- ------- installing the wrap

function Lottery.install(ctx)
  if installed then return false end
  local ok, ItemEffects = pcall(require, "src.inventory.ItemEffects")
  if not (ok and type(ItemEffects) == "table"
      and type(ItemEffects.use) == "function") then
    return false
  end
  local Luck = ctx.Luck
  local inner = ItemEffects.use
  ItemEffects.use = function(data, save, itemId, target, battle, moveIndex, ow)
    if itemId ~= Luck.TICKET_ID then
      return inner(data, save, itemId, target, battle, moveIndex, ow)
    end
    -- Refused mid-battle, like every other field item (ItemUseNotTime).
    -- Written out rather than delegated because `inner` would fall through
    -- to its own "not the time" tail anyway and this says so on purpose.
    if battle then
      return "failed", { ("OAK: %s!\nThis isn't the\ftime to use that!")
        :format((save.player and save.player.name) or "YOU") }
    end
    local done, result, msgs = pcall(Lottery.scratch, ctx, data, save)
    if not done then
      -- A fault here must cost the ticket's EFFECT, never the bag menu the
      -- player is standing in. `failed` is the engine's own no-effect path
      -- and leaves the ticket in the bag.
      if ctx.log then ctx.log:error("scratch failed: %s", tostring(result)) end
      return "failed", { "The ticket is\nsmudged beyond\freading." }
    end
    -- Arm cosmetic art only after the authoritative scratch succeeds. A
    -- failed pcall must not leave a 30-second modal behind in another menu.
    if result == "consumed" and ctx.ticketArt
        and type(ctx.ticketArt.begin) == "function" then
      pcall(ctx.ticketArt.begin, ctx.mod, ctx.random)
    end
    return result, msgs
  end
  installed = true
  return true
end

function Lottery.installed() return installed end

return Lottery
