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
-- Hook helpers
-- ------------------------------------------------------------------
function ASF.overwrite(targetTable, fnName, newFn)
  if targetTable == nil or targetTable[fnName] == nil then
    asfPrint("WARN: cannot overwrite %s.%s (not found)", tostring(targetTable), tostring(fnName))
    return false
  end
  targetTable[fnName] = Utils.overwrittenFunction(targetTable[fnName], newFn)
  asfPrint("Hooked overwrite: %s.%s", tostring(targetTable), tostring(fnName))
  return true
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
  local v = nil

  if g_currentMission ~= nil then
    v = g_currentMission.controlledVehicle

    if v == nil and g_currentMission.player ~= nil and g_currentMission.player.getCurrentVehicle ~= nil then
      v = g_currentMission.player:getCurrentVehicle()
    end
  end

  if v == nil and g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
    v = g_localPlayer:getCurrentVehicle()
  end

  if v ~= nil and v.getRootVehicle ~= nil then
    v = v:getRootVehicle()
  end

  return v
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

function ASF:randomizeMoisture(bunker, extra)
  -- Simple placeholder: 0–1 uniform
  local value = math.random()
  if value < 0 then
    value = 0
  elseif value > 1 then
    value = 1
  end
  return value
end

function ASF:updateQualityScore(bunker, extra)
  if extra == nil then
    return
  end

  local comp  = extra.compactionScore or 0
  local ferm  = extra.fermentationScore or 0
  local oxy   = extra.oxygenDamage or 0

  -- Very simple placeholder model for now
  local score = (comp * 0.4) + (ferm * 0.5) - (oxy * 0.3)

  if score < 0 then
    score = 0
  elseif score > 1 then
    score = 1
  end

  extra.qualityScore = score
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

  -- FS dt is in ms; convert to seconds for tuning
  dt = (dt or 0) * 0.001
  if dt <= 0 then
    return
  end

  ----------------------------------------------------------------------
  -- Vehicle inputs
  ----------------------------------------------------------------------
  -- Use Chowkidar-style mass (tons -> kg)
  local massTons = ASF:getVehicleMassTons(vehicle)
  local mass     = massTons * 1000 -- kg

  local speedMs  = 0
  if vehicle.getLastSpeed ~= nil then
    speedMs = vehicle:getLastSpeed()
  end
  local speedKmh       = speedMs * 3.6

  -- For now we ignore special compacter strength and rely purely on mass
  local compStrength   = 1.0

  ----------------------------------------------------------------------
  -- Factors
  ----------------------------------------------------------------------
  local massRef        = 10000 -- 10 t reference
  local massFactor     = math.min(mass / massRef, 2.0)

  local optimalSpeed   = 6.0                                         -- km/h
  local speedDiff      = math.abs(speedKmh - optimalSpeed)
  local speedFactor    = math.max(0, 1 - (speedDiff / optimalSpeed)) -- 0..1

  local overdriveSpeed = 15.0                                        -- km/h: above this is “too fast”
  local isOverdrive    = speedKmh > overdriveSpeed

  local moisture       = extra.avgMoisture or 0
  if moisture <= 0 then
    -- fallback if not sealed yet / not randomized
    moisture = 0.65
  end

  local optMoisture       = 0.65
  local moistDiff         = moisture - optMoisture
  -- parabola: optimal moisture = 1, farther away reduces efficiency
  local moistureFactor    = math.max(0.3, 1 - (moistDiff * moistDiff) / 0.09)

  -- Rough “layer thickness”: more material → smaller effect per pass
  local fillLevel         = bunker.fillLevel or 0
  local layerThickness    = math.max(0.5, fillLevel / 400000)

  ----------------------------------------------------------------------
  -- Raw work & diminishing returns
  ----------------------------------------------------------------------
  local baseWorkPerSecond = 1.0 -- master gain knob for tuning
  local rawWork           = baseWorkPerSecond * dt * compStrength * massFactor * speedFactor * moistureFactor

  if rawWork <= 0 then
    return
  end

  extra.cumulativeCompactionWork = (extra.cumulativeCompactionWork or 0) + rawWork

  -- diminishing returns: more total work → less efficient
  local alpha                    = 0.5
  local effFactor                = 1 / (1 + alpha * extra.cumulativeCompactionWork)

  local deltaScore               = (rawWork * effFactor) / layerThickness

  extra.compactionScore          = extra.compactionScore or 0
  extra.compactionScore          = math.max(0, math.min(1, extra.compactionScore + deltaScore))

  ----------------------------------------------------------------------
  -- Over-driving penalty
  ----------------------------------------------------------------------
  if isOverdrive then
    extra.compactionDamage = (extra.compactionDamage or 0) + dt * 0.02
    if extra.compactionDamage > 1 then
      extra.compactionDamage = 1
    end

    local penalty = dt * 0.01 * extra.compactionDamage
    extra.compactionScore = math.max(0, extra.compactionScore - penalty)
  end

  extra.lastCompactionHour = ASF:getCurrentHour() or 0
  if vehicle ~= nil and vehicle.id ~= nil then
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
      if extra.avgMoisture == 0 then
        extra.avgMoisture = ASF:randomizeMoisture(self, extra)
      end
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

  setXMLFloat(xmlFile, asfKey .. "#compactionScore", extra.compactionScore or 0)
  setXMLFloat(xmlFile, asfKey .. "#cumulativeCompactionWork", extra.cumulativeCompactionWork or 0)
  setXMLFloat(xmlFile, asfKey .. "#compactionDamage", extra.compactionDamage or 0)
  setXMLFloat(xmlFile, asfKey .. "#avgMoisture", extra.avgMoisture or 0)
  setXMLFloat(xmlFile, asfKey .. "#sealedAtHour", extra.sealedAtHour or 0)
  setXMLFloat(xmlFile, asfKey .. "#fermentedAtHour", extra.fermentedAtHour or 0)
  setXMLFloat(xmlFile, asfKey .. "#openedAtHour", extra.openedAtHour or 0)
  setXMLFloat(xmlFile, asfKey .. "#totalGrassAdded", extra.totalGrassAdded or 0)
  setXMLFloat(xmlFile, asfKey .. "#totalSilageRemoved", extra.totalSilageRemoved or 0)
end

function ASF:loadBunkerDataFromXML(xmlFile, key, bunker)
  if xmlFile == nil or key == nil or bunker == nil then
    return
  end

  local extra = ASF:getOrCreateBunkerData(bunker)
  local asfKey = key .. ".asfAdvancedSilage"

  local function get(name, default)
    local v = getXMLFloat(xmlFile, asfKey .. "#" .. name)
    if v == nil then
      return default
    end
    return v
  end

  extra.compactionScore          = get("compactionScore", extra.compactionScore or 0)
  extra.cumulativeCompactionWork = get("cumulativeCompactionWork", extra.cumulativeCompactionWork or 0)
  extra.compactionDamage         = get("compactionDamage", extra.compactionDamage or 0)
  extra.avgMoisture              = get("avgMoisture", extra.avgMoisture or 0)
  extra.sealedAtHour             = get("sealedAtHour", extra.sealedAtHour or 0)
  extra.fermentedAtHour          = get("fermentedAtHour", extra.fermentedAtHour or 0)
  extra.openedAtHour             = get("openedAtHour", extra.openedAtHour or 0)
  extra.totalGrassAdded          = get("totalGrassAdded", extra.totalGrassAdded or 0)
  extra.totalSilageRemoved       = get("totalSilageRemoved", extra.totalSilageRemoved or 0)

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

-- ------------------------------------------------------------------
-- Hook installation (with retry)
-- ------------------------------------------------------------------
function ASF:installHooks()
  local ok = true

  if BunkerSilo ~= nil then
    ok = ASF.overwrite(BunkerSilo, "setState", ASF.bunkerSetState) and ok
    ok = ASF.overwrite(BunkerSilo, "update", ASF.bunkerUpdate) and ok
    ok = ASF.overwrite(BunkerSilo, "updateFillLevel", ASF.bunkerUpdateFillLevel) and ok
    ok = ASF.overwrite(BunkerSilo, "updateCompacting", ASF.bunkerUpdateCompacting) and ok
    ok = ASF.overwrite(BunkerSilo, "onHourChanged", ASF.bunkerOnHourChanged) and ok
    ok = ASF.overwrite(BunkerSilo, "onChangedFillLevelCallback", ASF.bunkerOnChangedFillLevelCallback) and ok
  else
    ok = false
    asfPrint("WARN: BunkerSilo not loaded yet")
  end

  if PlaceableBunkerSilo ~= nil then
    ok = ASF.overwrite(PlaceableBunkerSilo, "saveToXMLFile", ASF.placeableBunkerSaveToXML) and ok
    ok = ASF.overwrite(PlaceableBunkerSilo, "loadFromXMLFile", ASF.placeableBunkerLoadFromXML) and ok
  else
    ok = false
    asfPrint("WARN: PlaceableBunkerSilo not loaded yet")
  end

  if ok then
    self._hooksInstalled = true
    asfPrint("ASF bunker + compacter hooks installed")
  end
end

-- ------------------------------------------------------------------
-- Mod event listener
-- ------------------------------------------------------------------
function ASF:loadMap()
  asfPrint("Loaded %s", ASF.modName)
  self._hooksInstalled = false
  self:installHooks()
end

function ASF:update(dt)
  -- Retry hooks a few frames in case load order is late
  if not self._hooksInstalled then
    self._retry = (self._retry or 0) + 1
    if self._retry < 200 then
      self:installHooks()
    end
  end
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
