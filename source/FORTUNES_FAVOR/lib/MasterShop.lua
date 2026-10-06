-- Opt-in ordinary Gen1 mart offers. No global item/stock/save mutation.
local M={ITEM='MASTER_BALL'}
local installed=false
local CLERKS={
 ViridianMart={TEXT_VIRIDIANMART_CLERK=true},PewterMart={TEXT_PEWTERMART_CLERK=true},
 CeruleanMart={TEXT_CERULEANMART_CLERK=true},VermilionMart={TEXT_VERMILIONMART_CLERK=true},
 LavenderMart={TEXT_LAVENDERMART_CLERK=true},FuchsiaMart={TEXT_FUCHSIAMART_CLERK=true},
 SaffronMart={TEXT_SAFFRONMART_CLERK=true},CinnabarMart={TEXT_CINNABARMART_CLERK=true},
 IndigoPlateauLobby={TEXT_INDIGOPLATEAULOBBY_CLERK=true},
 CeladonMart2F={TEXT_CELADONMART2F_CLERK1=true,TEXT_CELADONMART2F_CLERK2=true},
 CeladonMart4F={TEXT_CELADONMART4F_CLERK=true},
 CeladonMart5F={TEXT_CELADONMART5F_CLERK1=true,TEXT_CELADONMART5F_CLERK2=true},
}
function M.inventory(data)
 local stocks={};local pointers=data and data.text_pointers
 for map,keys in pairs(CLERKS)do for key in pairs(keys)do
  local entry=pointers and pointers[map]and pointers[map][key]
  if type(entry)=='table'and type(entry.mart)=='table'then stocks[entry.mart]=true end
 end end
 return stocks
end
function M.referencePrice(data)
 local maximum=0;local item
 for stock in pairs(M.inventory(data))do for _,id in ipairs(stock)do
  local def=data.items and data.items[id];local n=def and def.price
  -- Exclude our own offer from the reference; never use unsold internal prices.
  if id~=M.ITEM and type(n)=='number'and n>maximum and n<math.huge and n%1==0 then maximum=n;item=id end
 end end
 if maximum==0 or maximum%2~=0 then return nil,'reference price is absent or not exactly divisible by two'end
 return maximum/2,maximum,item
end
function M.new()
 local issued=setmetatable({},{__mode='k'});local api={}
 function api.offer(data,stock,enabled)
  if not enabled or not M.inventory(data)[stock]then return stock end
  if not(data.items and data.items[M.ITEM])then return stock end
  local price=M.referencePrice(data);if not price then return stock end
  local offered={}
  for k,v in pairs(stock)do if type(k)~='number'then offered[k]=v end end
  for _,id in ipairs(stock)do if id~=M.ITEM then offered[#offered+1]=id end end
  offered[#offered+1]=M.ITEM
  issued[offered]={data=data,price=price}
  return offered
 end
 function api.price(game,stock,id,base)
  local offer=issued[stock]
  if offer and game and game.data==offer.data and id==M.ITEM then return offer.price end
  return base
 end
 return api
end
function M.install(mod,enabled)
 local Shop=require('src.ui.ShopMenu');local inner=assert(Shop.new)
 if installed then return false end
 if not Shop.BUY_PRICE_HOOK then return nil,'engine buy-price seam unavailable'end
 local api=M.new()
 mod.hooks:wrap('shop.buy.price',function(next,game,stock,id,base)
  return api.price(game,stock,id,next(game,stock,id,base))
 end,-10)
 -- Register first: a rejecting sandbox must never leave an unpriced offer.
 Shop.new=function(game,stock,...)
  -- Loader.find reflects disabled/failed/rolled-back owners even though a
  -- Lua module-method wrapper itself may survive until the requested restart.
  local current=game.mods and game.mods.exports
  local active=current and current[mod.id]==mod.exports
    and type(mod.find)=='function'and mod.find(mod.id)~=nil
  return inner(game,api.offer(game.data,stock,active and enabled()),...)
 end
 installed=true
 return api
end
return M
