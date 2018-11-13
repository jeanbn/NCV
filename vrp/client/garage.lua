
local Garage = class("Garage", vRP.Extension)

-- METHODS

function Garage:__construct()
  vRP.Extension.__construct(self)

  -- init decorators
  DecorRegister("vRP.owner", 3)

  self.vehicles = {} -- map of vehicle model => veh id (owned vehicles)
  self.hash_models = {} -- map of hash => model

  self.save_interval = 30 -- seconds

  -- task: save vehicle states
  Citizen.CreateThread(function()
    while true do
      Citizen.Wait(self.save_interval*1000)

      local states = {}
      
      for model, veh in pairs(self.vehicles) do
        if IsEntityAVehicle(veh) then
          states[model] = self:getVehicleState(veh)
        end
      end

      self.remote._updateVehicleStates(states)
    end
  end)
end

-- veh: vehicle game id
-- return owner character id and model or nil if not managed by vRP
function Garage:getVehicleInfo(veh)
  if veh and DecorExistOn(veh, "vRP.owner") then
    local model = self.hash_models[GetEntityModel(veh)]
    if model then
      return DecorGetInt(veh, "vRP.owner"), model
    end
  end
end

-- spawn vehicle
-- one vehicle per model allowed at the same time
--
-- state: (optional) vehicle state (client)
-- pos: (optional) {x,y,z}, if not passed the vehicle will be spawned on the player (and will be put inside the vehicle)
-- return true if spawned (if not already out)
function Garage:spawnVehicle(model, state, pos) 
  local vehicle = self.vehicles[model]
  if not vehicle then
    -- load vehicle model
    local mhash = GetHashKey(model)

    local i = 0
    while not HasModelLoaded(mhash) and i < 10000 do
      RequestModel(mhash)
      Citizen.Wait(10)
      i = i+1
    end

    -- spawn car
    if HasModelLoaded(mhash) then
      local x,y,z
      if pos then
        x,y,z = table.unpack(pos)
      else
        x,y,z = vRP.EXT.Base:getPosition()
      end

      local nveh = CreateVehicle(mhash, x,y,z+0.5, 0.0, true, false)
      SetVehicleOnGroundProperly(nveh)
      SetEntityInvincible(nveh,false)
      if not pos then
        SetPedIntoVehicle(GetPlayerPed(-1),nveh,-1) -- put player inside
      end
      SetVehicleNumberPlateText(nveh, "P "..vRP.EXT.Identity.registration)
      SetEntityAsMissionEntity(nveh, true, true)
      SetVehicleHasBeenOwnedByPlayer(nveh,true)

      -- set decorators
      DecorSetInt(veh, "vRP.owner", vRP.EXT.Base.id)
      self.vehicles[model] = nveh -- mark as owned

      SetModelAsNoLongerNeeded(mhash)

      if state then
        self:setVehicleState(nveh, state)
      end

      vRP:triggerEvent("garageVehicleSpawn", model)
    end

    return true
  end
end

-- return true if despawned
function Garage:despawnVehicle(model)
  local veh = self.vehicles[model]
  if veh then
    vRP:triggerEvent("garageVehicleStore", model)

    -- remove vehicle
    SetVehicleHasBeenOwnedByPlayer(veh,false)
    SetEntityAsMissionEntity(veh, false, true)
    SetVehicleAsNoLongerNeeded(Citizen.PointerValueIntInitialized(veh))
    Citizen.InvokeNative(0xEA386986E786A54F, Citizen.PointerValueIntInitialized(veh))
    self.vehicles[model] = nil

    return true
  end
end

-- return map of veh => distance
function Garage:getNearestVehicles(radius)
  local r = {}

  local px,py,pz = vRP.EXT.Base:getPosition()

  local vehs = {}
  local it, veh = FindFirstVehicle()
  if veh then table.insert(vehs, veh) end
  local ok
  repeat
    ok, veh = FindNextVehicle(it)
    if ok and veh then table.insert(vehs, veh) end
  until not ok
  EndFindVehicle(it)

  for _,veh in pairs(vehs) do
    local x,y,z = table.unpack(GetEntityCoords(veh,true))
    local distance = GetDistanceBetweenCoords(x,y,z,px,py,pz,true)
    if distance <= radius then
      r[veh] = distance
    end
  end

  return r
end

-- return veh
function Garage:getNearestVehicle(radius)
  local veh

  local vehs = self:getNearestVehicles(radius)
  local min = radius+10.0
  for _veh,dist in pairs(vehs) do
    if dist < min then
      min = dist 
      veh = _veh 
    end
  end

  return veh 
end

-- try to re-own the nearest vehicle
function Garage:tryOwnNearestVehicle(radius)
  local veh = self:getNearestVehicle(radius)
  if veh then
    local cid, model = self:getVehicleInfo(veh)
    if cid and vRP.EXT.Base.cid == cid then
      self.vehicles[model] = veh
    end
  end
end

function Garage:fixNearestVehicle(radius)
  local veh = self:getNearestVehicle(radius)
  if IsEntityAVehicle(veh) then
    SetVehicleFixed(veh)
  end
end

function Garage:replaceNearestVehicle(radius)
  local veh = self:getNearestVehicle(radius)
  if IsEntityAVehicle(veh) then
    SetVehicleOnGroundProperly(veh)
  end
end

-- return model or nil
function Garage:getNearestOwnedVehicle(radius)
  self:tryOwnNearestVehicle(radius) -- get back network lost vehicles

  local px,py,pz = vRP.EXT.Base:getPosition()
  local min_dist
  local min_k
  for k,veh in pairs(self.vehicles) do
    local x,y,z = table.unpack(GetEntityCoords(veh,true))
    local dist = GetDistanceBetweenCoords(x,y,z,px,py,pz,true)

    if dist <= radius+0.0001 then
      if not min_dist or dist < min_dist then
        min_dist = dist
        min_k = k
      end
    end
  end

  return min_k
end

-- return ok,x,y,z
function Garage:getAnyOwnedVehiclePosition()
  for model,veh in pairs(self.vehicles) do
    if IsEntityAVehicle(veh) then
      local x,y,z = table.unpack(GetEntityCoords(v[2],true))
      return true,x,y,z
    end
  end

  return false
end

-- return x,y,z or nil
function Garage:getOwnedVehiclePosition(model)
  local veh = self.vehicles[model]
  if veh then
    return table.unpack(GetEntityCoords(veh,true))
  end
end

-- eject the ped from the vehicle
function Garage:ejectVehicle()
  local ped = GetPlayerPed(-1)
  if IsPedSittingInAnyVehicle(ped) then
    local veh = GetVehiclePedIsIn(ped,false)
    TaskLeaveVehicle(ped, veh, 4160)
  end
end

function Garage:isInVehicle()
  local ped = GetPlayerPed(-1)
  return IsPedSittingInAnyVehicle(ped) 
end

-- return model or nil if not in owned vehicle
function Garage:getInOwnedVehicleModel()
  local veh = GetVehiclePedIsIn(ped,false)
  local cid, model = self:getVehicleInfo(veh)
  if cid and cid == vRP.EXT.Base.cid then
    return model
  end
end

-- VEHICLE STATE

-- get vehicle customization
function Garage:getCustomization(veh)
  local custom = {}

  custom.colours = {GetVehicleColours(veh)}
  custom.extra_colours = {GetVehicleExtraColours(veh)}
  custom.plate_index = GetVehicleNumberPlateTextIndex(veh)
  custom.wheel_type = GetVehicleWheelType(veh)
  custom.window_tint = GetVehicleWindowTint(veh)
  custom.neons = {}
  for i=0,3 do
    custom.neons[i] = IsVehicleNeonLightEnabled(veh, i)
  end
  custom.neon_colour = {GetVehicleNeonLightsColour(veh)}
  custom.tyre_smoke_color = {GetVehicleTyreSmokeColor(veh)}

  for i=0,49 do
    custom["mod"..i] = GetVehicleMod(veh, i)
  end

  custom.turbo_enabled = IsToggleModOn(veh, 18)
  custom.smoke_enabled = IsToggleModOn(veh, 20)
  custom.xenon_enabled = IsToggleModOn(veh, 22)

  return custom
end

-- set vehicle customization (partial update per property)
function Garage:setCustomization(veh, custom)
  SetVehicleModKit(veh, 0)

  if custom.colours then
    SetVehicleColours(veh, table.unpack(custom.colours))
  end

  if custom.extra_colours then
    SetVehicleExtraColours(veh, table.unpack(custom.extra_colours))
  end

  if custom.plate_index then 
    SetVehicleNumberPlateTextIndex(veh, custom.plate_index)
  end

  if custom.wheel_type then
    SetVehicleWheelType(veh, custom.wheel_type)
  end

  if custom.window_tint then
    SetVehicleWindowTint(veh, custom.window_tint)
  end

  if custom.neons then
    for i=0,3 do
      SetVehicleNeonLightEnabled(veh, i, custom.neons[i])
    end
  end

  if custom.neon_colour then
    SetVehicleNeonLightsColour(veh, table.unpack(custom.neon_colour))
  end

  if custom.tyre_smoke_color then
    SetVehicleTyreSmokeColor(veh, table.unpack(custom.tyre_smoke_color))
  end

  for i=0,49 do
    local mod = custom["mod"..i]
    if mod then
      SetVehicleMod(veh, i, mod, false)
    end
  end

  if custom.turbo_enabled ~= nil then
    ToggleVehicleMod(veh, 18, custom.turbo_enabled)
  end

  if custom.smoke_enabled ~= nil then
    ToggleVehicleMod(veh, 20, custom.smoke_enabled)
  end

  if custom.xenon_enabled ~= nil then
    ToggleVehicleMod(veh, 22, custom.xenon_enabled)
  end
end

function Garage:getVehicleState(veh)
  return {
    customization = self:getCustomization(veh),
    health = GetEntityHealth(veh),
    dirt_level = GetVehicleDirtLevel(veh)
  }
end

function Garage:setVehicleState(veh, state)
  -- apply state
  if state.customization then
    self:setCustomization(veh, state.customization)
  end
  
  if state.health then
    SetEntityHealth(veh, state.health)
  end

  if state.dirt_level then
    SetVehicleDirtLevel(veh, state.dirt_level)
  end
end

-- VEHICLE COMMANDS

function Garage:vc_openDoor(model, door_index)
  local vehicle = self.vehicles[model]
  if vehicle then
    SetVehicleDoorOpen(vehicle,door_index,0,false)
  end
end

function Garage:vc_closeDoor(model, door_index)
  local vehicle = self.vehicles[model]
  if vehicle then
    SetVehicleDoorShut(vehicle,door_index)
  end
end

function Garage:vc_detachTrailer(model)
  local vehicle = self.vehicles[model]
  if vehicle then
    DetachVehicleFromTrailer(vehicle)
  end
end

function Garage:vc_detachTowTruck(model)
  local vehicle = self.vehicles[model]
  if vehicle then
    local ent = GetEntityAttachedToTowTruck(vehicle)
    if IsEntityAVehicle(ent) then
      DetachVehicleFromTowTruck(vehicle,ent)
    end
  end
end

function Garage:vc_detachCargobob(model)
  local vehicle = self.vehicles[model]
  if vehicle then
    local ent = GetVehicleAttachedToCargobob(vehicle)
    if IsEntityAVehicle(ent) then
      DetachVehicleFromCargobob(vehicle,ent)
    end
  end
end

function Garage:vc_toggleEngine(model)
  local vehicle = self.vehicles[model]
  if vehicle then
    local running = Citizen.InvokeNative(0xAE31E7DF9B5B132E,vehicle) -- GetIsVehicleEngineRunning
    SetVehicleEngineOn(vehicle,not running,true,true)
    if running then
      SetVehicleUndriveable(vehicle,true)
    else
      SetVehicleUndriveable(vehicle,false)
    end
  end
end

-- return true if locked, false if unlocked
function Garage:vc_toggleLock(model)
  local vehicle = self.vehicles[model]
  if vehicle then
    local veh = vehicle
    local locked = GetVehicleDoorLockStatus(veh) >= 2
    if locked then -- unlock
      SetVehicleDoorsLockedForAllPlayers(veh, false)
      SetVehicleDoorsLocked(veh,1)
      SetVehicleDoorsLockedForPlayer(veh, PlayerId(), false)
      return false
    else -- lock
      SetVehicleDoorsLocked(veh,2)
      SetVehicleDoorsLockedForAllPlayers(veh, true)
      return true
    end
  end
end

-- TUNNEL
Garage.tunnel = {}

function Garage.tunnel:setConfig(save_interval)
  self.save_interval = save_interval
end

function Garage.tunnel:registerModels(models)
  -- generate models hashes
  for model in pairs(models) do
    local hash = GetHashKey(model)
    if hash then
      self.hash_models[hash] = model
    end
  end
end

Garage.tunnel.spawnVehicle = Garage.spawnVehicle
Garage.tunnel.despawnVehicle = Garage.despawnVehicle
Garage.tunnel.fixNearestVehicle = Garage.fixNearestVehicle
Garage.tunnel.replaceNearestVehicle = Garage.replaceNearestVehicle
Garage.tunnel.getNearestOwnedVehicle = Garage.getNearestOwnedVehicle
Garage.tunnel.getAnyOwnedVehiclePosition = Garage.getAnyOwnedVehiclePosition
Garage.tunnel.getOwnedVehiclePosition = Garage.getOwnedVehiclePosition
Garage.tunnel.getInOwnedVehicleModel = Garage.getInOwnedVehicleModel
Garage.tunnel.ejectVehicle = Garage.ejectVehicle
Garage.tunnel.isInVehicle = Garage.isInVehicle
Garage.tunnel.vc_openDoor = Garage.vc_openDoor
Garage.tunnel.vc_closeDoor = Garage.vc_closeDoor
Garage.tunnel.vc_detachTrailer = Garage.vc_detachTrailer
Garage.tunnel.vc_detachTowTruck = Garage.vc_detachTowTruck
Garage.tunnel.vc_detachCargobob = Garage.vc_detachCargobob
Garage.tunnel.vc_toggleEngine = Garage.vc_toggleEngine
Garage.tunnel.vc_toggleLock = Garage.vc_toggleLock

vRP:registerExtension(Garage)
