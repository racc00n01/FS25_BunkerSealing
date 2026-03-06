BunkerManager = {}
BunkerManager_mt = Class(BunkerManager)

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function BunkerManager.new()
  local self = setmetatable({}, BunkerManager_mt)
  self.config = g_currentMission.AdvancedBunkers.config
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

function BunkerManager:getOrCreateBunkerData(bunker)
  if bunker == nil then return nil end
  local data = bunker.asfAdvancedSilage
  if data == nil then
    data = {}
    bunker.asfAdvancedSilage = data
  end

  data.initialFillLevel = data.initialFillLevel or 0
  data.sealEfficiency = data.sealEfficiency or 0
  data.silageLoss = data.silageLoss or 0
  data.lossApplied = data.lossApplied == true
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

  return data
end

function BunkerManager:resetBunkerDataOnClose(bunker)
  local data = self:getOrCreateBunkerData(bunker)
  if data == nil then return nil end

  data.initialFillLevel = bunker.fillLevel or 0
  data.sealEfficiency = 0
  data.silageLoss = 0
  data.lossApplied = false
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

  return data
end

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

function BunkerManager:registerBunker(bunker)
  if bunker ~= nil then
    self.tracked[bunker] = true
  end
end

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

function BunkerManager:scanBunkerCover(bunker, data, bales)
  self:ensureSealGrid(bunker, data)
  local positions = data.seal.cellPositions or {}
  local coveredByBale = data.seal.baleCoveredCells or {}
  data.seal.baleCoveredCells = coveredByBale
  for i = 1, #positions do
    coveredByBale[i] = false
  end

  local tireWeight = (data.seal.sealedCount or 0) * self.config.coverWeights.tire
  local baleWeight = 0
  local area = bunker.bunkerSiloArea
  local restingMin = self.config.baleRestingOffset.min
  local restingMax = self.config.baleRestingOffset.max

  for _, bale in ipairs(bales or {}) do
    -- Do not count bales currently grabbed/attached by tools/loaders.
    if not self:isBaleMountedOrAttached(bale) then
      local bx, by, bz = self:getObjectWorldPosition(bale)
      if bx ~= nil and bz ~= nil and self:isPointInBunkerArea(area, bx, bz) then
        local weight, radius, halfHeight = self:getBaleWeightData(bale)
        local surfaceY = self:getSurfaceYAtWorldXZ(bx, bz, 0)
        local bottomY = (by or surfaceY) - (halfHeight or 0.2)
        if bottomY >= surfaceY + restingMin and bottomY <= surfaceY + restingMax then
          baleWeight = baleWeight + weight
          local radius2 = radius * radius
          for i, pos in ipairs(positions) do
            local dx = pos.x - bx
            local dz = pos.z - bz
            if dx * dx + dz * dz <= radius2 then
              coveredByBale[i] = true
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

function BunkerManager:updateSealEfficiency(data)
  local requiredWeight = math.max(1, #data.seal.cellPositions * self.config.requiredWeightPerCell)
  data.sealEfficiency = clamp(data.coverWeight / requiredWeight, 0, 1)
end

function BunkerManager:updateOxygen(data, dtHours)
  dtHours = dtHours or 1
  local targetOxygen = 1 - (data.sealEfficiency or 0)
  local lerp = clamp(self.config.oxygenLerpPerHour * dtHours, 0, 1)
  data.oxygen = data.oxygen + (targetOxygen - data.oxygen) * lerp
  data.oxygen = clamp(data.oxygen, 0, 1)
end

function BunkerManager:applySilageLossIfNeeded(bunker, data)
  if data.lossApplied then return false end
  if bunker.state ~= BunkerSilo.STATE_FERMENTED then return false end

  local initialFill = data.initialFillLevel or (bunker.fillLevel or 0)
  local currentFill = bunker.fillLevel or initialFill
  local lossPercent = clamp((1 - (data.sealEfficiency or 0)) * self.config.lossFactor, 0,
    self.config.maxLossPercent)
  local finalSilage = initialFill * (1 - lossPercent)
  local targetFill = math.max(0, math.min(currentFill, finalSilage))
  local lossLiters = math.max(0, currentFill - targetFill)

  if lossLiters > 0 then
    if bunker.setFillLevel ~= nil then
      bunker:setFillLevel(targetFill)
    else
      bunker.fillLevel = targetFill
    end
    if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
      bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
    end
  end

  data.silageLoss = lossLiters
  data.lossApplied = true
  self.asf:log("Fermentation finished")
  self.asf:log("Seal efficiency: %.2f", data.sealEfficiency or 0)
  self.asf:log("Initial fill: %.0f", initialFill)
  self.asf:log("Final silage: %.0f", targetFill)
  self.asf:log("Lost silage: %.0f", lossLiters)
  return true
end

function BunkerManager:updateBunker(bunker, dtHours, bales)
  if bunker == nil then return end
  if bunker.state ~= BunkerSilo.STATE_CLOSED and bunker.state ~= BunkerSilo.STATE_FERMENTED then return end
  local data = self:getOrCreateBunkerData(bunker)
  self:scanBunkerCover(bunker, data, bales)
  self:updateSealEfficiency(data)
  if bunker.state == BunkerSilo.STATE_CLOSED then
    self:updateOxygen(data, dtHours)
  else
    self:applySilageLossIfNeeded(bunker, data)
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
    self:applySilageLossIfNeeded(bunker, data)
  end
end

function BunkerManager:onBunkerHourChanged(bunker)
  self:registerBunker(bunker)
  self:updateBunker(bunker, 1, self:collectBales())
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
