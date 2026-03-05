--
-- AdvancedSilageFermentation
-- Author: Racc00n
-- Version: 0.0.0.1
--

AdvancedSilageFermentation = {}
local ASF                  = AdvancedSilageFermentation

ASF.modName                = g_currentModName or "AdvancedSilageFermentation"
ASF.dir                    = g_currentModDirectory

ASF.DEBUG                  = true

-- ------------------------------------------------------------------
-- Logging
-- ------------------------------------------------------------------
local function asfPrint(fmt, ...)
  if ASF.DEBUG then
    print(string.format("[ASF] " .. fmt, ...))
  end
end
-- ------------------------------------------------------------------
-- Utility: time + bunker data helpers
-- ------------------------------------------------------------------
function ASF:getCurrentHour()
  local mission = g_currentMission
  if mission ~= nil and mission.environment ~= nil then
    local env = mission.environment

    if env.currentDay ~= nil and env.currentHour ~= nil then
      return env.currentDay * 24 + env.currentHour
    elseif env.currentHour ~= nil then
      return env.currentHour
    elseif env.dayTime ~= nil then
      -- dayTime is ms since midnight of current day
      return env.dayTime / (60 * 60 * 1000)
    end
  end

  return 0
end

-- ------------------------------------------------------------------
-- Vehicle helpers (ported from Chowkidar mass logic)
-- ------------------------------------------------------------------
function ASF:findControlledVehicle()
  local controlledVehicle = nil


  if g_localPlayer ~= nil then
    controlledVehicle = g_localPlayer:getCurrentVehicle()
  end

  return controlledVehicle
end

function ASF:getVehicleMassTons(vehicle)
  if vehicle == nil then
    return 0
  end

  local massTons = 0.0

  -- Method A: physics mass
  if vehicle.getTotalMass ~= nil then
    local mKg = vehicle:getTotalMass(true) or 0
    massTons = mKg / 1000
  end

  local function getBaseMassTons(v)
    local mTons = 0

    if v.configFileName ~= nil and g_storeManager ~= nil then
      local item = g_storeManager:getItemByXMLFilename(v.configFileName)
      if item ~= nil and item.weight ~= nil then
        mTons = item.weight / 1000
      elseif v.defaultMass ~= nil then
        mTons = v.defaultMass
      end
    elseif v.defaultMass ~= nil then
      mTons = v.defaultMass
    end

    if v.getMassOfFillUnits ~= nil then
      mTons = mTons + (v:getMassOfFillUnits() or 0) / 1000
    end

    return mTons
  end

  -- Fallback: base mass + payload + attached tools
  if massTons < 0.01 then
    massTons = getBaseMassTons(vehicle)

    if vehicle.getAttachedImplements ~= nil then
      for _, impl in pairs(vehicle:getAttachedImplements()) do
        if impl.object ~= nil then
          massTons = massTons + getBaseMassTons(impl.object)
        end
      end
    end
  end

  return massTons
end

function ASF:getOrCreateBunkerData(bunker)
  if bunker == nil then
    return nil
  end

  -- Attach data directly onto the bunker instance so other scripts can
  -- access it as bunker.asfAdvancedSilage.* without going through ASF.
  local extra = bunker.asfAdvancedSilage
  if extra == nil then
    extra = {
      cycleId                  = 0,
      createdAtHour            = 0,
      sealedAtHour             = 0,
      fermentedAtHour          = 0,
      openedAtHour             = 0,

      totalGrassAdded          = 0,
      totalSilageRemoved       = 0,

      avgMoisture              = 0,

      -- Public scores used by the rest of the mod
      compactionScore          = 0,
      fermentationScore        = 0,
      oxygenDamage             = 0,

      qualityScore             = 0,

      -- Internal compaction model state
      cumulativeCompactionWork = 0, -- total “effective” work applied
      compactionDamage         = 0, -- 0–1, damage from over-driving
      lastCompactionHour       = 0,
      lastCompactorId          = 0
    }

    bunker.asfAdvancedSilage = extra
  end

  return extra
end

function ASF:updateQualityScore(bunker, extra)
  if extra == nil then
    return
  end

  local comp       = extra.compactionScore
  local compDamage = extra.compactionDamage
  local ferm       = extra.fermentationScore
  local oxy        = extra.oxygenDamage

  -- Very simple placeholder model for now
  local score      = (comp * 0.4) + (ferm * 0.5) - (oxy * 0.3) - (compDamage * 0.2)

  if score < 0 then
    score = 0
  elseif score > 1 then
    score = 1
  end

  extra.qualityScore = score
end

-- ------------------------------------------------------------------
-- Compaction gain from mass, speed, moisture (used by addCompactionFromVehicle / updateCompacting)
-- Modifies extra.compactionScore in place. Call on server only.
-- ------------------------------------------------------------------
function ASF.calculateCompactionGain(vehicleMass, speedKmh, avgMoisture, dt, extra)
  if extra == nil or dt <= 0 then
    return
  end

  -- Weight factor: ideal 12,000 kg; below = less effective, above = diminishing; clamp [0.2, 2.0]
  local weightFactor = vehicleMass / 12000
  weightFactor = math.max(0.2, math.min(2.0, weightFactor))

  -- Speed factor: optimal 4–8 km/h; below 3 = inefficient; above 14 = strongly reduced; above 18 = almost none
  local speedFactor
  local speedCompactionDamage = 0
  if speedKmh < 3 then
    speedFactor = 0.3 + (speedKmh / 3) * 0.2
    speedCompactionDamage = 1
  elseif speedKmh < 4 then
    speedFactor = 0.5 + (speedKmh - 3) * 0.5
    speedCompactionDamage = speedCompactionDamage + 0.1
  elseif speedKmh <= 8 then
    speedFactor = 1.0
  elseif speedKmh <= 14 then
    speedFactor = 1.0 - (speedKmh - 8) / 6 * 0.7
    speedCompactionDamage = speedCompactionDamage + 0.1
  elseif speedKmh <= 18 then
    speedFactor = 0.3 - (speedKmh - 14) / 4 * 0.25
    speedCompactionDamage = speedCompactionDamage + 0.2
  else
    speedFactor = 0.05
  end
  speedFactor = math.max(0, math.min(1, speedFactor))

  extra.compactionDamage = speedCompactionDamage

  -- Moisture factor: ideal 0.30–0.40; too dry <0.25 or very wet >0.55 reduces; clamp [0.5, 1.0]
  local moistureFactor
  if avgMoisture < 0.25 then
    moistureFactor = 0.5 + (avgMoisture / 0.25) * 0.2
  elseif avgMoisture < 0.30 then
    moistureFactor = 0.7 + (avgMoisture - 0.25) / 0.05 * 0.3
  elseif avgMoisture <= 0.40 then
    moistureFactor = 1.0
  elseif avgMoisture <= 0.55 then
    moistureFactor = 1.0 - (avgMoisture - 0.40) / 0.15 * 0.15
  else
    moistureFactor = math.max(0.5, 0.85 - (avgMoisture - 0.55) * 0.7)
  end
  moistureFactor = math.max(0.5, math.min(1.0, moistureFactor))

  -- Gain = base * factors * dt * (1 - score) so compaction slows as score -> 1
  local baseGain = 0.12
  local currentScore = extra.compactionScore or 0
  local gain = baseGain * weightFactor * speedFactor * moistureFactor * dt * (1 - currentScore)
  extra.compactionScore = math.min(1.0, currentScore + gain - speedCompactionDamage)
end

-- ------------------------------------------------------------------
-- Vehicle-aware compaction model
-- ------------------------------------------------------------------
function ASF:addCompactionFromVehicle(bunker, vehicle, dt)
  if bunker == nil or vehicle == nil then
    return
  end

  local extra = ASF:getOrCreateBunkerData(bunker)
  if extra == nil then
    return
  end

  dt = (dt or 0) * 0.001
  if dt <= 0 then
    return
  end

  local massKg = ASF:getVehicleMassTons(vehicle) * 1000
  local speedKmh = 0
  if vehicle.getLastSpeed ~= nil then
    speedKmh = vehicle:getLastSpeed() * 3.6
  end
  local avgMoisture = extra.avgMoisture
  if avgMoisture == nil or avgMoisture <= 0 then
    avgMoisture = 0.65
  end

  ASF.calculateCompactionGain(massKg, speedKmh, avgMoisture, dt, extra)

  extra.lastCompactionHour = ASF:getCurrentHour() or 0
  if vehicle.id ~= nil then
    extra.lastCompactorId = vehicle.id
  end

  ASF:updateQualityScore(bunker, extra)
end

-- ------------------------------------------------------------------
-- Bunker hooks: lifecycle and fill tracking
-- ------------------------------------------------------------------
function ASF:bunkerSetState(superFunc, state, showNotification)
  local oldState = self.state

  local result   = superFunc(self, state, showNotification)

  local extra    = ASF:getOrCreateBunkerData(self)
  local hour     = ASF:getCurrentHour()

  if state == BunkerSilo.STATE_FILL then
    if oldState ~= BunkerSilo.STATE_FILL then
      -- Starting a new fill cycle; reset stats and bump cycleId
      if extra.cycleId == nil then
        extra.cycleId = 0
      end

      extra.cycleId = extra.cycleId + 1

      extra.createdAtHour = 0
      extra.sealedAtHour = 0
      extra.fermentedAtHour = 0
      extra.openedAtHour = 0

      extra.totalGrassAdded = 0
      extra.totalSilageRemoved = 0

      extra.avgMoisture = 0
      extra.compactionScore = 0
      extra.fermentationScore = 0
      extra.oxygenDamage = 0
      extra.qualityScore = 0

      extra.cumulativeCompactionWork = 0
      extra.compactionDamage = 0
      extra.lastCompactionHour = 0
      extra.lastCompactorId = 0
    end
  elseif state == BunkerSilo.STATE_CLOSED then
    if extra.sealedAtHour == 0 then
      extra.sealedAtHour = hour
    end
  elseif state == BunkerSilo.STATE_FERMENTED then
    if extra.fermentedAtHour == 0 then
      extra.fermentedAtHour = hour
    end
  elseif state == BunkerSilo.STATE_DRAIN then
    if extra.openedAtHour == 0 then
      extra.openedAtHour = hour
    end
  end


  asfPrint("State change %d -> %d | quality=%.2f",
    oldState, state, extra.qualityScore)

  ASF:updateQualityScore(self, extra)

  return result
end

function ASF:bunkerUpdate(superFunc, dt)
  local result = superFunc(self, dt)

  if self.state ~= BunkerSilo.STATE_FILL then
    return result
  end

  local vehicle = ASF:findControlledVehicle()
  if vehicle == nil then
    return result
  end

  local massTons = ASF:getVehicleMassTons(vehicle)
  if massTons < 0.1 then
    return result
  end

  ASF:addCompactionFromVehicle(self, vehicle, dt)

  return result
end

function ASF:bunkerUpdateFillLevel(superFunc)
  local extra = ASF:getOrCreateBunkerData(self)
  local oldFillLevel = self.fillLevel or 0

  superFunc(self)

  local newFillLevel = self.fillLevel or 0
  local delta = newFillLevel - oldFillLevel

  if delta > 0 and self.state == BunkerSilo.STATE_FILL then
    extra.totalGrassAdded = (extra.totalGrassAdded or 0) + delta
    -- avgMoisture is set only from discharge moisture tracking (applyBunkerMoistureFromDischarge), not from fill delta

    if oldFillLevel <= 0 and extra.createdAtHour == 0 then
      extra.createdAtHour = ASF:getCurrentHour()
    end
  end

  -- asfPrint("Grass added: +%.1f (total %.1f)",
  --   delta, extra.totalGrassAdded)
end

function ASF:bunkerUpdateCompacting(superFunc, compactedFillLevel)
  local extra = ASF:getOrCreateBunkerData(self)

  superFunc(self, compactedFillLevel)

  if self.compactedPercent ~= nil then
    -- Treat engine compactedPercent as a minimum floor for our own score,
    -- in case some compaction is applied without our vehicle hook.
    local floorScore = (self.compactedPercent or 0) / 100
    if floorScore > (extra.compactionScore or 0) then
      extra.compactionScore = floorScore
    end
  end

  ASF:updateQualityScore(self, extra)
end

function ASF:bunkerOnHourChanged(superFunc)
  superFunc(self)

  local extra = ASF:getOrCreateBunkerData(self)

  -- Fermentation progress (0–1)
  if self.fermentingPercent ~= nil then
    extra.fermentationScore = self.fermentingPercent
  end

  -- Oxygen damage accumulates after opening
  if self.state == BunkerSilo.STATE_DRAIN then
    local damage = (extra.oxygenDamage or 0) + 0.01
    if damage > 1 then
      damage = 1
    end
    extra.oxygenDamage = damage
  end

  asfPrint("Hour tick | ferm=%.2f oxy=%.2f quality=%.2f",
    extra.fermentationScore,
    extra.oxygenDamage,
    extra.qualityScore)

  ASF:updateQualityScore(self, extra)
end

function ASF:bunkerOnChangedFillLevelCallback(superFunc, vehicle, fillDelta, fillType, x, y, z)
  superFunc(self, vehicle, fillDelta, fillType, x, y, z)

  if fillDelta ~= nil and fillDelta < 0 then
    if self.state == BunkerSilo.STATE_DRAIN or self.state == BunkerSilo.STATE_FERMENTED then
      local extra = ASF:getOrCreateBunkerData(self)
      extra.totalSilageRemoved = (extra.totalSilageRemoved or 0) + (-fillDelta)
    end
  end
end

function ASF:findBunkerContainingPoint(worldX, worldZ)
  if g_currentMission == nil or g_currentMission.placeableSystem == nil then
    return nil
  end
  local placeables = g_currentMission.placeableSystem:getBunkerSilos()
  if placeables == nil then
    return nil
  end
  for _, placeable in ipairs(placeables) do
    local bunker = nil
    if placeable.spec_bunkerSilo ~= nil and placeable.spec_bunkerSilo.bunkerSilo ~= nil then
      bunker = placeable.spec_bunkerSilo.bunkerSilo
    elseif placeable.spec_multiBunkerSilo ~= nil and placeable.spec_multiBunkerSilo.bunkerSilos ~= nil and #placeable.spec_multiBunkerSilo.bunkerSilos > 0 then
      bunker = placeable.spec_multiBunkerSilo.bunkerSilos[1]
    end
    if bunker ~= nil and bunker.bunkerSiloArea ~= nil and bunker.state == BunkerSilo.STATE_FILL then
      local a = bunker.bunkerSiloArea
      local minX = math.min(a.sx, a.wx, a.hx)
      local maxX = math.max(a.sx, a.wx, a.hx)
      local minZ = math.min(a.sz, a.wz, a.hz)
      local maxZ = math.max(a.sz, a.wz, a.hz)
      if worldX >= minX and worldX <= maxX and worldZ >= minZ and worldZ <= maxZ then
        return bunker
      end
    end
  end
  return nil
end

-- Update bunker ASF moisture from a discharge (volume-weighted average).
function ASF:applyBunkerMoistureFromDischarge(bunker, vehicle, dischargeNode, liters, moistureSystem)
  if bunker == nil or vehicle == nil or liters <= 0 or moistureSystem == nil then
    return
  end
  local fillType = nil
  if vehicle.getDischargeFillType ~= nil then
    fillType = vehicle:getDischargeFillType(dischargeNode)
  end
  if fillType == nil then
    return
  end
  local sourceMoisture = moistureSystem:getObjectMoisture(vehicle.uniqueId, fillType)
  if sourceMoisture == nil then
    sourceMoisture = moistureSystem:getDefaultMoisture()
  end
  if sourceMoisture == nil then
    sourceMoisture = 0.65
  end
  local extra = ASF:getOrCreateBunkerData(bunker)
  extra.moistureSum = (extra.moistureSum or 0) + (sourceMoisture * liters)
  extra.totalLitersForMoisture = (extra.totalLitersForMoisture or 0) + liters
  if extra.totalLitersForMoisture > 0 then
    extra.avgMoisture = extra.moistureSum / extra.totalLitersForMoisture
  end
  asfPrint("Bunker moisture: +%.0f L @ %.2f -> avg %.2f", liters, sourceMoisture, extra.avgMoisture or 0)
end

function ASF:dischargeToGround(superFunc, dischargeNode, emptyLiters)
  -- Call original function
  local dischargedLiters, minDropReached, hasMinDropFillLevel = superFunc(self, dischargeNode, emptyLiters)

  -- Only track on server and if something was actually discharged
  -- Note: dischargedLiters is negative when discharging (e.g., -7 means 7 liters discharged)
  if not self.isServer or dischargedLiters == 0 then
    return dischargedLiters, minDropReached, hasMinDropFillLevel
  end

  local tracker = g_currentMission.groundPropertyTracker

  -- Get filltype
  local fillType = self:getDischargeFillType(dischargeNode)
  if fillType == nil then
    return dischargedLiters, minDropReached, hasMinDropFillLevel
  end

  -- Get moisture from vehicle's fillType if available
  local moistureSystem = g_currentMission.MoistureSystem
  local moisture = nil

  if moistureSystem and self.uniqueId then
    moisture = moistureSystem:getObjectMoisture(self.uniqueId, fillType)
  end

  -- Get discharge area coordinates
  local info = dischargeNode.info
  local sx, sy, sz = localToWorld(info.node, -info.width, 0, info.zOffset)
  local ex, ey, ez = localToWorld(info.node, info.width, 0, info.zOffset)

  -- Adjust Y to terrain if needed
  if info.limitToGround then
    sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz) + 0.1
    ey = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez) + 0.1
  else
    sy = sy + info.yOffset
    ey = ey + info.yOffset
  end

  -- Calculate center point for tracking
  local centerX = (sx + ex) / 2
  local centerZ = (sz + ez) / 2

  -- Apply bunker moisture from discharge
  local bunker = ASF:findBunkerContainingPoint(centerX, centerZ)
  if bunker ~= nil and moistureSystem ~= nil then
    ASF:applyBunkerMoistureFromDischarge(bunker, self, dischargeNode, math.abs(dischargedLiters), moistureSystem)
  end

  -- Calculate bounding box corners for tracking
  local length = info.length or 0
  local width = math.sqrt((ex - sx) ^ 2 + (ez - sz) ^ 2)

  -- Create corner coordinates for pile tracking
  -- Using simplified rectangle aligned with discharge direction
  local halfWidth = width / 2
  local halfLength = length / 2

  local corner1X = centerX - halfWidth
  local corner1Z = centerZ - halfLength
  local corner2X = centerX + halfWidth
  local corner2Z = centerZ - halfLength
  local corner3X = centerX - halfWidth
  local corner3Z = centerZ + halfLength

  -- Track the pile with moisture
  -- Use absolute value since dischargedLiters is negative
  tracker:addPile(
    corner1X, corner1Z,
    corner2X, corner2Z,
    corner3X, corner3Z,
    fillType,
    math.abs(dischargedLiters),
    { moisture = moisture }
  )

  -- Clean up moisture tracking if vehicle is now empty of this fillType
  if not moistureSystem:hasFillType(self.uniqueId, fillType) then
    moistureSystem:setObjectMoisture(self.uniqueId, fillType, nil)
  end

  return dischargedLiters, minDropReached, hasMinDropFillLevel
end

-- ------------------------------------------------------------------
-- Save/load helpers for bunker data persistence
-- ------------------------------------------------------------------
function ASF:saveBunkerDataToXML(xmlFile, key, bunker)
  if xmlFile == nil or key == nil or bunker == nil then
    return
  end

  local extra = bunker.asfAdvancedSilage
  if extra == nil then
    return
  end

  local asfKey = key .. ".asfAdvancedSilage"

  print("saveBunkerDataToXML", extra.compactionScore)

  setXMLFloat(xmlFile.xmlFile, asfKey .. "#compactionScore", extra.compactionScore or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#cumulativeCompactionWork", extra.cumulativeCompactionWork or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#compactionDamage", extra.compactionDamage or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#avgMoisture", extra.avgMoisture or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#sealedAtHour", extra.sealedAtHour or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#fermentedAtHour", extra.fermentedAtHour or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#openedAtHour", extra.openedAtHour or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#totalGrassAdded", extra.totalGrassAdded or 0)
  setXMLFloat(xmlFile.xmlFile, asfKey .. "#totalSilageRemoved", extra.totalSilageRemoved or 0)
end

function ASF:loadBunkerDataFromXML(xmlFile, key, bunker)
  if xmlFile == nil or key == nil or bunker == nil then
    return
  end

  -- unwrap xml id safely
  local xmlId = xmlFile
  if type(xmlFile) == "table" and xmlFile.xmlFile ~= nil then
    xmlId = xmlFile
  end

  local extra = ASF:getOrCreateBunkerData(bunker)
  local asfKey = key .. ".asfAdvancedSilage"

  local function get(name, default)
    local v = getXMLFloat(xmlId.xmlFile, asfKey .. "#" .. name)
    if v == nil then
      return default
    end
    return v
  end

  extra.compactionScore          = get("compactionScore", 0)
  extra.cumulativeCompactionWork = get("cumulativeCompactionWork", 0)
  extra.compactionDamage         = get("compactionDamage", 0)
  extra.avgMoisture              = get("avgMoisture", 0)
  extra.sealedAtHour             = get("sealedAtHour", 0)
  extra.fermentedAtHour          = get("fermentedAtHour", 0)
  extra.openedAtHour             = get("openedAtHour", 0)
  extra.totalGrassAdded          = get("totalGrassAdded", 0)
  extra.totalSilageRemoved       = get("totalSilageRemoved", 0)

  ASF:updateQualityScore(bunker, extra)
end

-- ------------------------------------------------------------------
-- PlaceableBunkerSilo save/load hooks
-- ------------------------------------------------------------------
function ASF:placeableBunkerSaveToXML(superFunc, xmlFile, key, usedModNames)
  superFunc(self, xmlFile, key, usedModNames)

  local spec = self.spec_bunkerSilo
  if spec ~= nil and spec.bunkerSilo ~= nil then
    ASF:saveBunkerDataToXML(xmlFile, key, spec.bunkerSilo)
  end
end

function ASF:placeableBunkerLoadFromXML(superFunc, xmlFile, key)
  local ret = superFunc(self, xmlFile, key)

  local spec = self.spec_bunkerSilo
  if spec ~= nil and spec.bunkerSilo ~= nil then
    ASF:loadBunkerDataFromXML(xmlFile, key, spec.bunkerSilo)
  end

  return ret
end

-- Hook into Dischargeable specialization
Dischargeable.dischargeToGround = Utils.overwrittenFunction(
  Dischargeable.dischargeToGround,
  ASF.dischargeToGround
)

Utils.overwrittenFunction(BunkerSilo.setState, ASF.bunkerSetState)
BunkerSilo.update = Utils.overwrittenFunction(BunkerSilo.update, ASF.bunkerUpdate)
BunkerSilo.updateFillLevel = Utils.overwrittenFunction(BunkerSilo.updateFillLevel, ASF.bunkerUpdateFillLevel)
BunkerSilo.updateCompacting = Utils.overwrittenFunction(BunkerSilo.updateCompacting, ASF.bunkerUpdateCompacting)
BunkerSilo.onHourChanged = Utils.overwrittenFunction(BunkerSilo.onHourChanged, ASF.bunkerOnHourChanged)
BunkerSilo.onChangedFillLevelCallback = Utils.overwrittenFunction(BunkerSilo.onChangedFillLevelCallback,
  ASF.bunkerOnChangedFillLevelCallback)

PlaceableBunkerSilo.saveToXMLFile =
    Utils.overwrittenFunction(
      PlaceableBunkerSilo.saveToXMLFile,
      ASF.placeableBunkerSaveToXML
    )

PlaceableBunkerSilo.loadFromXMLFile =
    Utils.overwrittenFunction(
      PlaceableBunkerSilo.loadFromXMLFile,
      ASF.placeableBunkerLoadFromXML
    )

-- ------------------------------------------------------------------
-- Mod event listener
-- ------------------------------------------------------------------
function ASF:loadMap()
  g_currentMission.ASF = self
  asfPrint("Loaded %s", ASF.modName)
end

function ASF:deleteMap()
  asfPrint("Unloaded %s", ASF.modName)
end

function ASF:consoleDumpSilos()
  print("===== ASF BUNKER DUMP =====")

  local placeables = g_currentMission.placeableSystem.placeables
  if not placeables then
    print("No placeables found!")
    return
  end

  for i, placeable in ipairs(placeables) do
    if placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
      local bunker = placeable.spec_bunkerSilo.bunkerSilo
      print(string.format("Placeable ID: %d | Name: %s", i, placeable:getName()))
      print("  Root node:", bunker.rootNode)
      print("  State:", bunker.state)
      print("  Fill level:", bunker.fillLevel)
      print("  Compacted percent:", bunker.compactedPercent)

      if bunker.asfAdvancedSilage then
        local asf = bunker.asfAdvancedSilage
        print("  --- ASF Advanced Silage Data ---")
        for k, v in pairs(asf) do
          print(string.format("    %s: %s", k, tostring(v)))
        end
      else
        print("  No ASF data present")
      end

      print("  -----------------------------")
    end
  end
end

-- Register console command
addConsoleCommand("asfDumpSilos", "Dump all bunker silos with ASF data", "consoleDumpSilos", ASF)

addModEventListener(ASF)
