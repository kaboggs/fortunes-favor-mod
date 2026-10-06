-- A page of plain English about one setting, opened with SELECT.
--
-- Carried in this mod's own folder rather than reached for inside
-- DRAMATIC_MINI, even though that is the same user's mod and the file is
-- identical: a mod that reaches into another mod's lib gains a dependency on
-- it staying installed, staying enabled and keeping that file. Fortune's
-- Favor must run on its own with nothing else present, so it owns its help
-- page. Cross-mod borrowing is what `mod.exports` is for, and a help screen
-- is not worth an export.
--
-- Layout follows the engine's own OptionRows so the two pages read as one
-- program: 160x144 logical pixels, an 8px font, black ink on white paper.

local Font = require("src.render.Font")

local HelpScreen = {}
HelpScreen.__index = HelpScreen

local MARGIN = 8
local LINE = 8
local TOP = 24          -- under the title and its rule
local VISIBLE = 13      -- lines that fit above the footer at 136

-- Greedy wrap at the 8px grid. The Game Boy font is fixed width, so a line
-- fits when its character count does -- no measuring required.
local function wrap(body, cols)
  local out = {}
  for para in tostring(body or ""):gmatch("[^\n]*") do
    if para == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        if line == "" then
          line = word
        elseif #line + 1 + #word <= cols then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      if line ~= "" then out[#out + 1] = line end
    end
  end
  return out
end

function HelpScreen.new(game, title, body)
  local self = setmetatable({}, HelpScreen)
  self.game = game
  self.title = tostring(title or ""):upper()
  -- (160 - 2*8) / 8 = 18 characters per line
  self.lines = wrap(body, math.floor((160 - MARGIN * 2) / 8))
  self.scroll = 0
  return self
end

-- Opaque, and carrying its own palette, for the reason recorded in
-- ToggleMenu: a screen that declares neither inherits the zones of whatever
-- was under it, which paints a stray colour band across the third row.
HelpScreen.isOpaque = true

function HelpScreen:sgbPalettes(game)
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not (ok and PaletteFX and PaletteFX.wholeNamed) then return nil end
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

-- StateStack calls enter() and exit() on every state it pushes and pops
-- (src/core/StateStack.lua). A screen without them throws the moment it is
-- pushed -- which is exactly what happened the first time this page was
-- opened, and why SELECT appeared to do nothing.
function HelpScreen:enter() end
function HelpScreen:exit() end

function HelpScreen:update()
  local input = self.game.input
  local max = math.max(0, #self.lines - VISIBLE)
  if input:wasPressed("up") then
    self.scroll = math.max(0, self.scroll - 1)
  elseif input:wasPressed("down") then
    self.scroll = math.min(max, self.scroll + 1)
  elseif input:wasPressed("b") or input:wasPressed("a")
      or input:wasPressed("select") or input:wasPressed("start") then
    self.game.stack:pop()
  end
end

function HelpScreen:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(self.title, MARGIN, 8)
  love.graphics.rectangle("fill", MARGIN, 18, 160 - MARGIN * 2, 1)
  for i = 1, VISIBLE do
    local line = self.lines[self.scroll + i]
    if not line then break end
    Font.draw(line, MARGIN, TOP + (i - 1) * LINE)
  end
  -- the footer sits at 136, the row OptionRows leaves free for it
  Font.draw("B: BACK", MARGIN, 136)
  if self.scroll + VISIBLE < #self.lines then
    Font.draw("MORE", 160 - MARGIN - 4 * 8, 136)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return HelpScreen
