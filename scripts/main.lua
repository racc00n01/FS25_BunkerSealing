AdvancedBunkers = {}
AdvancedBunkers.dir = g_currentModDirectory
AdvancedBunkers.modName = g_currentModName

AdvancedBunkers.config = {
  debug = true,
  gridCellSize = 0.5,
  coverScanIntervalMs = 1000,
  requiredWeightPerCell = 1.0,
  oxygenLerpPerHour = 0.25,
  lossFactor = 2.0,
  maxLossPercent = 0.8,
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
  debugPointSize = 0.5
}


function AdvancedBunkers:loadMap()
  g_currentMission.AdvancedBunkers = self

  self.BunkerManager = BunkerManager:new()
  self.config = AdvancedBunkers.config

  if g_currentMission and g_currentMission.addDrawable then
    g_currentMission:addDrawable(self)
  end

  addConsoleCommand("gsASFPlaceSealTire", "Place seal tire at current player position (stand on closed bunker foil)",
    "consoleCommandPlaceSealTire", self)
  self:log("ASF initialized")
end

function AdvancedBunkers:deleteMap()
  if g_currentMission and g_currentMission.removeDrawable then
    g_currentMission:removeDrawable(self)
  end
  removeConsoleCommand("gsASFPlaceSealTire")
end

function AdvancedBunkers:update(dt)
  self.BunkerManager:update(dt)
end

function AdvancedBunkers:draw()
  self:drawDebugGrid()
end

function AdvancedBunkers:placeSealTire(bunker, worldX, worldZ, player)
  if bunker == nil then return false end
  if not bunker.isServer then return false end
  local data = self.BunkerManager:getOrCreateBunkerData(bunker)
  self.BunkerManager:ensureSealGrid(bunker, data)
  if data == nil or data.seal == nil or data.seal.cellPositions == nil then return false end

  local bestIdx, bestDist2 = nil, math.huge
  for i, pos in ipairs(data.seal.cellPositions) do
    local dx = pos.x - worldX
    local dz = pos.z - worldZ
    local d2 = dx * dx + dz * dz
    if d2 < bestDist2 then
      bestDist2 = d2
      bestIdx = i
    end
  end

  local placeRadius = 1.5
  if bestIdx == nil or bestDist2 > placeRadius * placeRadius then return false end

  if not data.seal.cells[bestIdx] then
    data.seal.cells[bestIdx] = true
    data.seal.sealedCount = (data.seal.sealedCount or 0) + 1
    if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
      bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
    end
    return true
  end
  return false
end

function AdvancedBunkers:getSealedFraction(bunker)
  local data = self.BunkerManager:getOrCreateBunkerData(bunker)
  if data == nil or data.seal == nil or data.seal.cells == nil then return 0 end
  local count = 0
  for _, v in ipairs(data.seal.cells) do
    if v then count = count + 1 end
  end
  return count / math.max(1, #data.seal.cells)
end

function AdvancedBunkers:log(fmt, ...)
  if not self.config.debug then
    return
  end
  if select("#", ...) > 0 then
    print(string.format("[AdvancedBunkers] " .. fmt, ...))
  else
    print("[AdvancedBunkers] " .. tostring(fmt))
  end
end

function AdvancedBunkers.consoleCommandPlaceSealTire(self)
  local ok, err = pcall(function()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
      print("[AdvancedBunkers] No mission or placeable system.")
      return
    end
    local player = g_localPlayer
    if player == nil then
      print("[AdvancedBunkers] No local player.")
      return
    end
    local px, py, pz = player:getPosition()
    if px == nil or pz == nil then
      print("[AdvancedBunkers] Could not get player position.")
      return
    end

    local placeables = g_currentMission.placeableSystem:getBunkerSilos()
    for _, placeable in ipairs(placeables or {}) do
      local bunkers = nil
      if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
        bunkers = placeable.spec_multiBunkerSilo.bunkerSilos
      elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
        bunkers = { placeable.spec_bunkerSilo.bunkerSilo }
      end
      if bunkers then
        for _, bunker in ipairs(bunkers) do
          if bunker and self:placeSealTire(bunker, px, pz, player) then
            local frac = self:getSealedFraction(bunker)
            print(string.format("[AdvancedBunkers] Sealed cell at (%.1f, %.1f). Grid: %.0f%% sealed.", px, pz, frac * 100))
            return
          end
        end
      end
    end
    print("[AdvancedBunkers] No cell sealed. Stand on the seal foil within 1.5 m of a grid cell and try again.")
  end)
  if not ok and err then
    print("[AdvancedBunkers] Error: " .. tostring(err))
  end
end

-- Debug function to draw the grid of sealed cells onto the bunker silo surface
function AdvancedBunkers:drawDebugGrid()
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
      local W = data.seal.cellCountWidth or 1
      local L = data.seal.cellCountLength or #positions
      for idx = 1, #positions do
        local pos = positions[idx]
        local x, z = pos.x, pos.z
        if x == nil or z == nil then break end
        local y = self.BunkerManager:getSurfaceYAtWorldXZ(x, z)
        local sealed = (cells and cells[idx]) or baleCovered[idx]
        if sealed then
          drawDebugPoint(x, y, z, 0, 1, 0, self.config.debugPointSize)
        else
          drawDebugPoint(x, y, z, 1, 0.3, 0, self.config.debugPointSize)
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

function AdvancedBunkers.onBunkerSetState(self, superFunc, state, showNotification)
  superFunc(self, state, showNotification)
  g_currentMission.AdvancedBunkers.BunkerManager:onBunkerStateChanged(self, state)
end

function AdvancedBunkers.onBunkerHourChanged(self, superFunc)
  superFunc(self)
  g_currentMission.AdvancedBunkers.BunkerManager:onBunkerHourChanged(self)
end

BunkerSilo.setState = Utils.overwrittenFunction(BunkerSilo.setState, AdvancedBunkers.onBunkerSetState)
BunkerSilo.onHourChanged = Utils.overwrittenFunction(BunkerSilo.onHourChanged, AdvancedBunkers.onBunkerHourChanged)

addModEventListener(AdvancedBunkers)
