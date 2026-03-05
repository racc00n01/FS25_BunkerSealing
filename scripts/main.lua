-- Minimal ASF module: bunker sealing (tire) logic only.
-- Seal grid generation and placement API for integration later.

AdvancedSilageFermentation = {}
local ASF = AdvancedSilageFermentation

ASF.modName = g_currentModName or "AdvancedSilageFermentation"
ASF.dir = g_currentModDirectory
ASF.DEBUG = true

local function asfPrint(fmt, ...)
  if ASF.DEBUG then
    print(string.format("[ASF] " .. fmt, ...))
  end
end

-- Y position on the bunker surface (seal foil / tarp), not terrain. Uses density map so lines draw on top.
local function getSurfaceYAtWorldXZ(x, z, offsetAbove)
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

function ASF:getOrCreateBunkerData(bunker)
  if bunker == nil then return nil end
  local extra = bunker.asfAdvancedSilage
  if extra == nil then
    extra = {}
    bunker.asfAdvancedSilage = extra
  end
  return extra
end

-- Initialize seal grid on bunker roof. cellSizeMeters defaults to 1m.
-- Full 2D grid over length and width of the bunker (parallelogram). cellPositions/cells are row-major.
function ASF:initSealGrid(bunker, cellSizeMeters)
  if bunker == nil then return end
  local extra = ASF:getOrCreateBunkerData(bunker)
  if extra == nil then return end
  local area = bunker.bunkerSiloArea
  if area == nil then return end
  cellSizeMeters = cellSizeMeters or 1.0

  local dhx = area.dhx or (area.hx - area.sx)
  local dhz = area.dhz or (area.hz - area.sz)
  local dwx = area.dwx or (area.wx - area.sx)
  local dwz = area.dwz or (area.wz - area.sz)
  local length = math.sqrt(dhx * dhx + dhz * dhz)
  local width = math.sqrt(dwx * dwx + dwz * dwz)
  local cellCountLength = math.max(2, math.floor(length / cellSizeMeters + 0.5))
  local cellCountWidth = math.max(2, math.floor(width / cellSizeMeters + 0.5))

  extra.seal = {
    cells = {},
    cellPositions = {},
    cellCountLength = cellCountLength,
    cellCountWidth = cellCountWidth,
    requiredCoverage = 0.98,
    sealedCount = 0
  }

  local idx = 0
  for i = 0, cellCountLength - 1 do
    for j = 0, cellCountWidth - 1 do
      idx = idx + 1
      extra.seal.cells[idx] = false
      local tLen = (i + 0.5) / cellCountLength
      local tWid = (j + 0.5) / cellCountWidth
      local wx = area.sx + tLen * dhx + tWid * dwx
      local wz = area.sz + tLen * dhz + tWid * dwz
      local wy = getSurfaceYAtWorldXZ(wx, wz)
      extra.seal.cellPositions[idx] = { x = wx, y = wy, z = wz }
    end
  end

  asfPrint("initSealGrid: bunker=%s grid=%dx%d cells=%d", tostring(bunker.rootNode or "?"), cellCountLength,
    cellCountWidth, idx)
  if bunker.isServer and bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
    bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
  end
end

-- Place a tire on the bunker roof (server-only). Returns true if a cell was sealed.
function ASF:placeSealTire(bunker, worldX, worldZ, player)
  if bunker == nil then return false end
  if not bunker.isServer then return false end
  local extra = ASF:getOrCreateBunkerData(bunker)
  if extra == nil or extra.seal == nil or extra.seal.cellPositions == nil then return false end

  local bestIdx, bestDist2 = nil, math.huge
  for i, pos in ipairs(extra.seal.cellPositions) do
    local dx = pos.x - worldX
    local dz = pos.z - worldZ
    local d2 = dx * dx + dz * dz
    if d2 < bestDist2 then bestDist2, bestIdx = d2, i end
  end
  local placeRadius = 1.5
  if bestIdx == nil or bestDist2 > placeRadius * placeRadius then return false end

  if not extra.seal.cells[bestIdx] then
    extra.seal.cells[bestIdx] = true
    extra.seal.sealedCount = (extra.seal.sealedCount or 0) + 1
    asfPrint("placeSealTire: sealed cell %d (bunker=%s)", bestIdx, tostring(bunker.rootNode or "?"))
    if bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
      bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
    end
    return true
  end
  return false
end

function ASF:getSealedFraction(bunker)
  local extra = ASF:getOrCreateBunkerData(bunker)
  if extra == nil or extra.seal == nil or extra.seal.cells == nil then return 0 end
  local count = 0
  for _, v in ipairs(extra.seal.cells) do if v then count = count + 1 end end
  return count / math.max(1, #extra.seal.cells)
end

-- Console command: place seal tire at the player's current position (for testing).
function ASF.consoleCommandPlaceSealTire(self)
  local ok, err = pcall(function()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
      print("[ASF] No mission or placeable system.")
      return
    end
    local player = g_localPlayer
    if player == nil then
      print("[ASF] No local player.")
      return
    end
    local px, py, pz = player:getPosition()
    if px == nil or pz == nil then
      print("[ASF] Could not get player position.")
      return
    end
    local placeables = g_currentMission.placeableSystem:getBunkerSilos()
    if placeables == nil then
      print("[ASF] No bunker silos found.")
      return
    end
    for _, placeable in ipairs(placeables) do
      local bunkers = nil
      if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
        bunkers = placeable.spec_multiBunkerSilo.bunkerSilos
      elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
        bunkers = { placeable.spec_bunkerSilo.bunkerSilo }
      end
      if bunkers then
        for _, bunker in ipairs(bunkers) do
          if bunker and ASF:placeSealTire(bunker, px, pz, player) then
            local frac = ASF:getSealedFraction(bunker)
            print(string.format("[ASF] Sealed cell at (%.1f, %.1f). Grid: %.0f%% sealed.", px, pz, frac * 100))
            return
          end
        end
      end
    end
    print("[ASF] No cell sealed. Stand on the seal foil within 1.5 m of a grid cell and try again.")
  end)
  if not ok and err then
    print("[ASF] Error: " .. tostring(err))
  end
end

-- Hook BunkerSilo so closing the bunker creates the seal grid on top.
local function onBunkerSetState(self, superFunc, state, showNotification)
  superFunc(self, state, showNotification)
  if state == BunkerSilo.STATE_CLOSED then
    ASF:initSealGrid(self)
  end
end
if BunkerSilo and BunkerSilo.setState then
  BunkerSilo.setState = Utils.overwrittenFunction(BunkerSilo.setState, onBunkerSetState)
end

-- Draw seal grid in world (only when mission and terrain exist). 2D grid with larger points.
local DEBUG_POINT_SIZE = 1.0

function ASF:draw()
  if g_currentMission == nil or g_currentMission.placeableSystem == nil or g_terrainNode == nil then
    return
  end
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
        local extra = bunker.asfAdvancedSilage
        if extra and extra.seal and extra.seal.cellPositions and #extra.seal.cellPositions > 0 then
          local positions = extra.seal.cellPositions
          local cells = extra.seal.cells
          local W = extra.seal.cellCountWidth or 1
          local L = extra.seal.cellCountLength or #positions
          for idx = 1, #positions do
            local pos = positions[idx]
            local x, z = pos.x, pos.z
            if not x or not z then break end
            local y = getSurfaceYAtWorldXZ(x, z)
            local sealed = cells and cells[idx]
            if sealed then
              drawDebugPoint(x, y, z, 0, 1, 0, DEBUG_POINT_SIZE)
            else
              drawDebugPoint(x, y, z, 1, 0.3, 0, DEBUG_POINT_SIZE)
            end
            -- Line to right neighbor (same row, next column)
            local col = (idx - 1) % W
            if col < W - 1 and idx < #positions then
              local nextPos = positions[idx + 1]
              if nextPos and nextPos.x and nextPos.z then
                local ny = getSurfaceYAtWorldXZ(nextPos.x, nextPos.z)
                drawDebugLine(x, y, z, 0.5, 0.5, 0.5, nextPos.x, ny, nextPos.z, 0.5, 0.5, 0.5, true)
              end
            end
            -- Line to bottom neighbor (next row, same column)
            local row = math.floor((idx - 1) / W)
            local bottomIdx = idx + W
            if row < L - 1 and bottomIdx <= #positions then
              local nextPos = positions[bottomIdx]
              if nextPos and nextPos.x and nextPos.z then
                local ny = getSurfaceYAtWorldXZ(nextPos.x, nextPos.z)
                drawDebugLine(x, y, z, 0.5, 0.5, 0.5, nextPos.x, ny, nextPos.z, 0.5, 0.5, 0.5, true)
              end
            end
          end
        end
      end
    end
  end
end

function ASF:loadMap()
  if g_currentMission and g_currentMission.addDrawable then
    g_currentMission:addDrawable(ASF)
  end
  addConsoleCommand("gsASFPlaceSealTire", "Place seal tire at current player position (stand on closed bunker foil)",
    "consoleCommandPlaceSealTire", ASF)
  asfPrint("Seal grid drawable registered (grid visible when bunker is closed)")
end

function ASF:deleteMap()
  if g_currentMission and g_currentMission.removeDrawable then
    g_currentMission:removeDrawable(ASF)
  end
  removeConsoleCommand("gsASFPlaceSealTire")
end

addModEventListener(ASF)
