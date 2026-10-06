-- Fortune's Favor -- WHAT THE PLAYER ACTUALLY HOLDS, at the finest
-- granularity this install can honestly answer, and one rung coarser every
-- time a piece of that answer is missing.
--
-- ------- why this file exists
--
-- The wild bias used to ask one question: `save.pokedex.owned[species]`.
-- That is the right question for a dex, and the wrong one for a COLLECTION.
-- Sprite Variety gives every creature one of ELEVEN cartridges' artwork and
-- Dramatic Shape gives it a finish, so a complete collection on this install
-- is 151 x 11 x 2 = 3,322 entries, of which 1,661 are shiny. Against that,
-- "owned" is a single bit that goes true the first time you catch any
-- Charizard at all and never moves again -- and at MISSINGNO, the tier whose
-- whole job is finishing a collection, a bias that switches itself off after
-- one Charizard is a bias that does nothing for the rest of the hunt.
--
-- ------- three granularities, and the ladder DOWN between them
--
-- Fortune's Favor must stand alone: the cartridge axis exists only because
-- Sprite Variety is installed and the finish axis only because Dramatic
-- Shape is. Neither is a dependency, so each is asked for and each absence
-- costs exactly one axis:
--
--   species_cartridge_finish  both reachable -- the real collection
--   species_finish            no Sprite Variety -- normal vs shiny only
--   species                   no shiny oracle either -- today's dex bit
--
-- Nothing here throws. Every reach into another mod is a pcall and every
-- failure lands one rung coarser, which is always a SAFE direction: a
-- coarser answer marks FEWER things missing, so the worst case is the bias
-- doing less than it could, never a species being leaned toward that the
-- player already finished.
--
-- ------- HELD, not SEEN
--
-- Sprite Variety persists a "seen" sidecar whose entries are permanent by
-- design. It is the wrong file for this question and reading it would be a
-- quiet, permanent bug: a Pokemon you met once and ran from would count as
-- collected and take itself off the lean forever. So this file derives
-- holdings the way that mod's own COLLECTION page does -- live, from the
-- party and the boxes, resolving each creature through the published
-- `classFor` -- and stores nothing.
--
-- ------- EXTENDED STORAGE, which used to be the hole in the middle of this
--
-- Sprite Variety's own storage vault holds up to 5,040 creatures beside the
-- save, and they are still the player's Pokemon: that mod's `Statics.held`
-- counts them for exactly that reason (lib/Statics.lua:114-133, "leaving it
-- out would restart the respawn for a species the player had already
-- finished and merely put away"). This file used to count only the party and
-- the boxes, and the consequence was not a rounding error -- it was the
-- completion hunt failing for precisely the player it is aimed at. A
-- collector who finishes a species and parks it in the vault never reaches
-- `shinyComplete`, so MISSINGNO's yield never fires and the tier behaves as
-- STARDUST forever. Same shape as the ladder inversion below: correct
-- arithmetic, dead feature.
--
-- ------- how the vault is reached, since `exports.api` cannot answer it
--
-- Sprite Variety publishes TWO handles: `exports.api` (the documented
-- third-party seam -- registerSet, listSets, classFor, listSources ...) and
-- `exports.lib`, the module namespace. `exports.api` has NO vault accessor
-- of any kind, and the live handle behind that mod's storage screen
-- (`vaultData`, `vaultAttach`) is a file-local upvalue that is not exported.
-- We may not edit that mod, so the vault is read the only published way
-- there is: `exports.lib.Vault`, its own storage module, driven exactly as
-- its own `vaultAttach` drives it --
--
--     Vault.pathsFor(SaveData, GameVersion) -> main, bak, tmp
--     Vault.fsFor(SaveData, love.filesystem) -> fs
--     Vault.load(fs, main, bak, tmp)         -> vault, status
--
-- with the ENGINE's `src.core.SaveData` and `src.core.GameVersion` supplying
-- the routing, not anything of Sprite Variety's internals. It is a READ. This
-- file never writes the vault, never holds it across a write of that mod's,
-- and a `refused` load (checksum mismatch, damaged file) is treated as no
-- vault at all -- i.e. today's live-only behaviour, which is the safe
-- direction, rather than folding in bytes that mod would not trust either.
--
-- ------- cost, measured rather than assumed
--
-- `snapshot` walks the party and every box and calls Sprite Variety's
-- resolver once per creature. That is ~250 calls on a full save, far too
-- much for a per-step encounter roll, so the result is cached behind a
-- wall-clock TTL. Holdings change when a creature is caught, evolved, boxed
-- or traded -- events measured in minutes -- and the only consumer is a
-- probability weight, so a fraction of a second of staleness is invisible.
--
-- The vault cannot ride that TTL. Measured on this machine with LuaJIT, a
-- FULL vault (5,040 creatures, 1.90 MB):
--
--     Vault.load  (parse + verify checksum)   250-340 ms
--     parse only, checksum skipped                70 ms
--     fs.read of the whole file                 0.75 ms
--     fold 5,040 through the real classFor      5.8 ms
--     fold 5,040 with no cartridge oracle       0.33 ms
--     merge the folded vault into the live one  0.008 ms
--
-- so re-reading per rebuild -- twice a second -- would cost more than the
-- entire frame budget, and re-reading per ROLL is off the table by three
-- orders of magnitude. The verified load is therefore done ONCE and the
-- FOLD is what is cached; the TTL rebuild pays only the 0.75 ms read that
-- proves the file has not changed, plus the 0.008 ms merge. A warm roll
-- inside the TTL pays nothing at all, as before.
--
-- The checksum is NOT skipped for the 70 ms. A damaged vault read without it
-- can only fail in the unsafe direction -- garbage marking a species
-- complete and switching the shiny force off -- and 250 ms once per session
-- is a price this pays once, where 70 ms would be paid for the same once.
--
-- ------- why the cache key is the file's BYTES and not its stat
--
-- The obvious key is size + modtime. This install runs PORTABLE, and the
-- filesystem `SaveData.persistenceFs` hands out there answers `getInfo` with
-- `{ type = "file" }` and nothing else -- no size, no modtime at all
-- (src/core/SaveData.lua:85-88). A stat-keyed cache would therefore never
-- notice a deposit on the very install this runs on, which is the silent
-- half of the bug this change exists to fix. So the key is the file text
-- itself: one 0.75 ms read, and LuaJIT's interning makes the comparison a
-- pointer test. That is the "widen the invalidation" the vault needed.

local Holdings = {}

-- Long enough that a step-by-step walk through grass never rebuilds it,
-- short enough that catching something is reflected before the player can
-- take many more steps.
local TTL = 0.5

-- ------- the pure half (no engine, no other mod, fully testable)

-- Fold a list of creatures into held[species] = { [setId or true] = {
--   normal = true?, shiny = true? } }.
--
-- `classOf(mon) -> setId or nil` and `isShiny(mon) -> bool or nil` are
-- injected. A nil from classOf collapses that creature onto the key `true`,
-- which is exactly the species_finish granularity; a nil from isShiny
-- collapses both finishes onto `normal`, which is species granularity. So
-- the same fold produces all three answers and the granularity is decided
-- by which oracles the caller could find.
--
-- The second return is HOW MANY creatures classOf actually answered for.
-- `snapshot` needs it, and the reason is the whole point of the ladder: the
-- key `true` this function falls back to is a key `wanted` and
-- `shinyComplete` never look at while a cartridge list is in force, so a
-- classOf that answers for NOBODY does not degrade the answer one rung, it
-- DELETES the player's collection. See `snapshot`.
function Holdings.fold(mons, classOf, isShiny)
  local held, resolved = {}, 0
  for _, mon in ipairs(mons or {}) do
    local species = type(mon) == "table" and mon.species
    if species ~= nil then
      local set = true
      if classOf then
        local ok, c = pcall(classOf, mon)
        if ok and c ~= nil then set = c; resolved = resolved + 1 end
      end
      local shiny = false
      if isShiny then
        local ok, s = pcall(isShiny, mon)
        if ok and s == true then shiny = true end
      end
      local bySpecies = held[species]
      if not bySpecies then bySpecies = {}; held[species] = bySpecies end
      local bySet = bySpecies[set]
      if not bySet then bySet = {}; bySpecies[set] = bySet end
      bySet[shiny and "shiny" or "normal"] = true
    end
  end
  return held, resolved
end

-- Fold `src` INTO `dst` and return `dst`.
--
-- Two folds of the same shape -- the live creatures and the vault's -- are
-- the same collection seen twice, so the union is the answer. Only ever
-- writes into `dst`: the vault fold is CACHED and shared across rebuilds, so
-- mutating it would let one rebuild's live creatures leak into the next.
function Holdings.merge(dst, src)
  for species, bySet in pairs(src or {}) do
    local d = dst[species]
    if not d then d = {}; dst[species] = d end
    for set, cell in pairs(bySet) do
      local dc = d[set]
      if not dc then dc = {}; d[set] = dc end
      if cell.normal then dc.normal = true end
      if cell.shiny then dc.shiny = true end
    end
  end
  return dst
end

-- Is any (cartridge, finish) cell of this species still empty?
--
-- `sets` is the cartridge list; an empty list means the cartridge axis does
-- not exist here and the single key `true` stands for "any artwork".
-- `finishes` is likewise {"normal","shiny"} or just {"normal"}.
--
-- A species the dex has never recorded is missing whatever the collection
-- says: you cannot have finished collecting something you have not met.
function Holdings.wanted(held, species, sets, finishes, dexOwned)
  if dexOwned ~= nil and not dexOwned then return true end
  local bySpecies = held[species]
  if not bySpecies then return true end
  local keys = (sets and #sets > 0) and sets or { true }
  for _, set in ipairs(keys) do
    local cell = bySpecies[set]
    for _, finish in ipairs(finishes) do
      if not (cell and cell[finish]) then return true end
    end
  end
  return false
end

-- Are ALL of this species' shinies held?
--
-- This is the question MISSINGNO's shiny force yields to, and it is
-- deliberately the strict one: holding a shiny Yellow Charizard does not
-- complete Charizard while ten other cartridges' shinies are unheld, so the
-- force stays on until the last of them lands. With no cartridge axis it
-- degrades to "is this species' shiny held at all", and with no shiny
-- oracle it answers false -- meaning "never yield", which leaves the tier
-- behaving exactly as it did before this file existed.
function Holdings.shinyComplete(held, species, sets, hasShinyAxis)
  if not hasShinyAxis then return false end
  local bySpecies = held[species]
  if not bySpecies then return false end
  local keys = (sets and #sets > 0) and sets or { true }
  for _, set in ipairs(keys) do
    local cell = bySpecies[set]
    if not (cell and cell.shiny) then return false end
  end
  return true
end

-- ------- the seam half

local function engineGame()
  local ok, Game = pcall(require, "src.core.Game")
  if ok and type(Game) == "table" then return Game end
  return nil
end

-- Every creature the player is holding right now: the party, then every box
-- the save carries, in whatever shape it carries them. Written to survive a
-- boxes table that is a list of lists, a map of named boxes, or a flat list,
-- because that shape is the engine's to change and a mod guessing it wrong
-- should lose creatures from a weighting, not throw.
local function heldMons(save)
  local out = {}
  local function take(list)
    if type(list) ~= "table" then return end
    for _, mon in pairs(list) do
      if type(mon) == "table" then
        if mon.species ~= nil then
          out[#out + 1] = mon
        else
          for _, inner in pairs(mon) do
            if type(inner) == "table" and inner.species ~= nil then
              out[#out + 1] = inner
            end
          end
        end
      end
    end
  end
  take(save and save.party)
  take(save and save.boxes)
  take(save and save.daycare and { save.daycare })
  return out
end

-- Dramatic Shape's shiny predicate, through its published exports handle.
-- Re-resolved every time, never cached as absent: load order is not ours to
-- choose and the mod may be switched off mid-session.
local function shinyOracle(mod)
  local ok, handle = pcall(function() return mod.find("DRAMATIC_SHAPE") end)
  if not (ok and handle and handle.exports and handle.exports.lib) then return nil end
  local okM, Shiny = pcall(handle.exports.lib.require, "Shiny")
  if not (okM and type(Shiny) == "table" and type(Shiny.isShiny) == "function") then
    return nil
  end
  return function(mon) return Shiny.isShiny(mon) == true end
end

-- Sprite Variety's PUBLISHED api (mod.exports.api, version 1): `listSets`
-- for the cartridge vocabulary and `classFor` for which one a creature
-- wears. Nothing here touches that mod's internals, its files, or its lib
-- namespace -- only the two entry points it documents for other mods.
local function cartridgeOracle(mod, game)
  local ok, handle = pcall(function() return mod.find("SPRITE_VARIETY") end)
  if not (ok and handle and handle.exports and handle.exports.api) then return nil end
  local api = handle.exports.api
  if type(api.listSets) ~= "function" or type(api.classFor) ~= "function" then
    return nil
  end
  local okL, list = pcall(api.listSets)
  if not (okL and type(list) == "table" and #list > 0) then return nil end
  local sets = {}
  for _, s in ipairs(list) do
    if type(s) == "table" and s.id ~= nil then sets[#sets + 1] = s.id end
  end
  if #sets == 0 then return nil end
  return sets, function(mon) return api.classFor(game, mon) end
end

-- ------- extended storage: the seam
--
-- Everything here is optional and every step is guarded. Any miss -- Sprite
-- Variety absent, an older version with no `Vault`, an engine without the
-- SaveData routing, an unreadable or refused file -- returns nil, and nil
-- means "live creatures only", which is exactly what this file did before.
local function svLib(mod)
  local ok, handle = pcall(function() return mod.find("SPRITE_VARIETY") end)
  if not (ok and handle and handle.exports and type(handle.exports.lib) == "table") then
    return nil
  end
  return handle.exports.lib
end

local function vaultSeam(mod)
  local SV = svLib(mod)
  if not SV then return nil end
  local Vault = SV.Vault
  if type(Vault) ~= "table" then return nil end
  if type(Vault.pathsFor) ~= "function" or type(Vault.fsFor) ~= "function"
     or type(Vault.load) ~= "function" then
    return nil
  end
  local okS, SaveData = pcall(require, "src.core.SaveData")
  if not (okS and type(SaveData) == "table") then return nil end
  -- GameVersion is what makes the path per-cartridge (red/blue/yellow). Its
  -- absence is survivable -- `pathsFor` pcalls the lookup and falls back to
  -- the active slot -- so it is asked for rather than required.
  local okG, GameVersion = pcall(require, "src.core.GameVersion")
  local okP, main, bak, tmp = pcall(Vault.pathsFor, SaveData,
                                    okG and GameVersion or nil)
  if not (okP and type(main) == "string" and main ~= "") then return nil end
  local okF, fs = pcall(Vault.fsFor, SaveData, love and love.filesystem)
  if not (okF and type(fs) == "table" and type(fs.getInfo) == "function") then
    return nil
  end
  return Vault, fs, main, bak, tmp
end

-- The stored creature list, or nil. Re-verified against the file's bytes on
-- every call and re-loaded only when they differ; `vaultGen` is bumped
-- whenever the list is replaced so the fold below knows to rebuild.
local vaultPath, vaultBytes, vaultList, vaultGen = nil, nil, nil, 0

local function vaultMons(mod)
  local Vault, fs, main, bak, tmp = vaultSeam(mod)
  if not Vault then return nil end
  local bytes = nil
  if type(fs.read) == "function" then
    local okI, info = pcall(fs.getInfo, main)
    if okI and info then
      local okR, text = pcall(fs.read, main)
      if okR and type(text) == "string" then bytes = text end
    end
  end
  -- `bytes == nil` is "there is no main file to fingerprint": either it does
  -- not exist yet (a save that has never opened storage) or this filesystem
  -- cannot hand us the text. Both are cacheable states -- the first is the
  -- common one and must not pay a load per rebuild -- and `Vault.load` is
  -- still asked once, because it can recover a vault from `.tmp` or `.bak`
  -- when the main file is the missing one.
  if main == vaultPath and bytes == vaultBytes then return vaultList end

  local okL, v = pcall(Vault.load, fs, main, bak, tmp)
  local mons = nil
  -- `refused` is Vault.load's own marker for "every copy failed verification"
  -- (lib/Vault.lua:538-540). The table it returns is EMPTY, and an empty
  -- vault is indistinguishable from a first run -- so counting it would
  -- silently report a damaged living dex as no dex at all. Treated as no
  -- vault instead, which leaves the bias on rather than switching it off.
  if okL and type(v) == "table" and type(v.mons) == "table" and not v.refused then
    mons = v.mons
  end
  vaultPath, vaultBytes, vaultList = main, bytes, mons
  vaultGen = vaultGen + 1
  return mons
end

-- ------- the RECORDED cartridge, which `classFor` alone cannot give us here
--
-- Eight is less than eleven. Shininess pins Defense, Speed and Special to 10
-- and leaves eight Attack values, so no function OF a creature's DVs can
-- produce more than eight distinct cartridges for a shiny -- and measured
-- across the whole DV space only SIX of the eleven bands admit a shiny at
-- all (SPRITE_VARIETY/lib/Statics.lua:137-158). That is precisely why that
-- mod stopped deriving the cartridge and started RECORDING it, in the Assign
-- sidecar beside the save.
--
-- `exports.api.classFor` returns the recorded set -- but only for creatures
-- Sprite Variety has BOUND, and that binding is keyed on the creature's own
-- table by identity (`assignBinding[mon]`, main.lua:1122-1124). The vault
-- tables we load are our own copies of the same bytes, so they are never in
-- it, and `classFor` would quietly answer with the DERIVED band instead.
--
-- Left there, the vault fix would be half a fix: an eleven-cartridge shiny
-- set parked in storage would come back as at most six bands and
-- `shinyComplete` would still never be true -- the exact dead feature this
-- change exists to revive, moved one step along rather than removed.
--
-- So the records are read and bound the same way that mod binds them, using
-- ITS OWN published modules and nothing else:
--
--     Seen.pathsFor / Seen.load  -> the sidecar's assignment records
--     Lineage.build(pokemon)     -> family roots, because a record is keyed
--                                   on the ROOT so it survives evolution
--     Assign.order(save, vault)  -> the fixed traversal the ordinals count in
--     Assign.bind(records, ...)  -> creature -> set id
--
-- `bind` is called with NO pending table, which is what makes it a pure read:
-- with `pending` nil it cannot write a record, so this can never author an
-- assignment or mark that mod's sidecar dirty.
--
-- The traversal is why the fold below is keyed on the LIVE composition as
-- well as on the vault: ordinals count within a fingerprint group across
-- party, boxes, day care AND vault in that order, so catching one more
-- creature that happens to share a stored one's DVs really does shift which
-- record belongs to which. 4.1 ms at a full vault, and only when something
-- moved.

local rootPokemon, rootMapCache = nil, nil

local function rootMap(SV, pokemon)
  if type(pokemon) ~= "table" then return nil end
  if rawequal(pokemon, rootPokemon) and rootMapCache then return rootMapCache end
  local Lineage = SV.Lineage
  if not (type(Lineage) == "table" and type(Lineage.build) == "function") then
    return nil
  end
  local ok, roots = pcall(Lineage.build, pokemon)
  if not (ok and type(roots) == "table") then return nil end
  rootPokemon, rootMapCache = pokemon, roots
  return roots
end

local seenPath, seenBytes, seenRecords, seenGen = nil, nil, nil, 0

-- The sidecar's assignment records, or nil. Cached on the file's bytes for
-- the same reason the vault is, and cheap either way: the records file is a
-- few kilobytes even at living-dex size.
local function assignRecords(mod)
  local SV = svLib(mod)
  local Seen = SV and SV.Seen
  if not (type(Seen) == "table" and type(Seen.pathsFor) == "function"
          and type(Seen.fsFor) == "function" and type(Seen.load) == "function") then
    return nil
  end
  local okS, SaveData = pcall(require, "src.core.SaveData")
  if not (okS and type(SaveData) == "table") then return nil end
  local okG, GameVersion = pcall(require, "src.core.GameVersion")
  local okP, main, bak, tmp = pcall(Seen.pathsFor, SaveData, okG and GameVersion or nil)
  if not (okP and type(main) == "string" and main ~= "") then return nil end
  local okF, fs = pcall(Seen.fsFor, SaveData, love and love.filesystem)
  if not (okF and type(fs) == "table" and type(fs.getInfo) == "function") then
    return nil
  end
  local bytes = nil
  if type(fs.read) == "function" then
    local okI, info = pcall(fs.getInfo, main)
    if okI and info then
      local okR, text = pcall(fs.read, main)
      if okR and type(text) == "string" then bytes = text end
    end
  end
  if main == seenPath and bytes == seenBytes then return seenRecords end
  local okL, _, _, sets = pcall(Seen.load, fs, main, bak, tmp)
  seenPath, seenBytes = main, bytes
  seenRecords = (okL and type(sets) == "table") and sets or nil
  seenGen = seenGen + 1
  return seenRecords
end

-- creature -> recorded set id, over the FULL traversal, or nil.
local function recordedBinding(mod, save, mons)
  local SV = svLib(mod)
  local Assign = SV and SV.Assign
  if not (type(Assign) == "table" and type(Assign.order) == "function"
          and type(Assign.bind) == "function") then
    return nil
  end
  local records = assignRecords(mod)
  if not (type(records) == "table" and next(records) ~= nil) then return nil end
  local Game = engineGame()
  local roots = rootMap(SV, Game and Game.data and Game.data.pokemon)
  local rootOf = roots and function(sp) return roots[sp] or sp end or nil
  local okO, order = pcall(Assign.order, save, { mons = mons })
  if not (okO and type(order) == "table") then return nil end
  local okB, binding = pcall(Assign.bind, records, order, rootOf, nil)
  if not (okB and type(binding) == "table") then return nil end
  return binding
end

-- The signature of everything OUTSIDE the vault that can move an ordinal.
-- Shaped after that mod's own `assignSignature` (main.lua:1042-1051).
local function liveSignature(save)
  local parts = { tostring(#((save and save.party) or {})) }
  for _, box in ipairs((save and save.boxes) or {}) do
    parts[#parts + 1] = tostring(#(box or {}))
  end
  parts[#parts + 1] = (save and type(save.daycare) == "table") and "d" or "-"
  return table.concat(parts, ".")
end

-- The vault folded at both granularities, cached. Returns fine, coarse,
-- resolved, count -- or nil when there is no readable vault.
--
-- BOTH folds are built in the one pass because the coarse one is what the
-- ladder below falls back to, and re-deriving it later would mean re-reading
-- a 1.9 MB file to get the creatures back. It costs 0.33 ms at full size.
local vFoldGen, vFoldKey = -1, nil
local vFine, vCoarse, vResolved, vCount, vRecorded = nil, nil, 0, 0, 0

local function vaultFold(mod, classOf, isShiny, save)
  local mons = vaultMons(mod)
  if not mons then return nil end
  -- Read the sidecar BEFORE the key is built. It is the cheap bytes-compare
  -- either way, and building the key off a stale `seenGen` was a real bug in
  -- the first draft of this file: a player who recorded a cartridge without
  -- otherwise moving a creature changed nothing the key could see, so the
  -- new record was never picked up at all.
  if classOf then pcall(assignRecords, mod) end
  local key = (classOf and "c" or "-") .. (isShiny and "s" or "-")
    .. "|" .. liveSignature(save) .. "|" .. tostring(seenGen)
  local stale = (vFoldGen ~= vaultGen) or (vFoldKey ~= key)
  -- An oracle that answered for NOBODY is an oracle that is not up, not an
  -- answer worth keeping -- see `snapshot`. Retried on the next rebuild,
  -- when Sprite Variety may have finished becoming `ready`.
  if not stale and classOf and vCount > 0 and vResolved == 0 then stale = true end
  if stale then
    local resolve = classOf
    local recorded = 0
    if classOf then
      -- The recorded set wins over the derived one, exactly as that mod's own
      -- resolver orders them (lib/Resolve.lua:262-266).
      local binding = recordedBinding(mod, save, mons)
      if binding then
        for _, mon in ipairs(mons) do
          if binding[mon] ~= nil then recorded = recorded + 1 end
        end
        resolve = function(mon)
          local rec = binding[mon]
          if rec ~= nil then return rec end
          return classOf(mon)
        end
      end
    end
    vFine, vResolved = Holdings.fold(mons, resolve, isShiny)
    vCoarse = classOf and Holdings.fold(mons, nil, isShiny) or vFine
    vCount, vRecorded = #mons, recorded
    vFoldGen, vFoldKey = vaultGen, key
  end
  return vFine, vCoarse, vResolved, vCount, vRecorded
end

local cache, cacheAt = nil, -1e9

-- WALL clock, which is what the TTL above is written in.
--
-- `os.clock` is PROCESS CPU TIME in LuaJIT, not elapsed time, and a vsynced
-- LOVE frame spends most of its wall second asleep -- so a 0.5 "second" TTL
-- measured on it is two to five real seconds of staleness, i.e. several more
-- steps through grass than the comment above promises. love.timer.getTime is
-- the monotonic wall clock and is what the rest of this install times with
-- (lib/TicketArt.lua's `now`); os.clock is only the headless fallback, where
-- the two agree closely enough and every test injects `now` anyway.
local function wallNow()
  if love and love.timer and love.timer.getTime then
    local ok, t = pcall(love.timer.getTime)
    if ok and type(t) == "number" then return t end
  end
  return os.clock()
end

-- ctx = { mod = mod }. Returns a snapshot table, or nil when there is no
-- save to read -- which every caller treats as "leave the vanilla behaviour
-- alone", the same way an unreadable dex always has.
function Holdings.snapshot(ctx, now)
  now = now or wallNow()
  if cache and (now - cacheAt) < TTL then return cache end

  local Game = engineGame()
  local save = Game and Game.save
  if type(save) ~= "table" then return nil end

  local mod = ctx and ctx.mod
  local isShiny = mod and shinyOracle(mod)
  local sets, classOf = nil, nil
  if mod then sets, classOf = cartridgeOracle(mod, Game) end

  local mons = heldMons(save)
  local held, resolved = Holdings.fold(mons, classOf, isShiny)

  -- ------- and everything parked in extended storage
  --
  -- Folded separately and CACHED (see `vaultFold`), then merged into the live
  -- fold rather than the other way round: the cached table is shared across
  -- rebuilds and must never take a live creature with it.
  local vaultFine, vaultCoarse, vaultResolved, vaultCount = nil, nil, 0, 0
  local vaultRecorded = 0
  if mod then
    local okV, a, b, c, d, e = pcall(vaultFold, mod, classOf, isShiny, save)
    if okV and a then
      vaultFine, vaultCoarse, vaultResolved, vaultCount = a, b, c or 0, d or 0
      vaultRecorded = e or 0
    end
  end

  -- ------- the rung down that was never actually taken
  --
  -- `classFor` answers nil for EVERY creature whenever Sprite Variety is
  -- installed but not `ready` (its own guard, main.lua:3962 -- true during
  -- boot and again after any set is registered or a setting changes), and
  -- `listSets` keeps answering the full eleven throughout. The fold then puts
  -- every creature on the coarse key `true` while `sets` still names eleven
  -- cartridges -- and `wanted` and `shinyComplete` only ever look up `sets`,
  -- so they read the coarse bucket as EMPTY.
  --
  -- Measured, before this: a player holding a genuinely finished CHARIZARD --
  -- all eleven cartridges in both finishes, twenty-two creatures -- came back
  -- `wanted = true, shinyComplete = false`. That is not one rung coarser, it
  -- is the collection deleted, and it breaks this file's own promise at the
  -- top that a coarser answer marks FEWER things missing and never leans
  -- toward a species the player already finished.
  --
  -- So the ladder is taken for real: an oracle that resolved nobody is an
  -- oracle that is not up, and the cartridge axis goes with it. Testing
  -- `resolved == 0` rather than pcall success is what catches the `ready`
  -- case, where every call SUCCEEDS and returns nil.
  --
  -- The vault counts on BOTH sides of that test. A player whose collection
  -- lives in extended storage has an almost-empty party, so `#mons` and
  -- `resolved` alone would answer for a handful of creatures while five
  -- thousand went unexamined -- and an empty party would drop the cartridge
  -- axis for a fully resolving oracle.
  if sets and (#mons + vaultCount) > 0 and (resolved + vaultResolved) == 0 then
    sets, classOf = nil, nil
    held = Holdings.fold(mons, nil, isShiny)
    if vaultCoarse then held = Holdings.merge(held, vaultCoarse) end
  elseif vaultFine then
    held = Holdings.merge(held, vaultFine)
  end

  local granularity = "species"
  if isShiny then
    granularity = sets and "species_cartridge_finish" or "species_finish"
  end

  local dex = save.pokedex
  local owned = (type(dex) == "table" and type(dex.owned) == "table") and dex.owned or nil
  local finishes = isShiny and { "normal", "shiny" } or { "normal" }

  cache = {
    granularity = granularity,
    sets = sets or {},
    hasShinyAxis = isShiny ~= nil,
    owned = owned,
    -- What extended storage contributed, so a device probe can prove the
    -- vault was really read rather than quietly skipped -- the failure this
    -- whole section exists to make impossible is one that looks identical to
    -- success from outside.
    extended = vaultCount,
    extendedRead = vaultFine ~= nil,
    -- how many of them wear a RECORDED cartridge rather than a derived one:
    -- the number that decides whether an eleven-cartridge shiny set parked in
    -- storage can ever read complete
    extendedRecorded = vaultRecorded,
    live = #mons,
    wanted = function(species)
      -- `owned[species]` is a BOOLEAN or absent, and both readings matter:
      -- `false` is "the dex has never recorded this", which `Holdings.wanted`
      -- short-circuits on. Folding it through `x and true or false or nil`
      -- turned every false back into nil and left that branch dead.
      local dexOwned = nil
      if owned then dexOwned = owned[species] and true or false end
      return Holdings.wanted(held, species, sets, finishes, dexOwned)
    end,
    shinyComplete = function(species)
      return Holdings.shinyComplete(held, species, sets, isShiny ~= nil)
    end,
  }
  cacheAt = now
  return cache
end

-- The heartbeat has no reason to call this, but catching something should
-- not wait out the TTL when a test wants determinism.
--
-- The vault caches go with it. They are keyed on the file's own bytes and
-- would be correct to keep, but a test that wants determinism wants ALL of
-- it, and the only cost of dropping them is one re-read the next rebuild
-- would have paid anyway if the file really had changed.
function Holdings.invalidate()
  cache, cacheAt = nil, -1e9
  vaultPath, vaultBytes, vaultList = nil, nil, nil
  seenPath, seenBytes, seenRecords = nil, nil, nil
  seenGen = seenGen + 1
  rootPokemon, rootMapCache = nil, nil
  vaultGen = vaultGen + 1
  vFoldGen, vFoldKey = -1, nil
  vFine, vCoarse, vResolved, vCount, vRecorded = nil, nil, 0, 0, 0
end

return Holdings
