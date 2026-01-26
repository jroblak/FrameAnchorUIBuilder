-- ============================================================================
-- Frame Anchor UI Builder - Frame Anchoring Addon for World of Warcraft
-- ============================================================================

local AddonName = "FrameAnchor"

local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local wipe = wipe
local tinsert = table.insert
local abs = math.abs
local format = string.format
local pcall = pcall

-- WoW API locals
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local GetMouseFoci = GetMouseFoci
local GetMouseFocus = GetMouseFocus
local UnitName = UnitName
local GetRealmName = GetRealmName
local ReloadUI = ReloadUI
local StaticPopup_Show = StaticPopup_Show
local hooksecurefunc = hooksecurefunc
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings
local C_Timer = C_Timer

local UIParent = UIParent
local WorldFrame = WorldFrame

-- ============================================================================
-- LIBRARY INITIALIZATION
-- ============================================================================
local LibStub = _G.LibStub
if not LibStub then
    error("FrameAnchor requires LibStub. Please ensure it is installed.")
end

local function SafeGetLib(name, silent)
    local lib = LibStub(name, silent)
    if not lib and not silent then
        error(format("FrameAnchor requires %s. Please ensure it is installed.", name))
    end
    return lib
end

local AceAddon = SafeGetLib("AceAddon-3.0")
local FA = AceAddon:NewAddon(AddonName, "AceConsole-3.0", "AceSerializer-3.0")
local AC = SafeGetLib("AceConfig-3.0")
local ACD = SafeGetLib("AceConfigDialog-3.0")
local ACR = SafeGetLib("AceConfigRegistry-3.0")
local LD = SafeGetLib("LibDeflate")

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local POINTS = {
    ["TOPLEFT"] = "Top Left", 
    ["TOP"] = "Top", 
    ["TOPRIGHT"] = "Top Right",
    ["LEFT"] = "Left", 
    ["CENTER"] = "Center", 
    ["RIGHT"] = "Right",
    ["BOTTOMLEFT"] = "Bottom Left", 
    ["BOTTOM"] = "Bottom", 
    ["BOTTOMRIGHT"] = "Bottom Right"
}

local ICON_EXPAND = "|TInterface\\Buttons\\UI-PlusButton-Up:16|t " 
local ICON_COLLAPSE = "|TInterface\\Buttons\\UI-MinusButton-Up:16|t "

local PICKER_UPDATE_INTERVAL = 0.05   -- 20 updates per second (throttled)
local POSITION_TOLERANCE = 0.05       -- Tolerance for position comparisons
local EDIT_MODE_DURATION = 300        -- 5 minutes in seconds
local APPLY_DEBOUNCE_TIME = 0.1       -- Debounce time for anchor application

-- ============================================================================
-- INITIALIZATION & MIGRATION
-- ============================================================================

function FA:OnInitialize()
    self.state = {
        creationFrame = nil,
        pickerActive = false,
        pickerSource = nil,
        currentCallback = nil,
        visualLayerIndex = 1,
        selectedFrame = nil,
        manualSelection = nil,
        exportString = "",
        expandedStates = {},
        validFrames = {},
        ctrlLock = false,
    }
    
    self.editModeActive = false
    self.editModeTimer = nil
    self.forceUpdate = false
    
    self.cachedOptions = nil
    self.optionsDirty = true
    
    self.navButtons = nil
    self.highlighter = nil
    self.hud = nil
    self.eventFrame = nil
    self.applyTimer = nil
    
    local defaults = {
        global = { links = nil },
        profile = { 
            links = {},
            perfMode = "LIGHT" -- Options: STRICT, LIGHT, YOLO
        }
    }
    
    local charProfile = UnitName("player") .. " - " .. GetRealmName()
    self.db = LibStub("AceDB-3.0"):New("FrameAnchorDB", defaults, charProfile)
    
    if not StaticPopupDialogs["FRAMEANCHOR_RELOAD_CONFIRM"] then
        StaticPopupDialogs["FRAMEANCHOR_RELOAD_CONFIRM"] = {
            text = "|cff00ff00[FrameAnchor]|r\n\nAnchor deleted.\n\nA UI Reload is required to fully reset the frame's position.\n\nReload now?",
            button1 = "Reload UI",
            button2 = "Wait",
            OnAccept = function() ReloadUI() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    AC:RegisterOptionsTable(AddonName, function() return self:GetOptions() end)
    local profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    AC:RegisterOptionsTable(AddonName .. "_Profiles", profiles)

    self.optionsFrame = ACD:AddToBlizOptions(AddonName, AddonName)
    self.profilesFrame = ACD:AddToBlizOptions(AddonName .. "_Profiles", "Profiles", AddonName)
    
    self:RegisterChatCommand("fa", "OnSlashCommand")
    self:RegisterChatCommand("frameanchor", "OnSlashCommand")
    
    self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileCopied", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig")
end

function FA:OnEnable()
    if not self.eventFrame then
        self.eventFrame = CreateFrame("Frame")
        self.eventFrame:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_ENTERING_WORLD" then
                FA:OnWorldLoad()
            end
        end)
    end
    self.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
end

function FA:OnDisable()
    if self.eventFrame then
        self.eventFrame:UnregisterAllEvents()
    end
    
    if self.applyTimer then
        self.applyTimer:Cancel()
        self.applyTimer = nil
    end
    
    if self.editModeTimer then
        self.editModeTimer:Cancel()
        self.editModeTimer = nil
    end
end

function FA:OnWorldLoad()
    local attempt = 0
    local function TryApply()
        attempt = attempt + 1
        FA:ApplyAllAnchors()
        
        if attempt < 4 then
            local delay = (attempt == 1) and 1 or (attempt == 2) and 2 or 4
            C_Timer.After(delay, TryApply)
        end
    end
    TryApply()
end

function FA:RefreshConfig()
    self:InvalidateOptions()
    self:ApplyAllAnchors()
end

function FA:OnSlashCommand(input)
    if InCombatLockdown() then
        self:Print("|cffff0000Cannot open settings during combat.|r")
        return
    end
    ACD:Open(AddonName)
end

-- ============================================================================
-- OPTIONS CACHE MANAGEMENT
-- ============================================================================

function FA:InvalidateOptions()
    self.optionsDirty = true
    ACR:NotifyChange(AddonName)
end

-- ============================================================================
-- CORE ANCHOR LOGIC & MODES
-- ============================================================================

function FA:ToggleEditMode(enable)
    if enable then
        self.editModeActive = true
        self:Print("Edit Mode ENABLED (5 Minutes)")
        
        if self.editModeTimer then 
            self.editModeTimer:Cancel() 
        end
        self.editModeTimer = C_Timer.NewTimer(EDIT_MODE_DURATION, function() 
            FA:ToggleEditMode(false) 
        end)
    else
        self.editModeActive = false
        if self.editModeTimer then 
            self.editModeTimer:Cancel() 
            self.editModeTimer = nil
        end
        self:Print("|cffff0000Edit Mode DISABLED. Anchors locked.|r")
    end
    
    self:InvalidateOptions()
    self:ApplyAllAnchors() 
end

function FA:ScheduleApplyAnchors()
    if self.applyTimer then
        self.applyTimer:Cancel()
    end
    self.applyTimer = C_Timer.NewTimer(APPLY_DEBOUNCE_TIME, function()
        FA:ApplyAllAnchors()
        FA.applyTimer = nil
    end)
end

function FA:ApplyAllAnchors()
    if InCombatLockdown() then return end

    self.forceUpdate = true
    
    for childName, data in pairs(self.db.profile.links) do
        local success, err = pcall(function()
            local child = _G[childName]
            local parent = _G[data.parent]
            if child and parent then
                local p1 = data.point or "CENTER"
                local p2 = data.relPoint or "CENTER"
                self:SecureAnchor(childName, child, parent, p1, p2, data.x, data.y)
            end
        end)
        
        if not success then
            self:HandleAnchorError(childName, err)
        end
    end

    self.forceUpdate = false
end

function FA:HandleAnchorError(childName, err)
    if not self.errorLog then
        self.errorLog = {}
    end
    
    local now = GetTime()
    if not self.errorLog[childName] or (now - self.errorLog[childName]) > 60 then
        self:Print(format("|cffff0000Anchor error for %s: %s|r", childName, tostring(err)))
        self.errorLog[childName] = now
    end
end

function FA:SecureAnchor(childName, child, parent, point, relPoint, x, y)
    child.fa_anchorData = {
        parent = parent,
        point = point,
        relPoint = relPoint,
        x = x or 0,
        y = y or 0
    }

    if not child.fa_isHooked then
        hooksecurefunc(child, "SetPoint", function(frame)
            FA:EnforceAnchor(frame)
        end)
        child.fa_isHooked = true
    end
    
    self:EnforceAnchor(child)
end

function FA:EnforceAnchor(child)
    if not child then return end
    if not child.fa_anchorData then return end
    if InCombatLockdown() then return end
    if child.fa_isMoving then return end  -- Prevent infinite loops
    
    local data = child.fa_anchorData
    local parent = data.parent
    local point = data.point
    local relPoint = data.relPoint
    local x = data.x
    local y = data.y
    
    if not parent or not parent.GetObjectType then return end
    
    local mode = self.db.profile.perfMode or "LIGHT"
    
    -- STRICT mode: only enforce during edit mode or force updates
    if mode == "STRICT" and not self.editModeActive and not self.forceUpdate then
        return
    end

    -- LIGHT mode: check if position actually changed
    if mode ~= "YOLO" then
        local success, currP, currRel, currRelP, currX, currY = pcall(child.GetPoint, child)
        if success and currP == point and currRel == parent and currRelP == relPoint and 
           abs((currX or 0) - x) < POSITION_TOLERANCE and 
           abs((currY or 0) - y) < POSITION_TOLERANCE then
            return 
        end
    end

    child.fa_isMoving = true
    
    local success, err = pcall(function()
        child:ClearAllPoints()
        child:SetPoint(point, parent, relPoint, x, y)
    end)
    
    child.fa_isMoving = false
    
    if not success then
        child.fa_anchorData = nil
        child.fa_isHooked = nil
    end
end

-- ============================================================================
-- IMPORT / EXPORT
-- ============================================================================

function FA:ExportProfile()
    local serialized = self:Serialize(self.db.profile.links)
    if not serialized then return "" end
    
    local compressed = LD:CompressDeflate(serialized)
    if not compressed then return "" end
    
    return LD:EncodeForPrint(compressed) or ""
end

function FA:ImportProfile(str)
    if not str or str == "" then 
        self:Print("Import failed: Empty string.")
        return 
    end
    
    local decoded = LD:DecodeForPrint(str)
    if not decoded then 
        self:Print("Import failed: Invalid string format.")
        return 
    end
    
    local decompressed = LD:DecompressDeflate(decoded)
    if not decompressed then 
        self:Print("Import failed: Decompression error.")
        return 
    end
    
    local success, newLinks = self:Deserialize(decompressed)
    if not success then 
        self:Print("Import failed: Deserialization error.")
        return 
    end

    self.db.profile.links = newLinks
    self:InvalidateOptions()
    self:ApplyAllAnchors()
    self:Print("Profile imported successfully!")
end

-- ============================================================================
-- THE POP-OUT CREATOR
-- ============================================================================

function FA:ShowCreationFrame()
    if InCombatLockdown() then
        self:Print("|cffff0000Cannot open during combat.|r")
        return
    end
    
    if self.state.creationFrame then 
        self.state.creationFrame:Show() 
        self.state.creationFrame:Raise() 
        return 
    end

    local f = CreateFrame("Frame", "FACreationFrame", UIParent, "BackdropTemplate")
    f:SetSize(320, 300) 
    f:SetPoint("CENTER")
    
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(100)
    f:SetToplevel(true)         
    
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    tinsert(UISpecialFrames, "FACreationFrame") 
    
    f:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -15)
    title:SetText("New Frame Anchor")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetFrameLevel(f:GetFrameLevel() + 20)
    close:SetScript("OnClick", function() f:Hide() end)

    local function CreateInput(label, subtext, yOffset, showPicker)
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", 25, yOffset)
        lbl:SetText(label)
        
        local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        eb:SetSize(200, 20)
        eb:SetPoint("TOPLEFT", 25, yOffset - 20)
        eb:SetAutoFocus(false)
        
        if subtext then
            local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sub:SetPoint("TOPLEFT", 25, yOffset - 42)
            sub:SetText(subtext)
            sub:SetTextColor(0.6, 0.6, 0.6) 
        end
        
        local pickBtn = nil
        if showPicker then
            pickBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            pickBtn:SetSize(50, 20)
            pickBtn:SetPoint("LEFT", eb, "RIGHT", 5, 0)
            pickBtn:SetText("Pick")
        end
        return eb, pickBtn
    end

    local pEdit, pPick = CreateInput("Anchor To (Parent):", "The stationary frame you are attaching TO.", -50, true)
    local cEdit, cPick = CreateInput("Anchor From (Child):", "The frame that will MOVE with the parent.", -120, true)
    local nEdit, _     = CreateInput("Display Name (Optional):", nil, -190, false)
    
    pPick:SetScript("OnClick", function() 
        f:Hide()
        FA:StartPicker(function(name) pEdit:SetText(name) f:Show() end, "CREATION_FRAME") 
    end)
    cPick:SetScript("OnClick", function() 
        f:Hide() 
        FA:StartPicker(function(name) cEdit:SetText(name) f:Show() end, "CREATION_FRAME") 
    end)

    local createBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    createBtn:SetSize(120, 30)
    createBtn:SetPoint("BOTTOM", 0, 25)
    createBtn:SetText("Create Link")
    createBtn:SetScript("OnClick", function()
        local p, c = pEdit:GetText(), cEdit:GetText()
        local n = nEdit:GetText()
        
        if p == "" or c == "" then 
            FA:Print("Please select both parent and child frames.")
            return 
        end
        
        if p == c then 
            FA:Print("Parent and child cannot be the same frame.")
            return 
        end
        
        FA.db.profile.links[c] = { 
            parent = p, 
            customName = (n ~= "" and n or nil), 
            point = "CENTER", 
            relPoint = "CENTER", 
            x = 0, 
            y = 0 
        }
        
        FA.state.expandedStates[c] = true
        FA:InvalidateOptions()
        FA:ApplyAllAnchors()
        
        cEdit:SetText("")
        nEdit:SetText("")
        f:Hide()
        
        ACD:Open(AddonName) 
        ACD:SelectGroup(AddonName, "anchors")
    end)

    self.state.creationFrame = f
end

-- ============================================================================
-- OPTIONS TABLE
-- ============================================================================

function FA:GetOptions()
    -- Return cached options if valid
    if self.cachedOptions and not self.optionsDirty then
        return self.cachedOptions
    end
    
    local state = self.state
    
    local options = {
        name = "Frame Anchor", 
        handler = FA, 
        type = "group", 
        childGroups = "tab", 
        args = {
            anchors = {
                order = 1, 
                type = "group", 
                name = "Anchors",
                args = {
                    perfHeader = { 
                        order = 0.1, 
                        type = "header", 
                        name = "Performance Settings" 
                    },
                    perfMode = {
                        order = 0.2, 
                        type = "select", 
                        name = "Engine Mode",
                        desc = "STRICT: Highest performance. Only sets anchor on Login or Edit Mode.\nLIGHT: Resets anchor if parent frame changes (throttled, out of combat only).\nYOLO: Forces link connection every update (High CPU).",
                        values = { 
                            ["STRICT"] = "Strict (Manual)", 
                            ["LIGHT"] = "Light (Smart)", 
                            ["YOLO"] = "YOLO (Force)" 
                        },
                        get = function() return FA.db.profile.perfMode end,
                        set = function(_, v) 
                            FA.db.profile.perfMode = v 
                            FA:ApplyAllAnchors() 
                        end
                    },
                    editModeBtn = {
                        order = 0.3, 
                        type = "execute",
                        name = function() 
                            return FA.editModeActive and "DISABLE EDIT MODE" or "ENABLE EDIT MODE (5m)" 
                        end,
                        desc = "Temporarily enables anchor enforcement so you can move things around.",
                        disabled = function() return FA.db.profile.perfMode == "YOLO" end, 
                        func = function() FA:ToggleEditMode(not FA.editModeActive) end,
                        width = "double",
                    },
                    space1 = { order = 0.4, type = "description", name = "\n" },

                    createBtn = { 
                        order = 1, 
                        type = "execute", 
                        name = "Create New Anchor...", 
                        width = "full", 
                        func = function() FA:ShowCreationFrame() end 
                    },
                    space2 = { order = 2, type = "description", name = "\n" },
                    header = { order = 3, type = "header", name = "Active Anchors" },
                    list = { order = 10, type = "group", inline = true, name = "", args = {} }
                }
            },
            share = {
                order = 2, 
                type = "group", 
                name = "Import / Export",
                args = {
                    header = { order = 1, type = "header", name = "Share Profile" },
                    desc = { order = 2, type = "description", name = "Copy string to share, or paste to import." },
                    exportBtn = { 
                        order = 3, 
                        type = "execute", 
                        name = "Generate Export String", 
                        func = function() 
                            state.exportString = FA:ExportProfile() 
                        end 
                    },
                    ioBox = { 
                        order = 4, 
                        type = "input", 
                        name = "String", 
                        width = "full", 
                        multiline = 10, 
                        get = function() return state.exportString end, 
                        set = function(_, v) state.exportString = v end 
                    },
                    importBtn = { 
                        order = 5, 
                        type = "execute", 
                        name = "Import", 
                        confirm = true, 
                        confirmText = "Overwrite profile?", 
                        func = function() FA:ImportProfile(state.exportString) end 
                    }
                }
            },
        }
    }

    local i = 1
    for childName, data in pairs(self.db.profile.links) do
        local dName = data.customName and (data.customName .. " (" .. childName .. ")") or childName
        local isExpanded = state.expandedStates[childName]
        local icon = isExpanded and ICON_COLLAPSE or ICON_EXPAND
        local toggleName = icon .. dName

        options.args.anchors.args.list.args[childName] = {
            type = "group", 
            name = "", 
            order = i, 
            inline = true, 
            args = {
                toggle = {
                    order = 0, 
                    type = "execute", 
                    name = toggleName, 
                    width = "full",
                    func = function() 
                        state.expandedStates[childName] = not state.expandedStates[childName] 
                        FA:InvalidateOptions()
                    end
                },
                
                detailsH = { 
                    order = 0.5, 
                    type = "header", 
                    name = "Link Details", 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                infoP = { 
                    order = 0.6, 
                    type = "description", 
                    fontSize = "medium",
                    name = "|cffFFFF00Anchor To (Parent):|r  " .. (data.parent or "Unknown"),
                    hidden = function() return not state.expandedStates[childName] end 
                },
                infoC = { 
                    order = 0.7, 
                    type = "description", 
                    fontSize = "medium",
                    name = "|cffFFFF00Anchor From (Child):|r  " .. childName .. "\n",
                    hidden = function() return not state.expandedStates[childName] end 
                },

                posH = { 
                    order = 1, 
                    type = "header", 
                    name = "Positioning", 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                point = { 
                    order = 2, 
                    type = "select", 
                    name = "Anchor From", 
                    values = POINTS, 
                    get = function() return data.point end, 
                    set = function(_, v) 
                        data.point = v 
                        FA:ScheduleApplyAnchors() 
                    end, 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                relPoint = { 
                    order = 3, 
                    type = "select", 
                    name = "Anchor To", 
                    values = POINTS, 
                    get = function() return data.relPoint end, 
                    set = function(_, v) 
                        data.relPoint = v 
                        FA:ScheduleApplyAnchors() 
                    end, 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                x = { 
                    order = 4, 
                    type = "range", 
                    name = "X Offset", 
                    min = -500, 
                    max = 500, 
                    step = 1, 
                    get = function() return data.x or 0 end, 
                    set = function(_, v) 
                        data.x = v 
                        FA:ScheduleApplyAnchors()  -- Debounced!
                    end, 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                y = { 
                    order = 5, 
                    type = "range", 
                    name = "Y Offset", 
                    min = -500, 
                    max = 500, 
                    step = 1, 
                    get = function() return data.y or 0 end, 
                    set = function(_, v) 
                        data.y = v 
                        FA:ScheduleApplyAnchors()  -- Debounced!
                    end, 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                
                metaH = { 
                    order = 10, 
                    type = "header", 
                    name = "Settings", 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                cName = { 
                    order = 11, 
                    type = "input", 
                    name = "Display Name", 
                    width = "full", 
                    get = function() return data.customName end, 
                    set = function(_, v) 
                        data.customName = v 
                        FA:InvalidateOptions()
                    end, 
                    hidden = function() return not state.expandedStates[childName] end 
                },
                del = { 
                    order = 99, 
                    type = "execute", 
                    name = "Delete Anchor", 
                    confirm = true, 
                    confirmText = "Are you sure?",
                    func = function() 
                        -- Clean up frame data
                        local child = _G[childName]
                        if child then
                            child.fa_anchorData = nil
                            -- Note: can't unhook, but without data the hook is a no-op
                        end
                        
                        FA.db.profile.links[childName] = nil
                        state.expandedStates[childName] = nil
                        FA:InvalidateOptions()
                        StaticPopup_Show("FRAMEANCHOR_RELOAD_CONFIRM")
                    end,
                    hidden = function() return not state.expandedStates[childName] end
                }
            }
        }
        i = i + 1
    end
    
    self.cachedOptions = options
    self.optionsDirty = false
    
    return options
end

-- ============================================================================
-- PICKER TOOL & HUD
-- ============================================================================

function FA:GetNavButton(name)
    if not self.navButtons then
        self.navButtons = {}
    end
    
    if not self.navButtons[name] then
        local btn = CreateFrame("Button", "FA_Nav_" .. name, UIParent)
        self.navButtons[name] = btn
        
        -- Set up click handlers based on button type
        if name == "Up" then
            btn:SetScript("OnClick", function()
                local state = FA.state
                if state.selectedFrame and state.selectedFrame:GetParent() then
                    state.selectedFrame = state.selectedFrame:GetParent()
                    state.manualSelection = state.selectedFrame
                    state.visualLayerIndex = 1
                end
            end)
        elseif name == "Down" then
            btn:SetScript("OnClick", function()
                local state = FA.state
                state.visualLayerIndex = state.visualLayerIndex + 1
                state.manualSelection = nil
            end)
        elseif name == "Block" then
            btn:SetScript("OnClick", function() end)
        elseif name == "Cancel" then
            btn:SetScript("OnClick", function()
                FA:StopPicker()
                local state = FA.state
                if state.pickerSource == "CREATION_FRAME" and state.creationFrame then 
                    state.creationFrame:Show() 
                else 
                    ACD:Open(AddonName) 
                end
            end)
        end
    end
    
    return self.navButtons[name]
end

function FA:CreateHUD()
    if self.hud then return self.hud end
    
    local f = CreateFrame("Frame", "FA_PickerHUD", UIParent, "BackdropTemplate")
    f:SetSize(300, 100)
    f:SetPoint("BOTTOM", 0, 150)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(false)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background", 
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16, 
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.8)
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("PICKER MODE ACTIVE")
    title:SetTextColor(0, 1, 0)
    
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    text:SetPoint("TOP", title, "BOTTOM", 0, -10)
    text:SetText("|cff00ccffCTRL|r  Select Frame\n|cff00ccffUP / DOWN|r  Navigate Layers\n|cff00ccffESC|r  Cancel")
    
    self.hud = f
    return f
end

function FA:CreateHighlighter()
    if self.highlighter then return self.highlighter end
    
    local h = CreateFrame("Frame", "FA_Highlighter", UIParent)
    h:SetFrameStrata("FULLSCREEN_DIALOG") 
    h:EnableMouse(false)
    
    local t = h:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetColorTexture(0, 1, 0, 0.4)
    h.tex = t
    
    local txt = h:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    txt:SetPoint("CENTER")
    h.text = txt
    
    self.highlighter = h
    return h
end

function FA:StartPicker(callback, source)
    if InCombatLockdown() then
        self:Print("|cffff0000Cannot use picker during combat.|r")
        return
    end
    
    local state = self.state
    state.currentCallback = callback
    state.pickerActive = true
    state.pickerSource = source
    state.visualLayerIndex = 1
    state.selectedFrame = nil
    state.manualSelection = nil
    
    local hud = self:CreateHUD()
    local highlighter = self:CreateHighlighter()
    
    hud:Show()
    highlighter:Show()
    
    self:GetNavButton("Up")
    self:GetNavButton("Down")
    self:GetNavButton("Block")
    self:GetNavButton("Cancel")
    
    SetOverrideBindingClick(highlighter, true, "UP", "FA_Nav_Up")
    SetOverrideBindingClick(highlighter, true, "DOWN", "FA_Nav_Down")
    SetOverrideBindingClick(highlighter, true, "LEFT", "FA_Nav_Block")
    SetOverrideBindingClick(highlighter, true, "RIGHT", "FA_Nav_Block")
    SetOverrideBindingClick(highlighter, true, "ESCAPE", "FA_Nav_Cancel")
    
    local updateFrame = CreateFrame("Frame")
    local lastUpdate = 0
    local lastSelectedFrame = nil

    updateFrame:SetScript("OnUpdate", function(self, elapsed)
        local state = FA.state
        
        if not state.pickerActive then 
            self:SetScript("OnUpdate", nil) 
            return 
        end
        
        -- THROTTLE: Only update at defined interval
        lastUpdate = lastUpdate + elapsed
        if lastUpdate < PICKER_UPDATE_INTERVAL then 
            return 
        end
        lastUpdate = 0
        
        if not state.manualSelection then
            wipe(state.validFrames)
            
            local frames = GetMouseFoci and GetMouseFoci() or {GetMouseFocus()}
            
            for _, frm in ipairs(frames or {}) do
                if frm and frm ~= WorldFrame and frm ~= FA.highlighter and frm ~= FA.hud and frm:IsVisible() then
                    tinsert(state.validFrames, frm)
                end
            end
            
            if #state.validFrames > 0 then
                if state.visualLayerIndex > #state.validFrames then 
                    state.visualLayerIndex = 1 
                end
                state.selectedFrame = state.validFrames[state.visualLayerIndex]
            end
        else
            state.selectedFrame = state.manualSelection
        end

        if state.selectedFrame and state.selectedFrame ~= lastSelectedFrame then
            local success = pcall(function()
                FA.highlighter:ClearAllPoints()
                FA.highlighter:SetAllPoints(state.selectedFrame)
                FA.highlighter.text:SetText(state.selectedFrame:GetName() or "Unnamed")
                FA.highlighter:Show()
            end)
            
            if success then
                lastSelectedFrame = state.selectedFrame
            end
        elseif not state.selectedFrame then
            FA.highlighter:Hide()
            lastSelectedFrame = nil
        end
        
        if state.selectedFrame and IsControlKeyDown() then
            if state.ctrlLock then return end
            state.ctrlLock = true
            
            C_Timer.After(0.5, function() 
                FA.state.ctrlLock = false 
            end)
            
            local name = state.selectedFrame:GetName()
            if name then
                local cb = state.currentCallback
                FA:StopPicker()
                if cb then cb(name) end
            end
        end
    end)
end

function FA:StopPicker()
    local state = self.state
    state.pickerActive = false
    
    if self.hud then 
        self.hud:Hide() 
    end
    
    if self.highlighter then 
        self.highlighter:Hide()
        ClearOverrideBindings(self.highlighter)
    end
end