---
--- BunkerSiloHUD.lua
--- Based on XPModder's Bunker Silo HUD (14.10.2020 / 03.12.2024)
--- Extended with ASF (Advanced Silage Fermentation) asfAdvancedSilage data
---

BunkerSiloHUD = {}

BunkerSiloHUD.metadata = {
  name = "Bunker Silo HUD",
  author = "XPModder / Racc00n (ASF)",
  version = "3.1.0",
  created = "14.10.2020",
  updated = "03.12.2024",
  fsVersion = "25",
  info = "Bunker silo HUD with ASF sealing, oxygen and silage loss"
}

BunkerSiloHUD.path = tostring(g_currentModDirectory .. "back.dds")
BunkerSiloHUD.posX = 0.6
BunkerSiloHUD.posY = 0.8
BunkerSiloHUD.size = 0.018
BunkerSiloHUD.sizeHeader = 0.020
BunkerSiloHUD.sizeASF = 0.016
BunkerSiloHUD.width = 0.12
BunkerSiloHUD.height = 0.14
BunkerSiloHUD.heightWithASF = 0.20

BunkerSiloHUD.backgroundOL = g_currentModDirectory .. "back.dds"
BunkerSiloHUD.drawOverlay = false

BunkerSiloHUD.line1 = ""
BunkerSiloHUD.line2 = ""
BunkerSiloHUD.line3 = ""
BunkerSiloHUD.line4 = ""
BunkerSiloHUD.line5 = ""
BunkerSiloHUD.line6 = ""
BunkerSiloHUD.line7 = ""
BunkerSiloHUD.line8 = ""
BunkerSiloHUD.line9 = ""
BunkerSiloHUD.line10 = ""

function BunkerSiloHUD.updateSilo(self, superFunc, dt)
  local returnValue = superFunc(self, dt)

  if self == nil then
    return returnValue
  end

  if self:getCanInteract(true) then
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.isVisible then
      if not g_gui:getIsGuiVisible() then
        self.currentFillLevel = math.ceil(self.fillLevel or 0)

        if self.state == BunkerSilo.STATE_FILL then
          self.currentFermentingPercent = 0
          self.currentCompactedPercent = self.compactedPercent or 0
        else
          self.currentFermentingPercent = math.ceil((self.fermentingPercent or 0) * 100)
          self.currentCompactedPercent = 100
        end

        local fillTypeIndex = self.inputFillType or 0
        if self.state == BunkerSilo.STATE_CLOSED or self.state == BunkerSilo.STATE_FERMENTED or self.state == BunkerSilo.STATE_DRAIN then
          fillTypeIndex = self.outputFillType or fillTypeIndex
        end

        local fillTypeName = "?"
        local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil and fillType.title then
          fillTypeName = fillType.title
        end

        local fillTypeLabel = "Fill type: " .. tostring(fillTypeName)
        local fillLevelLabel = "Fill level: " .. tostring(math.ceil(self.fillLevel or 0)) .. " L"
        local compacted = "Compacted: " .. tostring(self.compactedPercent or 0) .. "%"
        local fermented = "Fermenting: " .. tostring(self.currentFermentingPercent or 0) .. "%"
        local currentVehicle = g_localPlayer:getCurrentVehicle()
        local vehicleLabel = "Vehicle: " .. (currentVehicle ~= nil and tostring(currentVehicle:getName()) or "None")
        local vehicleMassLabel = string.format("Vehicle mass: %.1f T", 0)
        local vehicleSpeedLabel = string.format("Vehicle speed: %.1f km/h",
          currentVehicle ~= nil and currentVehicle:getLastSpeed() or 0)

        BunkerSiloHUD.line1 = tostring(fillTypeLabel)
        BunkerSiloHUD.line2 = tostring(fillLevelLabel)
        BunkerSiloHUD.line3 = ""
        BunkerSiloHUD.line4 = ""
        BunkerSiloHUD.line5 = ""
        BunkerSiloHUD.line6 = ""
        BunkerSiloHUD.line7 = ""
        BunkerSiloHUD.line8 = tostring(vehicleLabel)
        BunkerSiloHUD.line9 = tostring(vehicleMassLabel)
        BunkerSiloHUD.line10 = tostring(vehicleSpeedLabel)

        if self.state == BunkerSilo.STATE_CLOSED or self.state == BunkerSilo.STATE_FERMENTED then
          BunkerSiloHUD.line3 = tostring(fermented)
        elseif self.state == BunkerSilo.STATE_FILL then
          BunkerSiloHUD.line3 = tostring(compacted)
        end

        -- ASF state model: seal efficiency, oxygen and silage loss
        local asf = self.asfAdvancedSilage
        if asf ~= nil then
          local sealPct = math.floor((asf.sealEfficiency or 0) * 100)
          local oxyPct = math.floor((asf.oxygen or 0) * 100)
          local lossLiters = math.floor(asf.silageLoss or 0)
          BunkerSiloHUD.line4 = string.format("Seal efficiency: %d%%", sealPct)
          BunkerSiloHUD.line5 = string.format("Oxygen: %d%%", oxyPct)
          BunkerSiloHUD.line6 = string.format("Silage loss: %d L", lossLiters)
          if self.state == BunkerSilo.STATE_CLOSED or self.state == BunkerSilo.STATE_FERMENTED then
            BunkerSiloHUD.line7 = string.format("Cover weight: %.1f", asf.coverWeight or 0)
          elseif self.state == BunkerSilo.STATE_DRAIN then
            BunkerSiloHUD.line7 = string.format("Initial fill: %d L", math.floor(asf.initialFillLevel or 0))
          end
        end

        BunkerSiloHUD.drawOverlay = true
      end
    end
  end

  return returnValue
end

function BunkerSiloHUD:loadMap(filename)
  if g_currentMission and g_currentMission.addDrawable then
    g_currentMission:addDrawable(self)
  end
  print("--- Mod: " ..
    BunkerSiloHUD.metadata.name .. ", Version " .. BunkerSiloHUD.metadata.version .. " (ASF) loaded! ---")
end

function BunkerSiloHUD:deleteMap()
  if g_currentMission and g_currentMission.removeDrawable then
    g_currentMission:removeDrawable(self)
  end
end

function BunkerSiloHUD.createImageOverlay(texturePath, useASFHeight)
  local w = BunkerSiloHUD.width
  local h = (useASFHeight and (BunkerSiloHUD.line4 ~= "" or BunkerSiloHUD.line5 ~= "" or BunkerSiloHUD.line6 ~= "" or BunkerSiloHUD.line7 ~= "" or BunkerSiloHUD.line8 ~= "" or BunkerSiloHUD.line9 ~= "" or BunkerSiloHUD.line10 ~= "")) and
      BunkerSiloHUD.heightWithASF or BunkerSiloHUD.height
  return Overlay.new(texturePath, BunkerSiloHUD.posX - 0.008, BunkerSiloHUD.posY - 0.08, w, h)
end

function BunkerSiloHUD:draw()
  if not BunkerSiloHUD.drawOverlay then
    return
  end
  if g_currentMission and g_currentMission.hud and not g_currentMission.hud.isVisible then
    return
  end

  local hasASF = BunkerSiloHUD.line4 ~= "" or BunkerSiloHUD.line5 ~= "" or BunkerSiloHUD.line6 ~= "" or
      BunkerSiloHUD.line7 ~= "" or BunkerSiloHUD.line8 ~= "" or BunkerSiloHUD.line9 ~= "" or BunkerSiloHUD.line10 ~= ""
  local overlay = BunkerSiloHUD.createImageOverlay(BunkerSiloHUD.backgroundOL, hasASF)

  overlay:setColor(1.0, 1.0, 1.0, 1.0)
  overlay:render()

  setTextColor(1, 1, 1, 1)
  setTextAlignment(RenderText.ALIGN_LEFT)

  setTextBold(true)
  renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY + 0.03, BunkerSiloHUD.sizeHeader,
    "Bunker Silo")
  setTextBold(false)

  renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY, BunkerSiloHUD.size, tostring(BunkerSiloHUD.line1))
  renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.03, BunkerSiloHUD.size, tostring(BunkerSiloHUD.line2))
  renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.06, BunkerSiloHUD.size, tostring(BunkerSiloHUD.line3))

  if hasASF then
    renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.09, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line4))
    renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.105, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line5))
    if BunkerSiloHUD.line6 ~= "" then
      renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.12, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line6))
    end
    if BunkerSiloHUD.line7 ~= "" then
      renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.135, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line7))
    end
    if BunkerSiloHUD.line8 ~= "" then
      renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.15, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line8))
    end
    if BunkerSiloHUD.line9 ~= "" then
      renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.165, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line9))
    end
    if BunkerSiloHUD.line10 ~= "" then
      renderText(BunkerSiloHUD.posX, BunkerSiloHUD.posY - 0.18, BunkerSiloHUD.sizeASF, tostring(BunkerSiloHUD.line10))
    end
  end

  BunkerSiloHUD.drawOverlay = false
end

addModEventListener(BunkerSiloHUD)

if BunkerSilo and BunkerSilo.update then
  BunkerSilo.update = Utils.overwrittenFunction(BunkerSilo.update, BunkerSiloHUD.updateSilo)
end

-- Draw our overlay during gameplay (HUD.drawControlledEntityHUD is called when game is running and HUD visible)
if HUD and HUD.drawControlledEntityHUD then
  HUD.drawControlledEntityHUD = Utils.overwrittenFunction(HUD.drawControlledEntityHUD, function(self, superFunc)
    superFunc(self)
    if BunkerSiloHUD.drawOverlay and BunkerSiloHUD.draw ~= nil then
      BunkerSiloHUD:draw()
    end
  end)
end
