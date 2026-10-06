-- Yellow Legacy V1.0.10 release behavior, not inferred design intent.
-- ROM SHA1 2ac87de42afc70ef6016805acb3b206644417f97; source 3a5358e8.
-- Its shipped selector overwrites A before comparing ULTRA/SAFARI, leaving
-- HP factor 4 for ALL ordinary balls. Master remains automatic. Base rates,
-- status bonuses, ball random ranges, and bait/rock catch-rate math are stock.
local LegacyCapture = {}
local stockHP = { POKE_BALL = 12, GREAT_BALL = 8,
                  ULTRA_BALL = 12, SAFARI_BALL = 12 }

function LegacyCapture.ballDefinition(ball, def)
  local stock = stockHP[ball]
  -- Do not replace another mod's custom attempt or custom ball arithmetic.
  -- Already-4 is a no-op: copying/multiplying repeatedly never stacks buffs.
  if not stock or type(def) ~= "table" or def.attempt or def.autoCatch
      or def.hpFactor == 4
      or (def.hpFactor ~= nil and def.hpFactor ~= stock) then return def end
  local out = {}
  for key, v in pairs(def) do out[key] = v end
  out.hpFactor = 4
  return out
end

function LegacyCapture.fleeThreshold(battle, threshold)
  local speed = battle.enemy.curStats.speed % 256
  -- The engine handles the speed>127 automatic-flee check before this seam.
  if speed > 127 then return threshold end
  local stock, legacy = speed * 2, speed * 2
  if battle.baitFactor > 0 then
    stock, legacy = math.floor(stock / 4), math.floor(legacy / 8)
  end
  if battle.escapeFactor > 0 then
    stock = math.min(255, stock * 2)
    legacy = math.min(255, legacy + math.floor(legacy / 2))
  end
  -- Respect unrelated custom thresholds; assigning the target is idempotent.
  if threshold ~= stock and threshold ~= legacy then return threshold end
  return legacy
end

function LegacyCapture.install(mod, enabled)
  mod.hooks:wrap("battle.ball.definition", function(next, battle, ball, def)
    local resolved = next(battle, ball, def)
    if not enabled() then return resolved end
    return LegacyCapture.ballDefinition(ball, resolved)
  end, -10)
  mod.hooks:wrap("battle.safari.flee_threshold", function(next, battle, threshold)
    local resolved = next(battle, threshold)
    if not enabled() then return resolved end
    return LegacyCapture.fleeThreshold(battle, resolved)
  end, -10)
end

return LegacyCapture
