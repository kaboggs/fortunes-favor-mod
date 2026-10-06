-- Fortune's Favor -- the Game Corner slot machine.
--
-- The mod OWNS NOTHING here. Vanilla Gen 1 already ships a hidden luck stat
-- (SlotMachine_SetFlags + game_corner_slots.asm, ported faithfully in
-- src/ui/SlotMachine.lua), and all this file does is scale the four numbers
-- that stat is made of. That is what makes "do not break a vanilla feature"
-- enforceable rather than aspirational: there is one function to decorate,
-- and at NORMAL it is not decorated at all.
--
-- What is deliberately NOT touched, because it is the machine's presentation
-- and its accounting rather than its odds:
--
--   * the reel animation, the half-step offsets and the slip counters
--   * the wheel-3 reroll
--   * the x1 / x2 / x3 bet menu and the paylines-per-bet rule
--   * the payout drip timing and its jingle
--   * the "One more go?" prompt
--   * the 9,999 coin cap
--
-- The mod changes WHICH OUTCOMES ARE PERMITTED. Nothing else.
--
-- ------- the seam
--
-- `SlotMachine.setFlags` is a method on the module table, and instances are
-- `setmetatable({}, SlotMachine)` with `__index = SlotMachine`, so replacing
-- the field reaches every machine, including one already on screen. Same
-- shape DRAMATIC_MINI uses on Dramatic Shape's Shiny.isShiny.
--
-- Installed LAZILY, from the heartbeat, rather than at entry-chunk time:
-- src/ui/SlotMachine.lua drags in Font, Theme and the renderer, and the mod
-- entry chunk runs while the Game is still being wired.

local Slots = {}

local installed = false

-- ctx = { Luck, log, enabled() -> bool, tier() -> string, random(a,b) -> int }
function Slots.install(ctx)
  if installed then return false end
  local ok, SlotMachine = pcall(require, "src.ui.SlotMachine")
  if not (ok and type(SlotMachine) == "table"
      and type(SlotMachine.setFlags) == "function") then
    return false
  end
  local Luck = ctx.Luck
  local inner = SlotMachine.setFlags

  SlotMachine.setFlags = function(self, ...)
    -- THE early-out. At NORMAL, and with the row off, the vanilla function
    -- runs untouched and this mod is not in the call path in any observable
    -- sense. tests/luck_test.lua additionally proves that Luck.slotFlags at
    -- NORMAL would have returned the same answer anyway, so even a bug in
    -- this line cannot change vanilla behaviour.
    local tier = Luck.tierOf(ctx.tier())
    if Luck.isVanilla(tier) or not ctx.enabled() then
      return inner(self, ...)
    end
    -- Which machine is this? The engine records the per-visit lucky machine
    -- only as the seven-and-bar chance it was built with (SlotMachine.new:
    -- 250 when lucky, 253 when not), so that is what is read back. An
    -- unrecognised value is treated as a plain machine, which is the
    -- conservative reading.
    local lucky = self.sevenBarChance == 250
    local state = {
      sevenBar = self.sevenBar,
      canWin = self.canWin,
      counter = self.allowMatchesCounter or 0,
    }
    local done, out = pcall(Luck.slotFlags, tier, state, ctx.random(0, 255), lucky)
    if not (done and type(out) == "table") then
      if ctx.log then ctx.log:error("slot flags failed: %s", tostring(out)) end
      return inner(self, ...)
    end
    self.sevenBar = out.sevenBar
    self.canWin = out.canWin
    self.allowMatchesCounter = out.counter
  end

  installed = true
  return true
end

function Slots.installed() return installed end

return Slots
