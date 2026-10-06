-- The FORTUNE page: this mod's rows, on a page of its own.
--
-- Shaped after DRAMATIC_MINI/lib/ToggleMenu.lua (the same user's own mod)
-- for the same two reasons recorded there:
--
--   * The engine's OPTIONS list shows FOUR rows at a time and this install
--     is already past thirty. Splicing six more in at the top would push the
--     engine's own settings a page and a half down for a group most players
--     set once. One root row that OPENS A PAGE is the shape the engine
--     actually provides (OptionsMenu.lua:557 fires `activate` on A).
--   * Layout and input follow src/ui/OptionRows.lua exactly, so the page
--     looks and behaves like every other page in the game.
--
-- Two things about the row text that are not obvious and cost real time to
-- rediscover:
--
--   * `Font.encode` SILENTLY substitutes a space for
--     `# $ % & * + < = > @ \ ^ _ ` { | } ~`. Punctuation vanishes with no
--     error, which is why "RABBIT'S FOOT" ships as RABBITS FOOT and why
--     every label here is uppercase letters and spaces only.
--   * OptionRows draws the label at x = 16 and the VALUE at x = 24 on a
--     160px screen, so a value has 16 columns. "MISSINGNO. SMILES ON YOU"
--     does not fit; the row says MISSINGNO and the help page says the rest.

local OptionRows = require("src.ui.OptionRows")
local PaletteFX = require("src.render.PaletteFX")
local Font = require("src.render.Font")

local SettingsMenu = {}
SettingsMenu.__index = SettingsMenu

-- A screen that declares no palette INHERITS the zones of whatever was under
-- it, and one of those covers UI rows 8-9 -- exactly the third row's label
-- line, which then renders in a stray colour. The engine's own OptionsMenu
-- hit this and fixed it the same way (OptionsMenu.lua:35-42). Claiming the
-- whole screen with one flat palette is the fix; isOpaque is the other half.
SettingsMenu.isOpaque = true

function SettingsMenu:sgbPalettes(game)
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

-- ctx: { rows, value(key), setValue(game, key, v), toggle(key),
--        setToggle(game, key, v), help(game, title, body), changed(key) }
function SettingsMenu.new(game, ctx)
  local self = setmetatable({}, SettingsMenu)
  self.game = game
  self.ctx = ctx
  self.index = 1
  self.scroll = 0

  local rows = {}
  for _, row in ipairs(ctx.rows or {}) do
    local key = row.key
    -- a row may declare `visible()`; a hidden row is simply not built, which
    -- is how the SHINY row stays absent when Dramatic Shape is not there
    local show = true
    if type(row.visible) == "function" then
      local ok, v = pcall(row.visible)
      show = ok and v ~= false
    end
    if show and row.type == "choice" and type(row.values) == "table" then
      rows[#rows + 1] = {
        id = "FORTUNES_FAVOR:" .. key,
        label = row.label or key:upper(),
        help = row.help,
        value = function() return ctx.value(key, row.default) end,
        step = function(g, dir)
          local cur, at = ctx.value(key, row.default), 1
          for i, v in ipairs(row.values) do if v == cur then at = i end end
          local n = #row.values
          at = ((at - 1 + (dir or 1)) % n) + 1
          ctx.setValue(g, key, row.values[at])
          ctx.changed(key)
          return true
        end,
      }
    elseif show then
      rows[#rows + 1] = {
        id = "FORTUNES_FAVOR:" .. key,
        label = row.label or key:upper(),
        help = row.help,
        value = function() return ctx.toggle(key) and "ON" or "OFF" end,
        step = function(g)
          ctx.setToggle(g, key, not ctx.toggle(key))
          ctx.changed(key)
          return true
        end,
      }
    end
  end
  self.rows = rows
  return self
end

function SettingsMenu:update()
  local input = self.game.input
  local rows = self.rows
  local backRow = #rows + 1

  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or backRow
  elseif input:wasPressed("down") then
    self.index = self.index < backRow and self.index + 1 or 1
  elseif input:wasPressed("select") then
    -- A page of plain English about the highlighted row. The labels are
    -- eight characters because that is what fits; this is where the
    -- explaining happens.
    local row = rows[self.index]
    local help = self.ctx and self.ctx.help
    if row and row.help and help then
      pcall(help, self.game, row.label, row.help)
    end
  elseif input:wasPressed("b") then
    self.game.stack:pop()
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local row = rows[self.index]
    if row then
      local dir = input:wasPressed("left") and -1 or 1
      if row.step then row.step(self.game, dir) end
    elseif input:wasPressed("a") then
      self.game.stack:pop()                     -- the BACK row
    end
  end

  self.scroll = OptionRows.clampScroll(self.index, self.scroll,
                                       #rows + 1, backRow)
end

-- Short, and at x = 8. OptionRows' four boxes end at 127, its bottom label
-- sits at 136 and its scroll arrow at 144, so a 12-glyph hint from x = 8
-- ends at 104 and collides with nothing.
SettingsMenu.HINT = "SELECT: INFO"
SettingsMenu.HINT_X = 8

function SettingsMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll,
                  "BACK", #self.rows + 1)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(SettingsMenu.HINT, SettingsMenu.HINT_X, 128)
  love.graphics.setColor(1, 1, 1, 1)
end

return SettingsMenu
