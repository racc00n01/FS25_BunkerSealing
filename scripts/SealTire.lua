-- scripts/SealTire.lua
SealTire = {}
local SealTire_mt = Class(SealTire)
function SealTire.prerequisitesPresent(specializations)
  return true
end

function SealTire.registerEventListeners(placeableType)
  SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", SealTire)
end

-- helper: point-in-parallelogram using the bunker area vectors
local function isPointInBunkerArea(area, x, z)
  local relX = x - area.sx
  local relZ = z - area.sz
  local len2 = area.dhx * area.dhx + area.dhz * area.dhz
  local wid2 = area.dwx * area.dwx + area.dwz * area.dwz
  if len2 == 0 or wid2 == 0 then return false end
  local tLen = (relX * area.dhx + relZ * area.dhz) / len2
  local tWid = (relX * area.dwx + relZ * area.dwz) / wid2
  return tLen >= 0 and tLen <= 1 and tWid >= 0 and tWid <= 1
end

-- Called when the player finishes placing the placeable
function SealTire:onFinalizePlacement()
  if not self.isServer then
    return
  end

  -- get world position of the placed tire
  local tx, ty, tz = getWorldTranslation(self.rootNode)
  local sealRadius = 1.5 -- meters; tune this

  -- iterate bunkers and seal overlapping cells
  if g_currentMission and g_currentMission.placeableSystem then
    for _, placeable in ipairs(g_currentMission.placeableSystem:getBunkerSilos() or {}) do
      local bunkers = nil
      if placeable.spec_multiBunkerSilo and placeable.spec_multiBunkerSilo.bunkerSilos then
        bunkers = placeable.spec_multiBunkerSilo.bunkerSilos
      elseif placeable.spec_bunkerSilo and placeable.spec_bunkerSilo.bunkerSilo then
        bunkers = { placeable.spec_bunkerSilo.bunkerSilo }
      end
      if bunkers then
        for _, bunker in ipairs(bunkers) do
          local area = bunker.bunkerSiloArea
          if area and isPointInBunkerArea(area, tx, tz) then
            -- get ASF grid for this bunker
            local extra = (bunker.asfAdvancedSilage or nil)
            if extra and extra.seal and extra.seal.cellPositions then
              local radius2 = sealRadius * sealRadius
              local changed = false
              for i, pos in ipairs(extra.seal.cellPositions) do
                local dx = pos.x - tx
                local dz = pos.z - tz
                if dx * dx + dz * dz <= radius2 then
                  if not extra.seal.cells[i] then
                    extra.seal.cells[i] = true
                    extra.seal.sealedCount = (extra.seal.sealedCount or 0) + 1
                    changed = true
                  end
                end
              end
              if changed and bunker.raiseDirtyFlags and bunker.bunkerSiloDirtyFlag then
                bunker:raiseDirtyFlags(bunker.bunkerSiloDirtyFlag)
              end
              -- log and stop (we found the bunker under the tire)
              print(string.format("[AdvancedBunkers] SealTire placed: sealed cells around (%.2f, %.2f) in bunker", tx, tz))
              return
            end
          end
        end
      end
    end
  end

  -- nothing found
  print("[AdvancedBunkers] SealTire placed: not on a closed bunker seal area.")
end
