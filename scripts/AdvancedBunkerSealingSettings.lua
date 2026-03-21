AdvancedBunkerSealingSettings = {}
AdvancedBunkerSealingSettings.name = g_currentModName
AdvancedBunkerSealingSettings.modDir = g_currentModDirectory

local EPSILON = 0.000001

-- Discrete UI choices
AdvancedBunkerSealingSettings.LOSS_FACTOR_VALUES = { 0.5, 1.0, 2.0, 3.0 }
AdvancedBunkerSealingSettings.LOSS_FACTOR_STRINGS = { "0.5x", "1x", "2x", "3x" }

-- Stored as fraction (0..1). Default should match main.lua: 0.5 (50%)
AdvancedBunkerSealingSettings.MAX_LOSS_VALUES = {}
AdvancedBunkerSealingSettings.MAX_LOSS_STRINGS = {}
do
  local step = 0.05                                             -- 5%
  for v = 0, 0.5 + EPSILON, step do
    local value = math.floor((v + EPSILON) / step + 0.5) * step -- keep stable float
    table.insert(AdvancedBunkerSealingSettings.MAX_LOSS_VALUES, value)
    table.insert(AdvancedBunkerSealingSettings.MAX_LOSS_STRINGS, string.format("%d%%", math.floor(value * 100 + 0.5)))
  end
end

AdvancedBunkerSealingSettings.current = {
  debug = false,
  lossFactor = 1.0,
  maxLossPercent = 0.5,
  -- Hard = 0.8, Medium = 1.05, Easy = 1.2
  sealCoverageFactor = 1.05
}
AdvancedBunkerSealingSettings.controls = {}

function AdvancedBunkerSealingSettings:applyToModConfig()
  if not g_currentMission or not g_currentMission.AdvancedBunkerSealing then return end
  local cfg = g_currentMission.AdvancedBunkerSealing.config
  if not cfg then return end

  cfg.debug = self.current.debug
  cfg.lossFactor = self.current.lossFactor
  cfg.maxLossPercent = self.current.maxLossPercent
  cfg.sealCoverageFactor = self.current.sealCoverageFactor
end

function AdvancedBunkerSealingSettings:getStateIndex(values, value)
  for i, v in ipairs(values) do
    if math.abs(v - value) <= EPSILON then
      return i
    end
  end
  return 1
end

-- Network sync (client -> server -> all clients)
AdvancedBunkerSealingSettingsEvent = {}
AdvancedBunkerSealingSettingsEvent_mt = Class(AdvancedBunkerSealingSettingsEvent, Event)
InitEventClass(AdvancedBunkerSealingSettingsEvent, "AdvancedBunkerSealingSettingsEvent")

function AdvancedBunkerSealingSettingsEvent.emptyNew()
  local self = Event.new(AdvancedBunkerSealingSettingsEvent_mt)
  return self
end

function AdvancedBunkerSealingSettingsEvent.new(settings)
  local self = AdvancedBunkerSealingSettingsEvent.emptyNew()
  self.debug = settings.debug
  self.lossFactor = settings.lossFactor
  self.maxLossPercent = settings.maxLossPercent
  self.sealCoverageFactor = settings.sealCoverageFactor
  return self
end

function AdvancedBunkerSealingSettingsEvent:readStream(streamId, connection)
  self.debug = streamReadBool(streamId)
  self.lossFactor = streamReadFloat32(streamId)
  self.maxLossPercent = streamReadFloat32(streamId)
  self.sealCoverageFactor = streamReadFloat32(streamId)
  self:run(connection)
end

function AdvancedBunkerSealingSettingsEvent:writeStream(streamId, connection)
  streamWriteBool(streamId, self.debug)
  streamWriteFloat32(streamId, self.lossFactor)
  streamWriteFloat32(streamId, self.maxLossPercent)
  streamWriteFloat32(streamId, self.sealCoverageFactor)
end

function AdvancedBunkerSealingSettingsEvent:run(connection)
  if not connection:getIsServer() then
    -- Client side
    AdvancedBunkerSealingSettings.current.debug = self.debug
    AdvancedBunkerSealingSettings.current.lossFactor = self.lossFactor
    AdvancedBunkerSealingSettings.current.maxLossPercent = self.maxLossPercent
    AdvancedBunkerSealingSettings.current.sealCoverageFactor = self.sealCoverageFactor
    AdvancedBunkerSealingSettings:applyToModConfig()
  else
    -- Server side
    AdvancedBunkerSealingSettings.current.debug = self.debug
    AdvancedBunkerSealingSettings.current.lossFactor = self.lossFactor
    AdvancedBunkerSealingSettings.current.maxLossPercent = self.maxLossPercent
    AdvancedBunkerSealingSettings.current.sealCoverageFactor = self.sealCoverageFactor
    AdvancedBunkerSealingSettings:applyToModConfig()

    if g_server ~= nil then
      g_server:broadcastEvent(AdvancedBunkerSealingSettingsEvent.new(AdvancedBunkerSealingSettings.current))
    end
  end
end

AdvancedBunkerSealingLoadSettingsEvent = {}
AdvancedBunkerSealingLoadSettingsEvent_mt = Class(AdvancedBunkerSealingLoadSettingsEvent, Event)
InitEventClass(AdvancedBunkerSealingLoadSettingsEvent, "AdvancedBunkerSealingLoadSettingsEvent")

function AdvancedBunkerSealingLoadSettingsEvent.emptyNew()
  local self = Event.new(AdvancedBunkerSealingLoadSettingsEvent_mt)
  return self
end

function AdvancedBunkerSealingLoadSettingsEvent.new()
  return AdvancedBunkerSealingLoadSettingsEvent.emptyNew()
end

function AdvancedBunkerSealingLoadSettingsEvent:readStream(streamId, connection)
  self:run(connection)
end

function AdvancedBunkerSealingLoadSettingsEvent:writeStream(streamId, connection)
end

function AdvancedBunkerSealingLoadSettingsEvent:run(connection)
  if connection:getIsServer() then
    if g_server ~= nil then
      g_server:broadcastEvent(AdvancedBunkerSealingSettingsEvent.new(AdvancedBunkerSealingSettings.current))
    end
  end
end

function AdvancedBunkerSealingSettings:sendCurrentToServer()
  if not g_client or g_client == nil then return end
  if not g_currentMission or g_currentMission == nil then return end
  if g_currentMission:getIsServer() then return end

  local conn = g_client:getServerConnection()
  if conn ~= nil then
    conn:sendEvent(AdvancedBunkerSealingSettingsEvent.new(self.current))
  end
end

function AdvancedBunkerSealingSettings:requestLoadFromServer()
  if not g_client or g_client == nil then return end
  if not g_currentMission or g_currentMission == nil then return end
  if g_currentMission:getIsServer() then return end

  local conn = g_client:getServerConnection()
  if conn ~= nil then
    conn:sendEvent(AdvancedBunkerSealingLoadSettingsEvent.new())
  end
end

function AdvancedBunkerSealingSettings:updateGameSettings()
  local settingsPage = g_inGameMenu and g_inGameMenu.pageSettings
  if not settingsPage then return end

  local debugCtrl = self.controls.debug
  if debugCtrl ~= nil then
    debugCtrl:setState(self.current.debug and 2 or 1)
  end

  local lfCtrl = self.controls.lossFactor
  if lfCtrl ~= nil then
    lfCtrl:setState(self:getStateIndex(self.LOSS_FACTOR_VALUES, self.current.lossFactor))
  end

  local mlCtrl = self.controls.maxLossPercent
  if mlCtrl ~= nil then
    mlCtrl:setState(self:getStateIndex(self.MAX_LOSS_VALUES, self.current.maxLossPercent))
  end

  local scCtrl = self.controls.sealCoverageFactor
  if scCtrl ~= nil then
    scCtrl:setState(self:getStateIndex(self.SEAL_COVERAGE_VALUES, self.current.sealCoverageFactor))
  end
end

-- Seal difficulty UI choices (global coverage scaling).
AdvancedBunkerSealingSettings.SEAL_COVERAGE_VALUES = { 1.2, 1.4, 1.6 }
AdvancedBunkerSealingSettings.SEAL_COVERAGE_STRINGS = { "Hard", "Medium", "Easy" }

function AdvancedBunkerSealingSettings:addBinarySettingsOption(scrollPanel, settingsPage, settingName, titleKey,
                                                               tooltipKey)
  local function updateSetting(_, state)
    if state == 2 then
      self.current[settingName] = true
    else
      self.current[settingName] = false
    end

    self:applyToModConfig()
    self:sendCurrentToServer()
  end

  local parent = self.binaryOptionElement:clone(scrollPanel)
  local newOption = parent.elements[1]
  parent.id = nil

  parent.elements[2]:setText(g_i18n:getText(titleKey))

  newOption.elements[1]:setText(g_i18n:getText(tooltipKey))
  newOption.id = settingName .. "_Id"
  newOption.onClickCallback = updateSetting

  newOption:setState(self.current[settingName] and 2 or 1)

  self.controls[settingName] = newOption

  parent:setVisible(true)
  parent:setDisabled(false)
end

function AdvancedBunkerSealingSettings:addMultiTextSettingsOption(scrollPanel, settingsPage, settingName, values, strings,
                                                                  titleKey, tooltipKey)
  local function updateSetting(_, state)
    local value = values[state] or values[1]
    self.current[settingName] = value

    self:applyToModConfig()
    self:sendCurrentToServer()
  end

  local parent = self.multiTextOption:clone(scrollPanel)
  local newOption = parent.elements[1]
  parent.id = nil

  parent.elements[2]:setText(g_i18n:getText(titleKey))

  newOption.elements[1]:setText(g_i18n:getText(tooltipKey))
  newOption.id = settingName .. "_Id"
  newOption.onClickCallback = updateSetting

  newOption:setTexts(strings)

  -- Set initial state
  local stateIndex = self:getStateIndex(values, self.current[settingName])
  newOption:setState(stateIndex)

  self.controls[settingName] = newOption

  parent:setVisible(true)
  parent:setDisabled(false)
end

function AdvancedBunkerSealingSettings:extendSettingsScreen()
  if not g_inGameMenu or not g_inGameMenu.pageSettings then return end
  local settingsPage = g_inGameMenu.pageSettings
  local scrollPanel = settingsPage.gameSettingsLayout

  if not scrollPanel or not scrollPanel.elements then return end

  -- Find template elements on the settings page
  for _, element in pairs(scrollPanel.elements) do
    if element.name == "sectionHeader" then
      self.sectionHeader = element:clone(scrollPanel)
    end

    if element.typeName == "Bitmap" and element.elements and element.elements[1] then
      if element.elements[1].typeName == "BinaryOption" then
        self.binaryOptionElement = element
      end
      if element.elements[1].typeName == "MultiTextOption" then
        self.multiTextOption = element
      end
    end

    if self.sectionHeader ~= nil and self.binaryOptionElement ~= nil and self.multiTextOption ~= nil then
      break
    end
  end

  if self.sectionHeader == nil or self.binaryOptionElement == nil or self.multiTextOption == nil then
    return
  end

  self.sectionHeader:setText(g_i18n:getText("advancedBunkerSealing_settings_title"))

  self:addBinarySettingsOption(scrollPanel, settingsPage, "debug",
    "advancedBunkerSealing_debug_title", "advancedBunkerSealing_debug_tooltip")

  self:addMultiTextSettingsOption(scrollPanel, settingsPage, "lossFactor",
    self.LOSS_FACTOR_VALUES, self.LOSS_FACTOR_STRINGS,
    "advancedBunkerSealing_lossFactor_title", "advancedBunkerSealing_lossFactor_tooltip")

  self:addMultiTextSettingsOption(scrollPanel, settingsPage, "maxLossPercent",
    self.MAX_LOSS_VALUES, self.MAX_LOSS_STRINGS,
    "advancedBunkerSealing_maxLossPercent_title", "advancedBunkerSealing_maxLossPercent_tooltip")

  self:addMultiTextSettingsOption(scrollPanel, settingsPage, "sealCoverageFactor",
    self.SEAL_COVERAGE_VALUES, self.SEAL_COVERAGE_STRINGS,
    "advancedBunkerSealing_sealDifficulty_title", "advancedBunkerSealing_sealDifficulty_tooltip")

  scrollPanel:invalidateLayout()
end

function AdvancedBunkerSealingSettings.init()
  -- Initialize defaults from mod config if available
  if g_currentMission and g_currentMission.AdvancedBunkerSealing and g_currentMission.AdvancedBunkerSealing.config then
    local cfg = g_currentMission.AdvancedBunkerSealing.config
    AdvancedBunkerSealingSettings.current.debug = cfg.debug ~= nil and cfg.debug or
        AdvancedBunkerSealingSettings.current.debug
    AdvancedBunkerSealingSettings.current.lossFactor = cfg.lossFactor ~= nil and cfg.lossFactor or
        AdvancedBunkerSealingSettings.current.lossFactor
    AdvancedBunkerSealingSettings.current.maxLossPercent = cfg.maxLossPercent ~= nil and cfg.maxLossPercent or
        AdvancedBunkerSealingSettings.current.maxLossPercent
    AdvancedBunkerSealingSettings.current.sealCoverageFactor = cfg.sealCoverageFactor ~= nil and cfg.sealCoverageFactor or
        AdvancedBunkerSealingSettings.current.sealCoverageFactor
  end

  AdvancedBunkerSealingSettings:applyToModConfig()

  InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGameSettings,
    function()
      AdvancedBunkerSealingSettings:updateGameSettings()
    end)

  -- Inject settings once the mission is fully loaded (menu exists then).
  Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    AdvancedBunkerSealingSettings:extendSettingsScreen()
  end)

  -- Request settings from server in MP when joining.
  FSBaseMission.onConnectionFinishedLoading = Utils.appendedFunction(FSBaseMission.onConnectionFinishedLoading,
    function()
      AdvancedBunkerSealingSettings:requestLoadFromServer()
    end)
end

AdvancedBunkerSealingSettings.init()
