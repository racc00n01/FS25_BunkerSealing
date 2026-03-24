AdvancedBunkerSealing = {}
AdvancedBunkerSealing.dir = g_currentModDirectory
AdvancedBunkerSealing.modName = g_currentModName

AdvancedBunkerSealing.config = {
  debug = false,
  gridCellSize = 0.5,
  coverScanIntervalMs = 1000,
  requiredWeightPerCell = 1.0,
  oxygenLerpPerHour = 0.25,
  lossFactor = 1.0,
  maxLossPercent = 0.5,
  -- Global seal difficulty: scales how effective bale coverage is.
  -- Hard = 0.8 (more bales needed), Medium = 1.05 (slightly easier), Easy = 1.2 (few bales needed).
  sealCoverageFactor = 1.05,
  coverWeights = {
    tire = 1,
    baleSmallSquare = 5,
    baleLargeSquare = 10,
    baleRound = 8
  },
  baleRestingOffset = {
    min = -0.15,
    max = 0.2
  },
  -- Extra downward tolerance for round bales lying on their side.
  -- Their origin/center can sit lower relative to the heap surface than square bales.
  roundBaleRestingExtraDown = 0.45,
  -- Seal tire (objects/tireHuge*.xml, shop Objects): horizontal coverage radius vs heap grid (world meters).
  -- Larger = fewer tires needed for full coverage; does not change the placed object's size.
  tireCoverRadius = 3.4,
  tireRestingHalfHeight = 0.45,
  tireRestingOffset = {
    min = -0.35,
    max = 0.45
  },
  debugPointSize = 0.5,
  -- Minimum liters in a grid cell to count as "has crop" (needs sealing).
  minCellFillLiters = 1.0,
  -- Among cells that have material, this many may stay uncovered and still count as full coverage.
  sealMaterialBufferCells = 3
}


function AdvancedBunkerSealing:loadMap()
  g_currentMission.AdvancedBunkerSealing = self

  self.BunkerManager = BunkerManager:new()
  self.config = AdvancedBunkerSealing.config

  if g_currentMission and g_currentMission.addDrawable then
    g_currentMission:addDrawable(self)
  end
end

function AdvancedBunkerSealing:deleteMap()
  if g_currentMission and g_currentMission.removeDrawable then
    g_currentMission:removeDrawable(self)
  end
end

function AdvancedBunkerSealing:update(dt)
  self.BunkerManager:update(dt)
end

-- Function to draw the debug grid of sealed cells onto the bunker silo surface.
function AdvancedBunkerSealing:draw()
  if self.config and self.config.debug then
    self:drawDebugGrid()
  end
end

-- Debug function to draw the grid of sealed cells onto the bunker silo surface
function AdvancedBunkerSealing:drawDebugGrid()
  if g_currentMission == nil or g_currentMission.placeableSystem == nil or g_terrainNode == nil then
    return
  end
  if self.BunkerManager == nil then return end

  for bunker, _ in pairs(self.BunkerManager.tracked) do
    local data = self.BunkerManager:getOrCreateBunkerData(bunker)
    if data and data.seal and data.seal.cellPositions and #data.seal.cellPositions > 0 then
      local positions = data.seal.cellPositions
      local cells = data.seal.cells
      local baleCovered = data.seal.baleCoveredCells or {}
      local cellHasMaterial = data.seal.cellHasMaterial or {}
      local W = data.seal.cellCountWidth or 1
      local L = data.seal.cellCountLength or #positions
      for idx = 1, #positions do
        local pos = positions[idx]
        local x, z = pos.x, pos.z
        if x == nil or z == nil then break end
        local y = self.BunkerManager:getSurfaceYAtWorldXZ(x, z)
        local hasMat = cellHasMaterial[idx] == true
        if not hasMat then
          -- No crop under this grid point: not part of seal requirement.
          drawDebugPoint(x, y, z, 0.35, 0.35, 0.35, self.config.debugPointSize * 0.7)
        else
          local sealed = (cells and cells[idx]) or baleCovered[idx]
          if sealed then
            drawDebugPoint(x, y, z, 0, 1, 0, self.config.debugPointSize)
          else
            drawDebugPoint(x, y, z, 1, 0.3, 0, self.config.debugPointSize)
          end
        end

        local col = (idx - 1) % W
        if col < W - 1 and idx < #positions then
          local nextPos = positions[idx + 1]
          if nextPos and nextPos.x and nextPos.z then
            local ny = self.BunkerManager:getSurfaceYAtWorldXZ(nextPos.x, nextPos.z)
            drawDebugLine(x, y, z, 0.5, 0.5, 0.5, nextPos.x, ny, nextPos.z, 0.5, 0.5, 0.5, true)
          end
        end

        local row = math.floor((idx - 1) / W)
        local bottomIdx = idx + W
        if row < L - 1 and bottomIdx <= #positions then
          local nextPos = positions[bottomIdx]
          if nextPos and nextPos.x and nextPos.z then
            local ny = self.BunkerManager:getSurfaceYAtWorldXZ(nextPos.x, nextPos.z)
            drawDebugLine(x, y, z, 0.5, 0.5, 0.5, nextPos.x, ny, nextPos.z, 0.5, 0.5, 0.5, true)
          end
        end
      end
    end
  end
end

function AdvancedBunkerSealing.onBunkerSetState(self, superFunc, state, showNotification)
  superFunc(self, state, showNotification)
  g_currentMission.AdvancedBunkerSealing.BunkerManager:onBunkerStateChanged(self, state)
end

function AdvancedBunkerSealing.onBunkerHourChanged(self, superFunc)
  superFunc(self)
  g_currentMission.AdvancedBunkerSealing.BunkerManager:onBunkerHourChanged(self)
end

function AdvancedBunkerSealing.onBunkerOpenSilo(self, superFunc, px, py, pz)
  if g_currentMission and g_currentMission.AdvancedBunkerSealing and g_currentMission.AdvancedBunkerSealing.BunkerManager then
    g_currentMission.AdvancedBunkerSealing.BunkerManager:onBunkerOpenSilo(self, px, py, pz)
  end
  return superFunc(self, px, py, pz)
end

function AdvancedBunkerSealing.onBunkerUpdateFillLevel(self, superFunc)
  superFunc(self)
  local data = self.asfAdvancedSilage
  if data and data.lossApplied and data.finalFillLevel ~= nil then
    self.fillLevel = data.finalFillLevel
  end
end

-- Add a simple AdvancedBunkerSealing seal efficiency line to the bunker HUD when the player is close enough.
function AdvancedBunkerSealing.onBunkerUpdate(self, superFunc, dt)
  superFunc(self, dt)

  if not g_currentMission or not g_currentMission.AdvancedBunkerSealing or not g_currentMission.AdvancedBunkerSealing.BunkerManager then
    return
  end

  -- Only show when the player can interact with the bunker.
  if not self:getCanInteract(true) then
    return
  end

  local manager = g_currentMission.AdvancedBunkerSealing.BunkerManager
  local data = manager:getOrCreateBunkerData(self) or nil
  if not data or not data.sealEfficiency then
    return
  end

  local sealPct = math.floor((data.sealEfficiency or 0) * 100 + 0.5)
  g_currentMission:addExtraPrintText(string.format(g_i18n:getText("advancedBunkerSealing_sealEfficiency"), sealPct))
end

BunkerSilo.setState = Utils.overwrittenFunction(BunkerSilo.setState, AdvancedBunkerSealing.onBunkerSetState)
BunkerSilo.onHourChanged = Utils.overwrittenFunction(BunkerSilo.onHourChanged, AdvancedBunkerSealing.onBunkerHourChanged)
BunkerSilo.openSilo = Utils.overwrittenFunction(BunkerSilo.openSilo, AdvancedBunkerSealing.onBunkerOpenSilo)
BunkerSilo.updateFillLevel = Utils.overwrittenFunction(BunkerSilo.updateFillLevel,
  AdvancedBunkerSealing.onBunkerUpdateFillLevel)
BunkerSilo.update = Utils.overwrittenFunction(BunkerSilo.update, AdvancedBunkerSealing.onBunkerUpdate)

addModEventListener(AdvancedBunkerSealing)
