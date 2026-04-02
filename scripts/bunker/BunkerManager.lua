BunkerManager = {}
BunkerManager_mt = Class(BunkerManager)

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function dist2(ax, az, bx, bz)
  local dx, dz = ax - bx, az - bz
  return dx * dx + dz * dz
end

function BunkerManager.new()
  local self = setmetatable({}, BunkerManager_mt)
  self.bunkerSealing = g_currentMission.AdvancedBunkerSealing
  self.config = g_currentMission.AdvancedBunkerSealing.config
  self.tracked = {}
  self.scanTimerMs = 0
  self.nextId = 1
  -- Parsed BunkerSealing.xml rows; loaded once before any bunker is touched.
  self.modSaveLoaded = false
  self.modSaveRows = nil

  return self
end

function BunkerManager:loadFromXmlFile()
  if self.modSaveLoaded then return end

  local mission = g_currentMission and g_currentMission.missionInfo
  if mission == nil then return end

  local savegameFolderPath = mission.savegameDirectory
  if savegameFolderPath == nil then
    savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(), mission.savegameIndex)
  end
  savegameFolderPath = savegameFolderPath .. "/"
  local path = savegameFolderPath .. AdvancedBunkerSealing.SaveKey .. ".xml"

  self.modSaveLoaded = true
  self.modSaveRows = {}

  if not fileExists(path) then return end

  local xmlFile = loadXMLFile(AdvancedBunkerSealing.SaveKey, path)
  local key = AdvancedBunkerSealing.SaveKey
  local i = 0

  while true do
    local bunkerKey = string.format("%s.bunker(%d)", key, i)
    if not hasXMLProperty(xmlFile, bunkerKey) then break end

    local puid = getXMLString(xmlFile, bunkerKey .. "#placeableUniqueId")
    local bidx = getXMLInt(xmlFile, bunkerKey .. "#bunkerIndex") or 1
    local areaSx = getXMLFloat(xmlFile, bunkerKey .. "#areaSx")
    local areaSz = getXMLFloat(xmlFile, bunkerKey .. "#areaSz")
    local bunkerId = getXMLInt(xmlFile, bunkerKey .. "#bunkerId")
    local sealEfficiency = getXMLFloat(xmlFile, bunkerKey .. "#sealEfficiency")
    local silageLoss = getXMLInt(xmlFile, bunkerKey .. "#silageLoss")
    local lossApplied = getXMLInt(xmlFile, bunkerKey .. "#lossApplied")
    local finalFillLevel = getXMLInt(xmlFile, bunkerKey .. "#finalFillLevel")
    local oxygen = getXMLFloat(xmlFile, bunkerKey .. "#oxygen")

    table.insert(self.modSaveRows, {
      puid = puid,
      bidx = bidx,
      areaSx = areaSx,
      areaSz = areaSz,
      bunkerId = bunkerId,
      sealEfficiency = sealEfficiency,
      silageLoss = silageLoss,
      lossApplied = lossApplied ~= 0,
      finalFillLevel = finalFillLevel,
      oxygen = oxygen
    })
    i = i + 1
  end
  delete(xmlFile)
end

-- Save the bunkers ids + our custom data to the xml file.
function BunkerManager:saveToXmlFile(xmlFile)
  if not g_currentMission:getIsServer() then return end

  local key = AdvancedBunkerSealing.SaveKey
  local count = 0

  for _, bunker in pairs(self.tracked) do
    local rowKey = string.format("%s.bunker(%d)", key, count)
    self:ensureBunkerSealingData(bunker)
    local d = bunker.bunkerSealing
    -- Live value is on d.seal.sealEfficiency (0..1); setXMLInt truncates floats to 0/1.
    local sealEff = (d.seal and d.seal.sealEfficiency) or d.sealEfficiency or 0

    local placeable, bidx = self:getPlaceableAndBunkerIndex(bunker)
    local area = bunker.bunkerSiloArea
    if placeable ~= nil and placeable.uniqueId ~= nil and placeable.uniqueId ~= "" then
      setXMLString(xmlFile, rowKey .. "#placeableUniqueId", placeable.uniqueId)
      setXMLInt(xmlFile, rowKey .. "#bunkerIndex", bidx)
    else
      setXMLString(xmlFile, rowKey .. "#placeableUniqueId", "")
      setXMLInt(xmlFile, rowKey .. "#bunkerIndex", 1)
    end
    if area ~= nil and area.sx ~= nil and area.sz ~= nil then
      setXMLFloat(xmlFile, rowKey .. "#areaSx", area.sx)
      setXMLFloat(xmlFile, rowKey .. "#areaSz", area.sz)
    end
    setXMLInt(xmlFile, rowKey .. "#bunkerId", bunker.id)

    setXMLFloat(xmlFile, rowKey .. "#sealEfficiency", sealEff)
    setXMLInt(xmlFile, rowKey .. "#silageLoss", d.silageLoss or 0)
    setXMLInt(xmlFile, rowKey .. "#lossApplied", d.lossApplied and 1 or 0)
    setXMLInt(xmlFile, rowKey .. "#finalFillLevel", d.finalFillLevel or 0)
    setXMLFloat(xmlFile, rowKey .. "#oxygen", d.oxygen or 0)

    count = count + 1
  end
end

function BunkerManager:ensureBunkerSealingData(bunker)
  if bunker == nil then return end

  self:loadFromXmlFile()

  if bunker.bunkerSealing == nil then
    bunker.bunkerSealing = {
      sealEfficiency = 0,
      silageLoss = 0,
      lossApplied = false,
      finalFillLevel = 0,
      oxygen = 1,
      seal = {}
    }
    if not bunker.bunkerSealing._restoredFromModSave then
      local placeable, pidx = self:getPlaceableAndBunkerIndex(bunker)
      local area = bunker.bunkerSiloArea
      for _, row in ipairs(self.modSaveRows or {}) do
        local match = false
        if row.puid ~= nil and row.puid ~= "" and placeable ~= nil and placeable.uniqueId == row.puid and (row.bidx or 1) == pidx then
          match = true
        elseif row.areaSx ~= nil and row.areaSz ~= nil and area ~= nil and area.sx ~= nil and area.sz ~= nil then
          if dist2(row.areaSx, row.areaSz, area.sx, area.sz) <= 4.0 then match = true end
        elseif row.bunkerId ~= nil and bunker.id == row.bunkerId then
          match = true
        end
        if match then
          bunker.bunkerSealing.sealEfficiency = row.sealEfficiency
          bunker.bunkerSealing.silageLoss = row.silageLoss
          bunker.bunkerSealing.lossApplied = row.lossApplied
          bunker.bunkerSealing.finalFillLevel = row.finalFillLevel
          bunker.bunkerSealing.oxygen = row.oxygen
          bunker.bunkerSealing._restoredFromModSave = true
          break
        end
      end
    end
  end
  if bunker.bunkerSealing.seal == nil then
    bunker.bunkerSealing.seal = {}
  end
  local seal = bunker.bunkerSealing.seal
  if bunker.bunkerSealing._restoredFromModSave and seal.sealEfficiency == nil then
    seal.sealEfficiency = bunker.bunkerSealing.sealEfficiency or 0
  end
  seal.cells = seal.cells or {}
  seal.cellPositions = seal.cellPositions or {}
  seal.baleCoveredCells = seal.baleCoveredCells or {}
  seal.cellHasMaterial = seal.cellHasMaterial or {}
  seal.cellCountLength = seal.cellCountLength or 0
  seal.cellCountWidth = seal.cellCountWidth or 0
  seal.sealedCount = seal.sealedCount or 0
  seal.tireWeight = seal.tireWeight or 0
  seal.baleWeight = seal.baleWeight or 0
  seal.coverWeight = seal.coverWeight or 0
  seal.sealEfficiency = seal.sealEfficiency or 0
  seal.initialFillLevel = seal.initialFillLevel or 0
end

function BunkerManager:ensureTracked(bunker)
  if bunker == nil or bunker.id == nil then return end
  self:ensureBunkerSealingData(bunker)
  self.tracked[bunker.id] = bunker
end

-- placeableSystem:getBunkerSilos() returns placeables; BunkerSilo objects are on specs.
function BunkerManager:collectBunkerSiloInstances()
  local out = {}
  local ps = g_currentMission and g_currentMission.placeableSystem
  if ps == nil or ps.getBunkerSilos == nil then return out end
  local placeables = ps:getBunkerSilos()
  if placeables == nil then return out end
  for _, placeable in ipairs(placeables) do
    if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
      for _, bs in ipairs(placeable.spec_multiBunkerSilo.bunkerSilos) do
        table.insert(out, bs)
      end
    elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
      table.insert(out, placeable.spec_bunkerSilo.bunkerSilo)
    end
  end
  return out
end

-- FS25 PlaceableSystem has no getBunkerSiloById; bunker ids match BunkerSilo.id on registered instances.
function BunkerManager:findBunkerSiloById(bunkerId)
  if bunkerId == nil then return nil end
  for _, bunker in ipairs(self:collectBunkerSiloInstances()) do
    if bunker.id == bunkerId then
      return bunker
    end
  end
  return nil
end

-- Parent placeable + index within it (1 = single-bunker placeable). BunkerSilo.id is not stable across loads.
function BunkerManager:getPlaceableAndBunkerIndex(bunker)
  if bunker == nil then return nil, 1 end
  local ps = g_currentMission and g_currentMission.placeableSystem
  if ps == nil or ps.getBunkerSilos == nil then return nil, 1 end
  for _, placeable in ipairs(ps:getBunkerSilos()) do
    if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
      for idx, bs in ipairs(placeable.spec_multiBunkerSilo.bunkerSilos) do
        if bs == bunker then return placeable, idx end
      end
    elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo == bunker then
      return placeable, 1
    end
  end
  return nil, 1
end

function BunkerManager:findBunkerSiloByPlaceableUniqueId(uniqueId, bunkerIndex)
  if uniqueId == nil or uniqueId == "" then return nil end
  bunkerIndex = bunkerIndex or 1
  local ps = g_currentMission and g_currentMission.placeableSystem
  if ps == nil or ps.getBunkerSilos == nil then return nil end
  for _, placeable in ipairs(ps:getBunkerSilos()) do
    if placeable.uniqueId == uniqueId then
      if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
        return placeable.spec_multiBunkerSilo.bunkerSilos[bunkerIndex]
      elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
        return placeable.spec_bunkerSilo.bunkerSilo
      end
    end
  end
  return nil
end

function BunkerManager:findBunkerSiloNearAreaOrigin(sx, sz, maxDist)
  maxDist = maxDist or 2.0
  local maxD2 = maxDist * maxDist
  local best, bestD2 = nil, nil
  for _, bunker in ipairs(self:collectBunkerSiloInstances()) do
    local area = bunker.bunkerSiloArea
    if area and area.sx and area.sz then
      local d2 = dist2(sx, sz, area.sx, area.sz)
      if d2 <= maxD2 and (bestD2 == nil or d2 < bestD2) then
        bestD2 = d2
        best = bunker
      end
    end
  end
  return best
end

function BunkerManager:syncTrackedFromPlaceables()
  if not g_currentMission or not g_currentMission:getIsServer() then return end
  for _, bunker in ipairs(self:collectBunkerSiloInstances()) do
    if bunker.state == BunkerSilo.STATE_CLOSED or bunker.state == BunkerSilo.STATE_FERMENTED then
      self:ensureTracked(bunker)
    end
  end
end

function BunkerManager:getOrCreateBunkerData(bunker)
  if bunker == nil then return nil end
  self:ensureBunkerSealingData(bunker)
  return bunker.bunkerSealing
end

-- Rebuild tracked after mission start; mod save rows are merged in ensureBunkerSealingData via loadModSaveFromDisk.
function BunkerManager:finishModLoadAfterMissionStart()
  if not g_currentMission:getIsServer() then return end

  self:loadFromXmlFile()
  self.tracked = {}
  self.nextId = 1
  self:syncTrackedFromPlaceables()
  for _, row in ipairs(self.modSaveRows) do
    local bunker = nil
    if row.puid ~= nil and row.puid ~= "" then
      bunker = self:findBunkerSiloByPlaceableUniqueId(row.puid, row.bidx)
    end
    if bunker == nil and row.areaSx ~= nil and row.areaSz ~= nil then
      bunker = self:findBunkerSiloNearAreaOrigin(row.areaSx, row.areaSz)
    end
    if bunker == nil then
      bunker = self:findBunkerSiloById(row.bunkerId)
    end
    if bunker ~= nil then
      self:ensureTracked(bunker)
    end
  end
end

function BunkerManager:getBunkerById(id)
  for _, bunker in pairs(self.tracked) do
    if bunker.id == id then
      return bunker
    end
  end
  return nil
end

function BunkerManager:ensureSealGrid(bunker)
  if bunker == nil then return end

  self:ensureBunkerSealingData(bunker)

  local area = bunker.bunkerSiloArea
  if area == nil then return end
  local seal = bunker.bunkerSealing.seal
  if seal.cellPositions ~= nil and #seal.cellPositions > 0 then return end

  local cellSize = self.config.gridCellSize
  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local length = math.sqrt(dhx * dhx + dhz * dhz)
  local width = math.sqrt(dwx * dwx + dwz * dwz)
  local countL = math.max(2, math.floor(length / cellSize + 0.5))
  local countW = math.max(2, math.floor(width / cellSize + 0.5))

  bunker.bunkerSealing.seal.cells = {}
  bunker.bunkerSealing.seal.cellPositions = {}
  bunker.bunkerSealing.seal.baleCoveredCells = {}
  bunker.bunkerSealing.seal.cellCountLength = countL
  bunker.bunkerSealing.seal.cellCountWidth = countW
  bunker.bunkerSealing.seal.sealedCount = 0

  local idx = 0
  for i = 0, countL - 1 do
    for j = 0, countW - 1 do
      idx = idx + 1
      bunker.bunkerSealing.seal.cells[idx] = false
      bunker.bunkerSealing.seal.baleCoveredCells[idx] = false
      local tLen = (i + 0.5) / countL
      local tWid = (j + 0.5) / countW
      local wx = area.sx + tLen * dhx + tWid * dwx
      local wz = area.sz + tLen * dhz + tWid * dwz
      local wy = self:getSurfaceYAtWorldXZ(wx, wz)
      bunker.bunkerSealing.seal.cellPositions[idx] = { x = wx, y = wy, z = wz }
    end
  end
end

function BunkerManager:updateCellMaterialMask(bunker)
  if not DensityMapHeightUtil or not DensityMapHeightUtil.getFillLevelAtArea then return end
  if bunker == nil or bunker.bunkerSealing == nil or bunker.bunkerSealing.seal == nil then return end

  local area = bunker.bunkerSiloArea
  local positions = bunker.bunkerSealing.seal.cellPositions
  if area == nil or positions == nil or #positions == 0 then return end

  local cellHasMaterial = bunker.bunkerSealing.seal.cellHasMaterial or {}
  bunker.bunkerSealing.seal.cellHasMaterial = cellHasMaterial

  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local countL = math.max(1, bunker.bunkerSealing.seal.cellCountLength or 1)
  local countW = math.max(1, bunker.bunkerSealing.seal.cellCountWidth or 1)
  local ax = dhx / countL
  local az = dhz / countL
  local bx = dwx / countW
  local bz = dwz / countW
  local minL = self.config.minCellFillLiters or 1.0
  local fillTypes = { bunker.fermentingFillType, bunker.outputFillType }

  for idx = 1, #positions do
    local pos = positions[idx]
    local wx, wz = pos.x, pos.z
    -- Small parallelogram around cell center (same orientation as bunker grid).
    local fx = ax * 0.35
    local fz = az * 0.35
    local gx = bx * 0.35
    local gz = bz * 0.35
    local x0 = wx - fx - gx
    local z0 = wz - fz - gz
    local x1 = wx + fx - gx
    local z1 = wz + fz - gz
    local x2 = wx - fx + gx
    local z2 = wz - fz + gz
    local liters = 0
    for _, ft in ipairs(fillTypes) do
      if ft ~= nil then
        liters = liters + DensityMapHeightUtil.getFillLevelAtArea(ft, x0, z0, x1, z1, x2, z2)
      end
    end
    cellHasMaterial[idx] = (liters >= minL)
  end
end

function BunkerManager:scanBunkerCover(bunker, bales)
  self:ensureSealGrid(bunker)
  self:updateCellMaterialMask(bunker)
  local positions = bunker.bunkerSealing.seal.cellPositions or {}
  local coveredByBale = bunker.bunkerSealing.seal.baleCoveredCells or {}

  bunker.bunkerSealing.seal.baleCoveredCells = coveredByBale
  for i = 1, #positions do
    coveredByBale[i] = false
  end

  local tireWeight = 0
  local baleWeight = 0
  local area = bunker.bunkerSiloArea
  local restingMin = self.config.baleRestingOffset.min
  local restingMax = self.config.baleRestingOffset.max
  local cellHasMaterial = bunker.bunkerSealing.seal.cellHasMaterial or {}

  for _, bale in ipairs(bales or {}) do
    -- Do not count bales currently grabbed/attached by tools/loaders.
    if not self:isBaleMountedOrAttached(bale) then
      local bx, by, bz = self:getObjectWorldPosition(bale)
      if bx ~= nil and bz ~= nil and self:isPointInBunkerArea(area, bx, bz) then
        local weight, radius, halfHeight = self:getBaleWeightData(bale)
        local baleCoverMult = self.config.baleCoverRadiusMultiplier or 1.0
        radius = radius * baleCoverMult
        local isRound = bale.isRoundbale == true or bale.isRoundBale == true
        local roundExtraDown = (self.config.roundBaleRestingExtraDown or 0)
        local restMin = restingMin - (isRound and roundExtraDown or 0)
        local surfaceY = self:getSurfaceYAtWorldXZ(bx, bz, 0)
        local bottomY = (by or surfaceY) - (halfHeight or 0.2)
        if bottomY >= surfaceY + restMin and bottomY <= surfaceY + restingMax then
          local radius2 = radius * radius
          local baleOverlapsMaterial = false
          for i, pos in ipairs(positions) do
            local dx = pos.x - bx
            local dz = pos.z - bz
            if dx * dx + dz * dz <= radius2 then
              coveredByBale[i] = true
              if cellHasMaterial[i] then
                baleOverlapsMaterial = true
              end
            end
          end
          if baleOverlapsMaterial then
            baleWeight = baleWeight + weight
          end
        end
      end
    end
  end

  -- Seal tires from shop (Objects): vehicle instances; same grid coverage as bales; weight only if over crop.
  local tireRadius = self.config.tireCoverRadius or 1.9
  local tireHalfH = self.config.tireRestingHalfHeight or 0.45
  local tireRestMin = (self.config.tireRestingOffset and self.config.tireRestingOffset.min) or -0.35
  local tireRestMax = (self.config.tireRestingOffset and self.config.tireRestingOffset.max) or 0.45
  local tireRadius2 = tireRadius * tireRadius
  local vs = g_currentMission and g_currentMission.vehicleSystem
  if vs and vs.vehicles and area ~= nil then
    for _, vehicle in ipairs(vs.vehicles) do
      if self:isSealTireVehicle(vehicle) then
        local bx, by, bz = self:getObjectWorldPosition(vehicle)
        if bx ~= nil and bz ~= nil and self:isPointInBunkerArea(area, bx, bz) then
          local surfaceY = self:getSurfaceYAtWorldXZ(bx, bz, 0)
          local bottomY = (by or surfaceY) - tireHalfH
          if bottomY >= surfaceY + tireRestMin and bottomY <= surfaceY + tireRestMax then
            local overlapsMaterial = false
            for i, pos in ipairs(positions) do
              local dx = pos.x - bx
              local dz = pos.z - bz
              if dx * dx + dz * dz <= tireRadius2 then
                coveredByBale[i] = true
                if cellHasMaterial[i] then
                  overlapsMaterial = true
                end
              end
            end
            if overlapsMaterial then
              tireWeight = tireWeight + (self.config.coverWeights.tire or 1)
            end
          end
        end
      end
    end
  end

  bunker.bunkerSealing.seal.tireWeight = tireWeight
  bunker.bunkerSealing.seal.baleWeight = baleWeight
  bunker.bunkerSealing.seal.coverWeight = tireWeight + baleWeight
end

function BunkerManager:updateSealEfficiency(bunker)
  local coveredByBale = bunker.bunkerSealing.seal.baleCoveredCells or {}
  local cellHasMaterial = bunker.bunkerSealing.seal.cellHasMaterial or {}
  local bufferCells = self.config.sealMaterialBufferCells or 2

  local numMaterialCells = 0
  local coveredMaterialCount = 0
  for i = 1, #bunker.bunkerSealing.seal.cellPositions do
    if cellHasMaterial[i] then
      numMaterialCells = numMaterialCells + 1
      if coveredByBale[i] then
        coveredMaterialCount = coveredMaterialCount + 1
      end
    end
  end

  -- Empty cells (no chaff/grass/silage under the point) are ignored.
  -- Buffer: among material cells, up to `bufferCells` may stay uncovered and still count as full bale coverage.
  local coverageFraction = 0
  if numMaterialCells == 0 then
    coverageFraction = 1
  elseif numMaterialCells <= bufferCells then
    coverageFraction = coveredMaterialCount / numMaterialCells
  else
    local needCovered = numMaterialCells - bufferCells
    if coveredMaterialCount >= needCovered then
      coverageFraction = 1
    else
      coverageFraction = coveredMaterialCount / needCovered
    end
  end

  -- Difficulty scaling: makes it easier/harder for bale coverage to produce high seal efficiency.
  -- Effective coverage is clamped back into [0..1].
  local sealCoverageFactor = self.config.sealCoverageFactor or 1.0
  local effectiveCoverage = clamp(coverageFraction * sealCoverageFactor, 0, 1)

  -- Weight requirement scales with material cells only; at least 2 cells worth when any material exists.
  local requiredWeight = 1
  if numMaterialCells > 0 then
    local cellsForWeight = math.max(bufferCells, numMaterialCells)
    requiredWeight = math.max(1, cellsForWeight * self.config.requiredWeightPerCell)
  end
  local weightBased = clamp(bunker.bunkerSealing.seal.coverWeight / requiredWeight, 0, 1)

  -- Use the better of coverage or weight: if almost all cells are under a bale, seal is good regardless of weight.
  local eff = math.max(effectiveCoverage, weightBased)
  bunker.bunkerSealing.seal.sealEfficiency = eff
  bunker.bunkerSealing.sealEfficiency = eff
end

function BunkerManager:updateOxygen(bunker, dtHours)
  dtHours = dtHours or 1
  local targetOxygen = 1 - (bunker.bunkerSealing.sealEfficiency or 0)
  local lerp = clamp(self.config.oxygenLerpPerHour * dtHours, 0, 1)
  bunker.bunkerSealing.oxygen = bunker.bunkerSealing.oxygen + (targetOxygen - bunker.bunkerSealing.oxygen) * lerp
  bunker.bunkerSealing.oxygen = clamp(bunker.bunkerSealing.oxygen, 0, 1)
end

function BunkerManager:applySilageLossIfNeeded(bunker, px, py, pz)
  if bunker == nil then return false end
  self:ensureBunkerSealingData(bunker)
  if bunker.bunkerSealing.lossApplied then
    return false
  end
  if bunker.state ~= BunkerSilo.STATE_FERMENTED and bunker.state ~= BunkerSilo.STATE_DRAIN then return false end

  -- If we never recorded initial fill (e.g. bunker was loaded already FERMENTED), use current fill from map.
  if (bunker.bunkerSealing.seal.initialFillLevel or 0) == 0 then
    if bunker.updateFillLevel then
      bunker:updateFillLevel()
    end
    bunker.bunkerSealing.seal.initialFillLevel = bunker.fillLevel or 0
  end

  local initialFill = bunker.bunkerSealing.seal.initialFillLevel or (bunker.fillLevel or 0)
  if initialFill <= 0 then
    return false
  end

  -- Calculate what the loss percentage should be, based on the sealEfficiency and the lossFactor and maxLossPercent settings.
  local lossPercent = clamp((1 - (bunker.bunkerSealing.sealEfficiency or 0)) * self.config.lossFactor, 0,
    self.config.maxLossPercent)

  -- Calculate the final silage level after applying the loss percentage to the initial fill level, this will create the final amount of silage inside the bunker, when completly fermented.
  local finalSilage = initialFill * (1 - lossPercent)

  -- Set the different calculations to the data of the bunker.
  bunker.bunkerSealing.finalFillLevel = math.max(0, finalSilage)

  -- Save the silage that is lost in the data, so we can later use it to remove silage from the density map and showcase a message to the player.
  bunker.bunkerSealing.silageLoss = initialFill - bunker.bunkerSealing.finalFillLevel
  bunker.bunkerSealing.lossApplied = true -- Set the lossApplied flag to true, so we know that the loss has been applied and we don't need to apply it again.

  -- Visually remove silage loss from the density map so the mound reflects the lost volume.
  if bunker.bunkerSealing.silageLoss > 0 and bunker.bunkerSealing.lossApplied == true and bunker.isServer then
    self:removeSilageLossFromDensityMap(bunker, bunker.bunkerSealing.silageLoss) -- Call the function to remove the silage from the density map.
    if bunker.updateFillLevel then
      bunker:updateFillLevel()                                                   -- Set the new fill level of the bunker.
    end
    if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
      bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag) -- Raise the dirty flags of the bunker.
    end
  end

  return true
end

function BunkerManager:removeSilageLossFromDensityMap(bunker, totalLossLiters)
  if not DensityMapHeightUtil or not DensityMapHeightUtil.tipToGroundAroundLine then return 0 end
  if not g_densityMapHeightManager or not g_densityMapHeightManager:getIsValid() then return 0 end
  if not bunker or totalLossLiters == nil or totalLossLiters <= 0 then return 0 end

  -- Use inner area for consistent fill-level calculations.
  local area = bunker.bunkerSiloArea and bunker.bunkerSiloArea.inner or bunker.bunkerSiloArea
  if area == nil then return 0 end

  local dhx = area.dhx or ((area.hx or 0) - (area.sx or 0))
  local dhz = area.dhz or ((area.hz or 0) - (area.sz or 0))
  local hl = math.sqrt(dhx * dhx + dhz * dhz)
  if hl <= 0 then return 0 end

  -- Length direction (normalized).
  local hx = (area.dhx_norm ~= nil and area.dhx_norm) or (dhx / hl)
  local hz = (area.dhz_norm ~= nil and area.dhz_norm) or (dhz / hl)

  -- Collect strips along bunker length and measure their fill volumes.
  local step = 0.5
  local strips = {}
  local totalLitersInBunker = 0
  local fillTypes = { bunker.fermentingFillType, bunker.outputFillType }

  local pos = 0
  while pos < hl do
    local s1 = pos
    local s2 = math.min(pos + step, hl)
    pos = s2

    local x0 = area.sx + s1 * hx
    local z0 = area.sz + s1 * hz
    local x1 = area.wx + s1 * hx
    local z1 = area.wz + s1 * hz
    local x2 = area.sx + s2 * hx
    local z2 = area.sz + s2 * hz

    local typeVolumes = {}
    local stripLiters = 0

    for _, fillType in ipairs(fillTypes) do
      if fillType ~= nil then
        local liters = DensityMapHeightUtil.getFillLevelAtArea(fillType, x0, z0, x1, z1, x2, z2)
        if liters > 0 then
          typeVolumes[fillType] = liters
          stripLiters = stripLiters + liters
        end
      end
    end

    if stripLiters > 0 then
      table.insert(strips, {
        s1 = s1,
        s2 = s2,
        stripLiters = stripLiters,
        typeVolumes = typeVolumes
      })
      totalLitersInBunker = totalLitersInBunker + stripLiters
    end
  end

  if totalLitersInBunker <= 0 then return 0 end

  -- Second pass: remove proportionally per strip using negative tip operations.
  local removedTotal = 0
  for _, strip in ipairs(strips) do
    if strip.stripLiters <= 0 then
      -- skip
    else
      local stripLoss = totalLossLiters * (strip.stripLiters / totalLitersInBunker)
      if stripLoss > 0 then
        local sMid = (strip.s1 + strip.s2) * 0.5
        local sx = area.sx + sMid * hx
        local sz = area.sz + sMid * hz
        local ex = area.wx + sMid * hx
        local ez = area.wz + sMid * hz
        local sy = self:getSurfaceYAtWorldXZ(sx, sz)
        local ey = self:getSurfaceYAtWorldXZ(ex, ez)

        local radius = 2.0
        local innerRadius = 0

        for fillType, litersInStripType in pairs(strip.typeVolumes) do
          if litersInStripType > 0 then
            local typeLoss = stripLoss * (litersInStripType / strip.stripLiters)
            if typeLoss > 0 then
              local delta = DensityMapHeightUtil.tipToGroundAroundLine(
                nil,
                -typeLoss,
                fillType,
                sx, sy, sz,
                ex, ey, ez,
                innerRadius,
                radius,
                nil,   -- lineOffset
                false, -- limitToLineHeight
                nil    -- occlusionAreas
              )
              if delta < 0 then
                removedTotal = removedTotal + (-delta)
              end
            end
          end
        end
      end
    end
  end

  return removedTotal
end

function BunkerManager:updateBunker(bunker, dtHours, bales)
  if bunker == nil then return end
  if bunker.state ~= BunkerSilo.STATE_CLOSED and bunker.state ~= BunkerSilo.STATE_FERMENTED then return end

  self:ensureTracked(bunker)
  self:scanBunkerCover(bunker, bales)
  self:updateSealEfficiency(bunker)

  if bunker.state == BunkerSilo.STATE_CLOSED then
    self:updateOxygen(bunker, dtHours)
  end

  if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
    bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
  end
end

function BunkerManager:onBunkerStateChanged(bunker, newState)
  if newState == BunkerSilo.STATE_CLOSED or newState == BunkerSilo.STATE_FERMENTED then
    self:ensureTracked(bunker)
  end
  if newState == BunkerSilo.STATE_CLOSED then
    self:ensureSealGrid(bunker)
    self:updateBunker(bunker, 0, self:collectBales())
  elseif newState == BunkerSilo.STATE_FERMENTED then
    self:ensureSealGrid(bunker)
    self:updateBunker(bunker, 0, self:collectBales())
    self:applySilageLossIfNeeded(bunker, nil, nil, nil)
  end
end

function BunkerManager:onBunkerHourChanged(bunker)
  self:ensureTracked(bunker)
  self:updateBunker(bunker, 1, self:collectBales())
end

function BunkerManager:onBunkerOpenSilo(bunker, px, py, pz)
  self:ensureTracked(bunker)
  local data = bunker.bunkerSealing
  if data == nil then return end
  self:updateBunker(bunker, 0, self:collectBales())
  self:applySilageLossIfNeeded(bunker, px, py, pz)
end

function BunkerManager:update(dt)
  self.scanTimerMs = self.scanTimerMs + (dt or 0)
  if self.scanTimerMs < self.config.coverScanIntervalMs then
    return
  end
  local elapsedMs = self.scanTimerMs
  self.scanTimerMs = 0
  local dtHours = elapsedMs / 3600000
  local bales = self:collectBales()
  for _, bunker in pairs(self.tracked) do
    self:updateBunker(bunker, dtHours, bales)
  end
end

--[[
---------------------------------------------------
HELPER FUNCTIONS
---------------------------------------------------
]]

function BunkerManager:isPointInBunkerArea(area, x, z)
  if area == nil then return false end
  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local len2 = dhx * dhx + dhz * dhz
  local wid2 = dwx * dwx + dwz * dwz
  if len2 <= 0 or wid2 <= 0 then return false end
  local relX = x - area.sx
  local relZ = z - area.sz
  local tLen = (relX * dhx + relZ * dhz) / len2
  local tWid = (relX * dwx + relZ * dwz) / wid2
  return tLen >= 0 and tLen <= 1 and tWid >= 0 and tWid <= 1
end

function BunkerManager:getSurfaceYAtWorldXZ(x, z, offsetAbove)
  offsetAbove = offsetAbove or 0.08
  if DensityMapHeightUtil and DensityMapHeightUtil.getHeightAtWorldPos then
    local surfaceY = DensityMapHeightUtil.getHeightAtWorldPos(x, 0, z)
    if surfaceY and surfaceY > 0 then
      return surfaceY + offsetAbove
    end
  end
  if g_terrainNode then
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + offsetAbove
  end
  return offsetAbove
end

function BunkerManager:getObjectWorldPosition(object)
  if object == nil then return nil, nil, nil end
  if object.nodeId ~= nil and object.nodeId ~= 0 then
    return getWorldTranslation(object.nodeId)
  end
  if object.rootNode ~= nil and object.rootNode ~= 0 then
    return getWorldTranslation(object.rootNode)
  end
  return nil, nil, nil
end

function BunkerManager:getBaleWeightData(bale)
  local cfg = self.config.coverWeights
  local isRound = bale.isRoundbale == true or bale.isRoundBale == true
  local width = bale.width or 0
  local height = bale.height or 0
  local length = bale.length or 0
  local diameter = bale.diameter or 0

  if isRound then
    return cfg.baleRound, math.max(0.8, diameter * 0.5), math.max(0.2, diameter * 0.5)
  end

  local footprintMax = math.max(width, length)
  local volume = width * math.max(height, 1) * math.max(length, 1)
  local isLarge = footprintMax >= 2.0 or volume >= 3.5
  local weight = isLarge and cfg.baleLargeSquare or cfg.baleSmallSquare
  local radius = math.max(0.8, footprintMax * 0.5)
  local halfHeight = math.max(0.2, height * 0.5)
  return weight, radius, halfHeight
end

function BunkerManager:isBaleMountedOrAttached(bale)
  -- Native Bale objects expose dynamic mount type when carried/loaded.
  if bale.dynamicMountType ~= nil and MountableObject ~= nil then
    if bale.dynamicMountType ~= MountableObject.MOUNT_TYPE_NONE then
      return true
    end
  end
  -- Generic fallback for mountable implementations.
  if bale.getMountObject ~= nil and bale:getMountObject() ~= nil then
    return true
  end
  return false
end

function BunkerManager:collectBales()
  local bales = {}
  if g_currentMission == nil then return bales end

  local itemSystem = g_currentMission.itemSystem
  if itemSystem and itemSystem.itemsToSave then
    for _, itemData in pairs(itemSystem.itemsToSave) do
      local item = itemData.item
      if item ~= nil and (item.isRoundbale ~= nil or item.getBaleMatchesSize ~= nil) then
        table.insert(bales, item)
      end
    end
  end

  local vehicleSystem = g_currentMission.vehicleSystem
  if vehicleSystem and vehicleSystem.vehicles then
    for _, vehicle in ipairs(vehicleSystem.vehicles) do
      if vehicle ~= nil and vehicle.spec_bale ~= nil then
        table.insert(bales, vehicle)
      end
    end
  end

  return bales
end

function BunkerManager:isSealTireVehicle(vehicle)
  if vehicle == nil or vehicle.isDeleted then
    return false
  end
  -- Do not count while the player is carrying the tire in hand.
  if vehicle.getIsBeingPickedUp ~= nil and vehicle:getIsBeingPickedUp() then
    return false
  end
  local fn = vehicle.configFileName or vehicle.xmlFilename
  if type(fn) ~= "string" or fn == "" then
    return false
  end
  fn = string.lower(fn)
  return string.find(fn, "tirehuge", 1, true) ~= nil
end
