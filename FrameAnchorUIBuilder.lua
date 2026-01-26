local AddonName = "FrameAnchor"
local FA = LibStub("AceAddon-3.0"):NewAddon(AddonName, "AceConsole-3.0", "AceSerializer-3.0")
local AC = LibStub("AceConfig-3.0")
local ACD = LibStub("AceConfigDialog-3.0")
local ACR = LibStub("AceConfigRegistry-3.0")
local LD = LibStub("LibDeflate")

local POINTS = {
    ["TOPLEFT"] = "Top Left", ["TOP"] = "Top", ["TOPRIGHT"] = "Top Right",
    ["LEFT"] = "Left", ["CENTER"] = "Center", ["RIGHT"] = "Right",
    ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOM"] = "Bottom", ["BOTTOMRIGHT"] = "Bottom Right"
}

local ICON_EXPAND = "|TInterface\\Buttons\\UI-PlusButton-Up:16|t " 
local ICON_COLLAPSE = "|TInterface\\Buttons\\UI-MinusButton-Up:16|t "

local CreationFrame = nil
local PickerActive = false
local PickerSource = nil 
local CurrentCallback = nil
local VisualLayerIndex = 1
local SelectedFrame, ManualSelection = nil, nil
local exportString = ""
local expandedStates = {} 
local validFrames = {} 

FA.EditModeActive = false
FA.EditModeTimer = nil
FA.ForceUpdate = false 


local NavUp = CreateFrame("Button", "FA_Nav_Up", UIParent)
local NavDown = CreateFrame("Button", "FA_Nav_Down", UIParent)
local NavBlock = CreateFrame("Button", "FA_Nav_Block", UIParent)
local NavCancel = CreateFrame("Button", "FA_Nav_Cancel", UIParent)

-- =========================================================================
-- 1. INITIALIZATION & MIGRATION
-- =========================================================================

function FA:OnInitialize()
    local defaults = {
        global = { links = nil },
        profile = { 
            links = {},
            perfMode = "LIGHT" -- Options: STRICT, LIGHT, YOLO
        }
    }
    
    local charProfile = UnitName("player") .. " - " .. GetRealmName()
    self.db = LibStub("AceDB-3.0"):New("FrameAnchorDB", defaults, charProfile)

    -- Global Migration
    if self.db.global.links then
        print("|cff00ff00[FrameAnchor]|r Migrating global links to profile...")
        for k, v in pairs(self.db.global.links) do
            self.db.profile.links[k] = v
        end
        self.db.global.links = nil 
    end

    -- Force Profile Separation
    if self.db:GetCurrentProfile() == "Default" then
        print("|cff00ff00[FrameAnchor]|r Separating profile for: " .. charProfile)
        self.db:SetProfile(charProfile)
        self.db:CopyProfile("Default", true) 
    end
    
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

    AC:RegisterOptionsTable(AddonName, function() return self:GetOptions() end)
    local profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    AC:RegisterOptionsTable(AddonName .. "_Profiles", profiles)

    self.optionsFrame = ACD:AddToBlizOptions(AddonName, AddonName)
    self.profilesFrame = ACD:AddToBlizOptions(AddonName .. "_Profiles", "Profiles", AddonName)
    
    self:RegisterChatCommand("fa", "OnSlashCommand")
    self:RegisterChatCommand("frameanchor", "OnSlashCommand")
    
    self:SetupNavButtons()
    self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileCopied", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig")
end

function FA:OnEnable()
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            FA:OnWorldLoad()
        end
    end)
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
    self:ApplyAllAnchors()
    ACR:NotifyChange(AddonName)
end

function FA:OnSlashCommand(input)
    ACD:Open(AddonName)
end

-- =========================================================================
-- 2. CORE ANCHOR LOGIC & MODES
-- =========================================================================

function FA:ToggleEditMode(enable)
    if enable then
        FA.EditModeActive = true
        print("|cff00ff00[FrameAnchor]|r Edit Mode ENABLED (5 Minutes)")
        
        if FA.EditModeTimer then FA.EditModeTimer:Cancel() end
        FA.EditModeTimer = C_Timer.NewTimer(300, function() 
            FA:ToggleEditMode(false) 
        end)
    else
        FA.EditModeActive = false
        if FA.EditModeTimer then FA.EditModeTimer:Cancel() end
        print("|cffff0000[FrameAnchor]|r Edit Mode DISABLED. Anchors locked.")
    end
    ACR:NotifyChange(AddonName) 
    
    -- Force re-application when mode changes
    self:ApplyAllAnchors() 
end

function FA:ApplyAllAnchors()
    if InCombatLockdown() then return end

    FA.ForceUpdate = true
    
    for childName, data in pairs(self.db.profile.links) do
        local child = _G[childName]
        local parent = _G[data.parent]
        if child and parent then
            local p1 = data.point or "CENTER"
            local p2 = data.relPoint or "CENTER"
            self:SecureAnchor(child, parent, p1, p2, data.x, data.y)
        end
    end

    FA.ForceUpdate = false
end

function FA:SecureAnchor(child, parent, point, relPoint, x, y)
    local function MoveIt()
        if InCombatLockdown() then return end
        
        -- Prevent infinite loops
        if child.fa_isMoving then return end

        local mode = FA.db.profile.perfMode or "LIGHT"
        
        if mode == "STRICT" and not FA.EditModeActive and not FA.ForceUpdate then
            return
        end

        if mode ~= "YOLO" then
            local currP, currRel, currRelP, currX, currY = child:GetPoint()
            if currP == point and currRel == parent and currRelP == relPoint and 
               math.abs((currX or 0) - (x or 0)) < 0.05 and 
               math.abs((currY or 0) - (y or 0)) < 0.05 then
                return 
            end
        end

        child.fa_isMoving = true 
        child:ClearAllPoints()
        child:SetPoint(point, parent, relPoint, x or 0, y or 0)
        child.fa_isMoving = false
    end

    MoveIt()
    if not child.fa_isHooked then
        hooksecurefunc(child, "SetPoint", MoveIt)
        child.fa_isHooked = true
    end
end

-- =========================================================================
-- 3. IMPORT / EXPORT
-- =========================================================================

function FA:ExportProfile()
    local serialized = self:Serialize(self.db.profile.links)
    if not serialized then return "" end
    local compressed = LD:CompressDeflate(serialized)
    return LD:EncodeForPrint(compressed)
end

function FA:ImportProfile(str)
    if not str or str == "" then return end
    local decoded = LD:DecodeForPrint(str)
    if not decoded then print("FrameAnchor: Invalid string."); return end
    local decompressed = LD:DecompressDeflate(decoded)
    if not decompressed then print("FrameAnchor: Decompress failed."); return end
    local success, newLinks = self:Deserialize(decompressed)
    if not success then print("FrameAnchor: Deserialize failed."); return end

    self.db.profile.links = newLinks
    self:ApplyAllAnchors()
    ACR:NotifyChange(AddonName)
    print("FrameAnchor: Profile imported!")
end

-- =========================================================================
-- 4. THE POP-OUT CREATOR
-- =========================================================================

function FA:ShowCreationFrame()
    if CreationFrame then 
        CreationFrame:Show() 
        CreationFrame:Raise() 
        return 
    end

    local f = CreateFrame("Frame", "FACreationFrame", UIParent, "BackdropTemplate")
    f:SetSize(320, 300) 
    f:SetPoint("CENTER")
    
    f:SetFrameStrata("TOOLTIP") 
    f:SetFrameLevel(9900)
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

    local function CreateInput(label, subtext, y, showPicker)
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", 25, y)
        lbl:SetText(label)
        
        local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        eb:SetSize(200, 20)
        eb:SetPoint("TOPLEFT", 25, y - 20)
        eb:SetAutoFocus(false)
        
        if subtext then
            local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sub:SetPoint("TOPLEFT", 25, y - 42)
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
        if p == "" or c == "" or p == c then print("FrameAnchor: Invalid selection.") return end
        
        FA.db.profile.links[c] = { 
            parent=p, customName=(n~="" and n or nil), 
            point="CENTER", relPoint="CENTER", x=0, y=0 
        }
        
        expandedStates[c] = true
        FA:ApplyAllAnchors()
        ACR:NotifyChange(AddonName)
        
        cEdit:SetText("")
        nEdit:SetText("")
        f:Hide()
        
        ACD:Open(AddonName) 
        ACD:SelectGroup(AddonName, "anchors")
    end)

    CreationFrame = f
end

-- =========================================================================
-- 5. OPTIONS TABLE
-- =========================================================================

function FA:GetOptions()
    local options = {
        name = "Frame Anchor", handler = FA, type = "group", childGroups = "tab", 
        args = {
            anchors = {
                order = 1, type = "group", name = "Anchors",
                args = {
                    perfHeader = { order = 0.1, type = "header", name = "Performance Settings" },
                    perfMode = {
                        order = 0.2, type = "select", name = "Engine Mode",
                        desc = "STRICT: Highest performance. Only sets anchor on Login or Edit Mode.\nLIGHT: Resets anchor if parent frame changes (throttled, out of combat only).\nYOLO: Forces link connection every update (High CPU).",
                        values = { ["STRICT"] = "Strict (Manual)", ["LIGHT"] = "Light (Smart)", ["YOLO"] = "YOLO (Force)" },
                        get = function() return FA.db.profile.perfMode end,
                        set = function(_, v) FA.db.profile.perfMode = v FA:ApplyAllAnchors() end
                    },
                    editModeBtn = {
                        order = 0.3, type = "execute",
                        name = function() return FA.EditModeActive and "DISABLE EDIT MODE" or "ENABLE EDIT MODE (5m)" end,
                        desc = "Temporarily enables anchor enforcement so you can move things around.",
                        disabled = function() return FA.db.profile.perfMode == "YOLO" end, 
                        func = function() FA:ToggleEditMode(not FA.EditModeActive) end,
                        width = "double",
                    },
                    space1 = { order=0.4, type="description", name="\n" },

                    createBtn = { order = 1, type = "execute", name = "Create New Anchor...", width = "full", func = function() FA:ShowCreationFrame() end },
                    space2 = { order=2, type="description", name="\n" },
                    header = { order = 3, type="header", name="Active Anchors" },
                    list = { order = 10, type = "group", inline = true, name = "", args = {} }
                }
            },
            share = {
                order = 2, type = "group", name = "Import / Export",
                args = {
                    header = { order=1, type="header", name="Share Profile" },
                    desc = { order=2, type="description", name="Copy string to share, or paste to import." },
                    exportBtn = { order = 3, type = "execute", name = "Generate Export String", func = function() exportString = FA:ExportProfile() end },
                    ioBox = { order = 4, type = "input", name = "String", width = "full", multiline = 10, get = function() return exportString end, set = function(_, v) exportString = v end },
                    importBtn = { order = 5, type = "execute", name = "Import", confirm = true, confirmText = "Overwrite profile?", func = function() FA:ImportProfile(exportString) end }
                }
            },
        }
    }

    local i = 1
    for childName, data in pairs(self.db.profile.links) do
        local dName = data.customName and (data.customName.." ("..childName..")") or childName
        local isExpanded = expandedStates[childName]
        local icon = isExpanded and ICON_COLLAPSE or ICON_EXPAND
        local toggleName = icon .. dName

        options.args.anchors.args.list.args[childName] = {
            type = "group", name = "", order = i, inline = true, 
            args = {
                toggle = {
                    order = 0, type = "execute", name = toggleName, width = "full",
                    func = function() expandedStates[childName] = not expandedStates[childName] ACR:NotifyChange(AddonName) end
                },
                
                detailsH = { order=0.5, type="header", name="Link Details", hidden = function() return not isExpanded end },
                infoP = { 
                    order=0.6, type="description", fontSize="medium",
                    name = "|cffFFFF00Anchor To (Parent):|r  " .. (data.parent or "Unknown"),
                    hidden = function() return not isExpanded end 
                },
                infoC = { 
                    order=0.7, type="description", fontSize="medium",
                    name = "|cffFFFF00Anchor From (Child):|r  " .. childName .. "\n",
                    hidden = function() return not isExpanded end 
                },

                posH = { order=1, type="header", name="Positioning", hidden = function() return not isExpanded end },
                point = { order=2, type="select", name="Anchor From", values=POINTS, get=function() return data.point end, set=function(_,v) data.point=v FA:ApplyAllAnchors() end, hidden = function() return not isExpanded end },
                relPoint = { order=3, type="select", name="Anchor To", values=POINTS, get=function() return data.relPoint end, set=function(_,v) data.relPoint=v FA:ApplyAllAnchors() end, hidden = function() return not isExpanded end },
                x = { 
                    order=4, type="range", name="X Offset", min=-500, max=500, step=1, 
                    get=function() return data.x or 0 end, 
                    set=function(_,v) data.x=v FA:ApplyAllAnchors() end, 
                    hidden = function() return not isExpanded end 
                },
                y = { 
                    order=5, type="range", name="Y Offset", min=-500, max=500, step=1, 
                    get=function() return data.y or 0 end, 
                    set=function(_,v) data.y=v FA:ApplyAllAnchors() end, 
                    hidden = function() return not isExpanded end 
                },
                
                metaH = { order=10, type="header", name="Settings", hidden = function() return not isExpanded end },
                cName = { order=11, type="input", name="Display Name", width="full", get=function() return data.customName end, set=function(_,v) data.customName=v ACR:NotifyChange(AddonName) end, hidden = function() return not isExpanded end },
                del = { 
                    order=99, type="execute", name="Delete Anchor", confirm=true, confirmText="Are you sure?",
                    func=function() 
                        FA.db.profile.links[childName] = nil
                        ACR:NotifyChange(AddonName)
                        StaticPopup_Show("FRAMEANCHOR_RELOAD_CONFIRM")
                    end,
                    hidden = function() return not isExpanded end
                }
            }
        }
        i = i + 1
    end
    return options
end

-- =========================================================================
-- 6. PICKER TOOL & HUD
-- =========================================================================

function FA:SetupNavButtons()
    NavUp:SetScript("OnClick", function()
        if SelectedFrame and SelectedFrame:GetParent() then
            SelectedFrame = SelectedFrame:GetParent()
            ManualSelection = SelectedFrame 
            VisualLayerIndex = 1
        end
    end)
    NavDown:SetScript("OnClick", function()
        VisualLayerIndex = VisualLayerIndex + 1
        ManualSelection = nil 
    end)
    NavBlock:SetScript("OnClick", function() end)
    
    NavCancel:SetScript("OnClick", function()
        FA:StopPicker()
        if PickerSource == "CREATION_FRAME" and CreationFrame then CreationFrame:Show() else ACD:Open(AddonName) end
    end)
end

function FA:CreateHUD()
    local f = CreateFrame("Frame", "FA_PickerHUD", UIParent, "BackdropTemplate")
    f:SetSize(300, 100)
    f:SetPoint("BOTTOM", 0, 150)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(false)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.8)
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("PICKER MODE ACTIVE")
    title:SetTextColor(0, 1, 0)
    
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    text:SetPoint("TOP", title, "BOTTOM", 0, -10)
    text:SetText("|cff00ccffCTRL|r  Select Frame\n|cff00ccffUP / DOWN|r  Navigate Layers\n|cff00ccffESC|r  Cancel")
    
    FA.HUD = f
end

function FA:StartPicker(callback, source)
    CurrentCallback = callback
    PickerActive = true
    PickerSource = source
    VisualLayerIndex = 1
    SelectedFrame = nil
    ManualSelection = nil
    
    if not FA.HUD then FA:CreateHUD() end
    FA.HUD:Show()
    
    if not self.Highlighter then
        self.Highlighter = CreateFrame("Frame", "FA_Highlighter", UIParent)
        self.Highlighter:SetFrameStrata("FULLSCREEN_DIALOG") 
        self.Highlighter:EnableMouse(false)
        local t = self.Highlighter:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints()
        t:SetColorTexture(0, 1, 0, 0.4)
        self.Highlighter.tex = t
        local txt = self.Highlighter:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        txt:SetPoint("CENTER")
        self.Highlighter.text = txt
    end
    self.Highlighter:Show()
    
    SetOverrideBindingClick(self.Highlighter, true, "UP", "FA_Nav_Up")
    SetOverrideBindingClick(self.Highlighter, true, "DOWN", "FA_Nav_Down")
    SetOverrideBindingClick(self.Highlighter, true, "LEFT", "FA_Nav_Block")
    SetOverrideBindingClick(self.Highlighter, true, "RIGHT", "FA_Nav_Block")
    SetOverrideBindingClick(self.Highlighter, true, "ESCAPE", "FA_Nav_Cancel")
    
    local f = CreateFrame("Frame")
    local lastSelectedFrame = nil 

    f:SetScript("OnUpdate", function(self)
        if not PickerActive then f:SetScript("OnUpdate", nil) return end
        
        if not ManualSelection then
            wipe(validFrames) 
            local frames = GetMouseFoci and GetMouseFoci() or {GetMouseFocus()}
            
            for _, frm in ipairs(frames or {}) do
                if frm ~= WorldFrame and frm ~= FA.Highlighter and frm ~= FA.HUD and frm:IsVisible() then
                    table.insert(validFrames, frm)
                end
            end
            
            if #validFrames > 0 then
                if VisualLayerIndex > #validFrames then VisualLayerIndex = 1 end
                SelectedFrame = validFrames[VisualLayerIndex]
            end
        else
            SelectedFrame = ManualSelection
        end

        if SelectedFrame and SelectedFrame ~= lastSelectedFrame then
            FA.Highlighter:ClearAllPoints()
            FA.Highlighter:SetAllPoints(SelectedFrame)
            FA.Highlighter.text:SetText(SelectedFrame:GetName() or "Unnamed")
            FA.Highlighter:Show()
            lastSelectedFrame = SelectedFrame
        elseif not SelectedFrame then
            FA.Highlighter:Hide()
            lastSelectedFrame = nil
        end
        
        if SelectedFrame and IsControlKeyDown() then
            if FA.ctrlLock then return end
            FA.ctrlLock = true
            C_Timer.After(0.5, function() FA.ctrlLock = false end)
            local name = SelectedFrame:GetName()
            if name then
                FA:StopPicker()
                if CurrentCallback then CurrentCallback(name) end
            end
        end
    end)
end

function FA:StopPicker()
    PickerActive = false
    if FA.HUD then FA.HUD:Hide() end
    self.Highlighter:Hide()
    ClearOverrideBindings(self.Highlighter)
end
