BunkerManager = {}
BunkerManager_mt = Class(BunkerManager)

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function BunkerManager.new()
  local self = setmetatable({}, BunkerManager_mt)
  self.advancedBunkerSealing = g_currentMission.AdvancedBunkerSealing
  self.config = g_currentMission.AdvancedBunkerSealing.config
  self.tracked = {}
  self.scanTimerMs = 0

  self:registerExistingBunkers()

  return self
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

-- Helper function to get the world position of an object
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

-- Helper function to check if a point is inside a bunker area
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

-- Helper function to get or create custom bunker data
function BunkerManager:getOrCreateBunkerData(bunker)
  if bunker == nil then return nil end
  local data = bunker.advancedBunkerSealing
  if data == nil then
    data = {}
    bunker.advancedBunkerSealing = data
  end

  data.initialFillLevel = data.initialFillLevel or 0
  data.sealEfficiency = data.sealEfficiency or 0   -- 0..1
  data.silageLoss = data.silageLoss or 0           -- liters
  data.lossApplied = data.lossApplied == true      -- boolean
  data.finalFillLevel = data.finalFillLevel or nil -- liters
  data.oxygen = data.oxygen or 1.0
  data.tireWeight = data.tireWeight or 0
  data.baleWeight = data.baleWeight or 0
  data.coverWeight = data.coverWeight or 0

  if data.seal == nil then data.seal = {} end
  data.seal.cells = data.seal.cells or {}
  data.seal.cellPositions = data.seal.cellPositions or {}
  data.seal.baleCoveredCells = data.seal.baleCoveredCells or {}
  data.seal.cellCountLength = data.seal.cellCountLength or 0
  data.seal.cellCountWidth = data.seal.cellCountWidth or 0
  data.seal.sealedCount = data.seal.sealedCount or 0
  data.seal.cellHasMaterial = data.seal.cellHasMaterial or {}

  return data
end

-- Helper function to reset bunker data on close
function BunkerManager:resetBunkerDataOnClose(bunker)
  local data = self:getOrCreateBunkerData(bunker)
  if data == nil then return nil end

  data.initialFillLevel = bunker.fillLevel or 0
  data.sealEfficiency = 0
  data.silageLoss = 0
  data.lossApplied = false
  data.finalFillLevel = nil
  data.oxygen = 1.0
  data.tireWeight = 0
  data.baleWeight = 0
  data.coverWeight = 0
  data.seal.cells = {}
  data.seal.cellPositions = {}
  data.seal.baleCoveredCells = {}
  data.seal.cellCountLength = 0
  data.seal.cellCountWidth = 0
  data.seal.sealedCount = 0
  data.seal.cellHasMaterial = {}

  return data
end

-- Helper function to ensure the seal grid is created
function BunkerManager:ensureSealGrid(bunker, data)
  if bunker == nil or data == nil then return end
  local area = bunker.bunkerSiloArea
  if area == nil then return end
  if data.seal.cellPositions ~= nil and #data.seal.cellPositions > 0 then return end

  local cellSize = self.config.gridCellSize
  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local length = math.sqrt(dhx * dhx + dhz * dhz)
  local width = math.sqrt(dwx * dwx + dwz * dwz)
  local countL = math.max(2, math.floor(length / cellSize + 0.5))
  local countW = math.max(2, math.floor(width / cellSize + 0.5))

  data.seal.cells = {}
  data.seal.cellPositions = {}
  data.seal.baleCoveredCells = {}
  data.seal.cellCountLength = countL
  data.seal.cellCountWidth = countW
  data.seal.sealedCount = 0

  local idx = 0
  for i = 0, countL - 1 do
    for j = 0, countW - 1 do
      idx = idx + 1
      data.seal.cells[idx] = false
      data.seal.baleCoveredCells[idx] = false
      local tLen = (i + 0.5) / countL
      local tWid = (j + 0.5) / countW
      local wx = area.sx + tLen * dhx + tWid * dwx
      local wz = area.sz + tLen * dhz + tWid * dwz
      local wy = self:getSurfaceYAtWorldXZ(wx, wz)
      data.seal.cellPositions[idx] = { x = wx, y = wy, z = wz }
    end
  end
end

-- Mark grid cells that actually contain fermenting/output fill (chaff/grass/silage).
-- Empty floor cells do not require bale coverage.
function BunkerManager:updateCellMaterialMask(bunker, data)
  if not DensityMapHeightUtil or not DensityMapHeightUtil.getFillLevelAtArea then
    return
  end
  if bunker == nil or data == nil or data.seal == nil then
    return
  end
  local area = bunker.bunkerSiloArea
  local positions = data.seal.cellPositions
  if area == nil or positions == nil or #positions == 0 then
    return
  end

  local cellHasMaterial = data.seal.cellHasMaterial or {}
  data.seal.cellHasMaterial = cellHasMaterial

  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local countL = math.max(1, data.seal.cellCountLength or 1)
  local countW = math.max(1, data.seal.cellCountWidth or 1)
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

-- Helper function to register a bunker that is being tracked
function BunkerManager:registerBunker(bunker)
  if bunker ~= nil then
    self.tracked[bunker] = true
  end
end

-- Helper function to register all existing bunkers
function BunkerManager:registerExistingBunkers()
  if g_currentMission == nil or g_currentMission.placeableSystem == nil then return end
  local placeables = g_currentMission.placeableSystem:getBunkerSilos()
  if placeables == nil then return end

  for _, placeable in ipairs(placeables) do
    local bunkers = nil
    if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
      bunkers = placeable.spec_multiBunkerSilo.bunkerSilos
    elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
      bunkers = { placeable.spec_bunkerSilo.bunkerSilo }
    end
    if bunkers then
      for _, bunker in ipairs(bunkers) do
        self:registerBunker(bunker)
      end
    end
  end
end

-- Helper function to get the weight data of a bale
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

-- Helper function to check if a bale is mounted or attached
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

-- Helper function to collect all bales in the mission
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

-- Store-bought seal tire (shop Objects — objects/tireHuge.xml + objects/tireHugeUnit.xml); matched by config filename.
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

-- Helper function to scan the bunker cover and update the seal efficiency
function BunkerManager:scanBunkerCover(bunker, data, bales)
  self:ensureSealGrid(bunker, data)
  self:updateCellMaterialMask(bunker, data)
  local positions = data.seal.cellPositions or {}
  local coveredByBale = data.seal.baleCoveredCells or {}
  data.seal.baleCoveredCells = coveredByBale
  for i = 1, #positions do
    coveredByBale[i] = false
  end

  local tireWeight = 0
  local baleWeight = 0
  local area = bunker.bunkerSiloArea
  local restingMin = self.config.baleRestingOffset.min
  local restingMax = self.config.baleRestingOffset.max
  local cellHasMaterial = data.seal.cellHasMaterial or {}

  for _, bale in ipairs(bales or {}) do
    -- Do not count bales currently grabbed/attached by tools/loaders.
    if not self:isBaleMountedOrAttached(bale) then
      local bx, by, bz = self:getObjectWorldPosition(bale)
      if bx ~= nil and bz ~= nil and self:isPointInBunkerArea(area, bx, bz) then
        local weight, radius, halfHeight = self:getBaleWeightData(bale)
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

  data.tireWeight = tireWeight
  data.baleWeight = baleWeight
  data.coverWeight = tireWeight + baleWeight
end

-- Helper function to update the seal efficiency
function BunkerManager:updateSealEfficiency(data)
  local coveredByBale = data.seal.baleCoveredCells or {}
  local cellHasMaterial = data.seal.cellHasMaterial or {}
  local bufferCells = self.config.sealMaterialBufferCells or 2

  local numMaterialCells = 0
  local coveredMaterialCount = 0
  for i = 1, #data.seal.cellPositions do
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
  local weightBased = clamp(data.coverWeight / requiredWeight, 0, 1)

  -- Use the better of coverage or weight: if almost all cells are under a bale, seal is good regardless of weight.
  data.sealEfficiency = math.max(effectiveCoverage, weightBased)
end

-- Helper function to update the oxygen level
function BunkerManager:updateOxygen(data, dtHours)
  dtHours = dtHours or 1
  local targetOxygen = 1 - (data.sealEfficiency or 0)
  local lerp = clamp(self.config.oxygenLerpPerHour * dtHours, 0, 1)
  data.oxygen = data.oxygen + (targetOxygen - data.oxygen) * lerp
  data.oxygen = clamp(data.oxygen, 0, 1)
end

-- Remove silage loss from the density map using bucket-style negative tips.
-- Distributes totalLossLiters proportionally across the bunker so the heap shape is preserved.
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
                nil, -- lineOffset
                false, -- limitToLineHeight
                nil -- occlusionAreas
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

-- Function to apply silage loss if needed.
-- Silage loss is calculated by calculating the lossPercentage (done by the config settings), and then multiply the initialFillLevel of the bunker by the lossPercentage.
function BunkerManager:applySilageLossIfNeeded(bunker, data, px, py, pz)
  if data.lossApplied then return false end
  if bunker.state ~= BunkerSilo.STATE_FERMENTED and bunker.state ~= BunkerSilo.STATE_DRAIN then return false end

  -- If we never recorded initial fill (e.g. bunker was loaded already FERMENTED), use current fill from map.
  if (data.initialFillLevel or 0) == 0 then
    if bunker.updateFillLevel then
      bunker:updateFillLevel()
    end
    data.initialFillLevel = bunker.fillLevel or 0
  end

  local initialFill = data.initialFillLevel or (bunker.fillLevel or 0)
  if initialFill <= 0 then
    return false
  end

  -- Calculate what the loss percentage should be, based on the sealEfficiency and the lossFactor and maxLossPercent settings.
  local lossPercent = clamp((1 - (data.sealEfficiency or 0)) * self.config.lossFactor, 0,
    self.config.maxLossPercent)

  -- Calculate the final silage level after applying the loss percentage to the initial fill level, this will create the final amount of silage inside the bunker, when completly fermented.
  local finalSilage = initialFill * (1 - lossPercent)

  -- Set the different calculations to the data of the bunker.
  data.finalFillLevel = math.max(0, finalSilage)

  -- Save the silage that is lost in the data, so we can later use it to remove silage from the density map and showcase a message to the player.
  data.silageLoss = initialFill - data.finalFillLevel
  data.lossApplied = true -- Set the lossApplied flag to true, so we know that the loss has been applied and we don't need to apply it again.

  -- Visually remove silage loss from the density map so the mound reflects the lost volume.
  if data.silageLoss > 0 and data.lossApplied == true and bunker.isServer then
    self:removeSilageLossFromDensityMap(bunker, data.silageLoss) -- Call the function to remove the silage from the density map.
    if bunker.updateFillLevel then
      bunker:updateFillLevel()                                   -- Set the new fill level of the bunker.
    end
    if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
      bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag) -- Raise the dirty flags of the bunker.
    end
  end

  return true
end

-- Function to update the bunker data.
function BunkerManager:updateBunker(bunker, dtHours, bales)
  if bunker == nil then return end
  if bunker.state ~= BunkerSilo.STATE_CLOSED and bunker.state ~= BunkerSilo.STATE_FERMENTED then return end
  local data = self:getOrCreateBunkerData(bunker)
  self:scanBunkerCover(bunker, data, bales)
  self:updateSealEfficiency(data)
  if bunker.state == BunkerSilo.STATE_CLOSED then
    self:updateOxygen(data, dtHours)
  end
  if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
    bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
  end
end

function BunkerManager:onBunkerStateChanged(bunker, newState)
  self:registerBunker(bunker)
  if newState == BunkerSilo.STATE_CLOSED then
    local data = self:resetBunkerDataOnClose(bunker)
    self:ensureSealGrid(bunker, data)
    self:updateBunker(bunker, 0, self:collectBales())
  elseif newState == BunkerSilo.STATE_FERMENTED then
    local data = self:getOrCreateBunkerData(bunker)
    self:updateBunker(bunker, 0, self:collectBales())
    self:applySilageLossIfNeeded(bunker, data, nil, nil, nil)
  end
end

function BunkerManager:onBunkerHourChanged(bunker)
  self:registerBunker(bunker)
  self:updateBunker(bunker, 1, self:collectBales())
end

-- When the bunker is opened, update the bunker data and apply the silage loss if needed.
function BunkerManager:onBunkerOpenSilo(bunker, px, py, pz)
  self:registerBunker(bunker)
  local data = self:getOrCreateBunkerData(bunker)
  if data == nil then return end
  self:updateBunker(bunker, 0, self:collectBales())
  self:applySilageLossIfNeeded(bunker, data, px, py, pz)
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
  for bunker, _ in pairs(self.tracked) do
    self:updateBunker(bunker, dtHours, bales)
  end
end
