-- TicketArt -- draw a real ticket behind its scratch-result messages.
--
-- ------- what it replaces
--
-- Using a LOTTO TICKET puts a message box over the bag. This puts the ticket
-- behind those messages, on an opaque paper backing, without letting the
-- generic ListMenu hook leak it into the PC, Pokedex, shops, or later menus.
--
-- ------- how it stays out of everything else's way
--
-- `ListMenu:draw` is the generic list. Wrapping it reaches the bag, the PC,
-- the Pokedex and every other list in the game, so the wrap does nothing at
-- all unless ALL of these hold:
--
--   * a scratch happened in the last few seconds (`M.begin` was called),
--   * this list is the bag that owns the scratch messages, and
--   * at least one ticket image actually loaded.
--
-- Any of those false and the stock draw runs untouched. With no art
-- installed the mod behaves exactly as it did before this file existed.
--
-- ------- the art itself
--
-- Hand-authored by the user. Files live in `assets/tickets/` and are picked
-- up by NAME ORDER, so adding one is a drop-in -- no code change, no list to
-- maintain. One is chosen at random per scratch.

local M = {}

-- The window between the title bar and the message box, in the Game Boy's
-- 160x144. The message box owns the bottom; the title sits at y=4.
M.AREA = { x = 0, y = 14, w = 160, h = 82 }

-- A BACKSTOP only. The art is normally retired the moment the message box
-- leaves the stack (see `messagesUp`), which is exact. This just guarantees
-- it cannot get stuck on if the stack is ever unreadable.
M.HOLD_SECONDS = 30

local images = nil      -- nil = not yet looked for; {} = looked, found none
local shown = nil       -- the image chosen for this scratch
local until_ = 0
local owner = nil       -- the one bag ListMenu allowed to present `shown`
local wrapped = false

local function now()
  if love and love.timer and love.timer.getTime then
    local ok, t = pcall(love.timer.getTime)
    if ok then return t end
  end
  return 0
end

-- Load every PNG in assets/tickets/, in name order. Done once, lazily, and
-- never retried on failure -- a missing folder is the normal case for anyone
-- who has not added art, not an error worth reporting every frame.
local function load(mod)
  if images then return images end
  images = {}
  if not (love and love.graphics and love.graphics.newImage) then return images end

  local names = {}
  local okList, listed = pcall(function()
    if mod and mod.assets and mod.assets.list then return mod.assets:list("assets/tickets") end
    if love.filesystem and love.filesystem.getDirectoryItems then
      return love.filesystem.getDirectoryItems("mods/FORTUNES_FAVOR/assets/tickets")
    end
    return nil
  end)
  if okList and type(listed) == "table" then
    for _, n in ipairs(listed) do
      if type(n) == "string" and n:lower():match("%.png$") then names[#names + 1] = n end
    end
  end
  table.sort(names)

  for _, n in ipairs(names) do
    local rel = "assets/tickets/" .. n
    local path = rel
    if mod and mod.assets and mod.assets.path then
      local okP, p = pcall(function() return mod.assets:path(rel) end)
      if okP and type(p) == "string" and p ~= "" then path = p end
    end
    local okI, img = pcall(love.graphics.newImage, path)
    if okI and img then
      -- Nearest, always. These are pixel art and any smoothing turns a
      -- hand-placed edge into mush.
      pcall(function() img:setFilter("nearest", "nearest") end)
      images[#images + 1] = img
    end
  end
  return images
end

--- Called when a ticket is scratched: choose the art for this one.
function M.begin(mod, random)
  local imgs = load(mod)
  if #imgs == 0 then M.stop(); return false end
  local i
  if type(random) == "function" then
    local ok, n = pcall(random, 1, #imgs)
    i = (ok and type(n) == "number") and n or 1
  else
    i = 1
  end
  if i < 1 or i > #imgs then i = 1 end
  shown = imgs[i]
  owner = nil
  until_ = now() + M.HOLD_SECONDS
  return true
end

function M.active()
  if shown ~= nil and now() < until_ then return true end
  M.stop()
  return false
end

function M.stop()
  shown = nil
  owner = nil
  until_ = 0
end

-- Centred in AREA, and never scaled UP past an integer multiple: a pixel
-- doubled is still pixel art, a pixel at 1.4x is not. Scaled DOWN only if it
-- genuinely does not fit, which is a warning sign about the source size
-- rather than something to make look good.
local function place(img)
  local iw, ih = img:getWidth(), img:getHeight()
  if iw <= 0 or ih <= 0 then return nil end
  local a = M.AREA
  local s = math.min(a.w / iw, a.h / ih)
  if s >= 1 then s = math.floor(s) end          -- integer up-scale only
  if s <= 0 then s = math.min(a.w / iw, a.h / ih) end
  local dw, dh = iw * s, ih * s
  return a.x + (a.w - dw) * 0.5, a.y + (a.h - dh) * 0.5, s
end

--- Wrap ListMenu:draw so the bag that owns a scratch shows the ticket while
--- its result messages are on screen.
function M.install(ListMenu, mod, log)
  if wrapped then return false end
  if type(ListMenu) ~= "table" or type(ListMenu.draw) ~= "function" then
    return false
  end
  if ListMenu.__fortunesFavorTicketArt then return false end

  -- Is a message box (or anything) sitting on top of this list? That is the
  -- real "the scratch is still on screen" signal, and it costs nothing:
  -- ListMenu already keeps `self.game.stack` and compares against it
  -- (ListMenu.lua:204-206). When the messages finish, the list becomes the
  -- top of the stack again and the art stops -- no timer guessing.
  local function messagesUp(self)
    local ok, covered = pcall(function()
      local g = self and self.game
      local st = g and g.stack
      if not (st and st.top) then return nil end
      return st:top() ~= self
    end)
    if not ok or covered == nil then return nil end   -- unknown
    return covered
  end

  local function isBag(self)
    return type(self) == "table"
      and (self.kind == "bag" or self.__usefulBagKind == "bag")
  end

  local inner = ListMenu.draw
  ListMenu.draw = function(self, ...)
    if not (M.active() and isBag(self)) then
      return inner(self, ...)
    end
    local covered = messagesUp(self)
    -- The list is the top screen: the scratch messages are gone, so stop.
    -- This is what retires the art, rather than HOLD_SECONDS -- that is only
    -- a backstop for a stack we could not read.
    if covered == false and (owner == nil or owner == self) then
      M.stop()
      return inner(self, ...)
    end

    -- Unknown stack state is never permission to paint a modal. Likewise,
    -- once one bag has claimed this scratch, no other list can inherit it.
    if covered ~= true or (owner ~= nil and owner ~= self) then
      return inner(self, ...)
    end
    owner = self

    -- The stock Gen 1 bag is deliberately a floating item box over the map.
    -- A scratch is a modal, though: first provide a complete paper layer so
    -- there are no world-colored strips around the ticket or text box. The
    -- normal bag then draws on top, preserving its classic frame and labels.
    pcall(function()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, 160, 144)
    end)

    -- Stock draw first: it paints the background and the title, so a fault
    -- below can never leave a half-drawn menu.
    local ok = pcall(inner, self, ...)
    if not ok then return end

    pcall(function()
      local img = shown
      if not img then return end
      local x, y, s = place(img)
      if not x then return end
      local a = M.AREA
      -- CLEAR THE AREA FIRST.
      --
      -- The engine's empty-list text lands at (16, 64) -- inside AREA but
      -- LEFT of a centred ticket, which starts at x=38 for an 83-wide image.
      -- Painting the ticket on top therefore left "Not..." poking out of its
      -- left edge. It also covers a non-empty item list, which is what makes
      -- the art appear on every scratch instead of only when the bag empties.
      -- White, because that is what ListMenu:draw fills the screen with.
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", a.x, a.y, a.w, a.h)
      local drawX, drawY = math.floor(x), math.floor(y)
      love.graphics.draw(img, drawX, drawY, 0, s, s)
      -- Ticket PNGs are authored RGB art, not four-shade cartridge pixels.
      -- The normal UI zone pass deliberately colorizes everything on the
      -- 160x144 canvas; record this 1x ticket so Renderer replays its original
      -- pixels after that pass and before DECK_TILT receives final output.
      local okPalette, PaletteFX = pcall(require, "src.render.PaletteFX")
      if okPalette and PaletteFX and s == 1
          and type(PaletteFX.markUiSpriteRedraw) == "function" then
        pcall(PaletteFX.markUiSpriteRedraw, img, nil, drawX, drawY)
      end
      love.graphics.setColor(0, 0, 0, 1)   -- Font.draw's expected state
    end)
  end

  ListMenu.__fortunesFavorTicketArt = true
  wrapped = true

  -- StateStack emits screen.popped AFTER removal, so the newly revealed top
  -- is authoritative. This retires the art even when Useful Bag hides the
  -- native owner and its ListMenu:draw wrapper never runs again.
  if mod and mod.events and type(mod.events.on) == "function" then
    mod.events:on("screen.popped", function(ev)
      if not M.active() then return end
      local state = ev and ev.state
      if state == owner or isBag(state) then
        M.stop()
        return
      end
      local list = owner
      local stack = list and list.game and list.game.stack
      if stack and type(stack.top) == "function" then
        local ok, top = pcall(stack.top, stack)
        if ok and top == list then M.stop() end
      end
    end)
  end
  if log then log:info("ticket art installed (%d image(s))", #load(mod)) end
  return true
end

function M.count(mod) return #load(mod) end
function M.installed() return wrapped end

return M
