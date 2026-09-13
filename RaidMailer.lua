local ADDON_NAME = ...

local BODY = ""
local DEFAULT_NEXT_MAIL_DELAY = 1.00
local DEFAULT_PANEL_OFFSET_X = 25
local DEFAULT_PANEL_OFFSET_Y = 0
local DEFAULT_QUANTITY = 1
local PANEL_WIDTH = 350
local PANEL_HEIGHT_CORRECTION = 3
local PANEL_HEIGHT_FALLBACK = 424
local RECIPIENTS_VISIBLE_HEIGHT = 159
local RECIPIENTS_EDIT_MIN_HEIGHT = 145
local ATTACHMENT_SETTLE_DELAY = 0.35
local MAIL_CLEAR_TIMEOUT = 12.0
local STATE_POLL_INTERVAL = 0.10
local BAG_OPERATION_TIMEOUT = 12.0
local ATTACHMENT_TIMEOUT = 12.0
local ITEM_LOCK_TIMEOUT = 12.0
local MAIL_RETRY_DELAY = 2.0
local MAX_MAIL_RETRIES = 3

local frame = CreateFrame("Frame")
local panel
local settingsFrame
local sendButton
local cancelButton
local settingsButton
local statusText
local detailText
local quantityEdit
local itemIDEdit
local itemNameText
local recipientsEdit
local recipientsScrollFrame
local configSaveButton
local configRevertButton
local settingsXEdit
local settingsYEdit
local settingsDelayEdit
local settingsSaveButton
local settingsRevertButton
local UpdatePanel

local state = {
    running = false,
    awaitingResult = false,
    awaitingAttachment = false,
    attachmentStartedAt = nil,
    awaitingSplit = false,
    splitStartedAt = nil,
    splitBag = nil,
    splitSlot = nil,
    awaitingRetry = false,
    awaitingMailClear = false,
    mailClearStartedAt = nil,
    mailRetryCount = 0,
    recipients = {},
    itemID = nil,
    quantity = nil,
    index = 0,
    sent = 0,
    currentRecipient = nil,
    generation = 0,
    cancelRequested = false,
}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9482c9RaidMailer:|r " .. tostring(message))
end

local function Trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizeRecipientText(text)
    return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function CopyArray(source)
    local copy = {}
    for i = 1, #source do
        copy[i] = source[i]
    end
    return copy
end

local function EnsureDatabases()
    if type(RaidMailerDB) ~= "table" then
        RaidMailerDB = {}
    end
    if type(RaidMailerSettingsDB) ~= "table" then
        RaidMailerSettingsDB = {}
    end

    if type(RaidMailerDB.config) ~= "table" then
        RaidMailerDB.config = {
            quantity = DEFAULT_QUANTITY,
            itemID = nil,
            recipients = "",
        }
    end

    local config = RaidMailerDB.config
    local quantity = tonumber(config.quantity)
    if not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        config.quantity = DEFAULT_QUANTITY
    else
        config.quantity = math.floor(quantity)
    end

    local itemID = tonumber(config.itemID)
    if itemID and itemID > 0 and itemID == math.floor(itemID) then
        config.itemID = math.floor(itemID)
    else
        config.itemID = nil
    end
    config.recipients = NormalizeRecipientText(config.recipients)

    if RaidMailerSettingsDB.interMailDelay == nil then
        RaidMailerSettingsDB.interMailDelay = DEFAULT_NEXT_MAIL_DELAY
    end
    if RaidMailerSettingsDB.panelOffsetX == nil then
        RaidMailerSettingsDB.panelOffsetX = DEFAULT_PANEL_OFFSET_X
    end
    if RaidMailerSettingsDB.panelOffsetY == nil then
        RaidMailerSettingsDB.panelOffsetY = DEFAULT_PANEL_OFFSET_Y
    end

    local delay = tonumber(RaidMailerSettingsDB.interMailDelay) or DEFAULT_NEXT_MAIL_DELAY
    RaidMailerSettingsDB.interMailDelay = math.max(0.75, math.min(delay, 10.0))
    RaidMailerSettingsDB.panelOffsetX = tonumber(RaidMailerSettingsDB.panelOffsetX) or DEFAULT_PANEL_OFFSET_X
    RaidMailerSettingsDB.panelOffsetY = tonumber(RaidMailerSettingsDB.panelOffsetY) or DEFAULT_PANEL_OFFSET_Y

    RaidMailerDB.schemaVersion = 2
    RaidMailerSettingsDB.schemaVersion = 1
end

local function GetSavedConfig()
    EnsureDatabases()
    return RaidMailerDB.config
end

local function GetNextMailDelay()
    EnsureDatabases()
    return math.max(0.75, math.min(tonumber(RaidMailerSettingsDB.interMailDelay) or DEFAULT_NEXT_MAIL_DELAY, 10.0))
end

local function GetPanelOffsetX()
    EnsureDatabases()
    return tonumber(RaidMailerSettingsDB.panelOffsetX) or DEFAULT_PANEL_OFFSET_X
end

local function GetPanelOffsetY()
    EnsureDatabases()
    return tonumber(RaidMailerSettingsDB.panelOffsetY) or DEFAULT_PANEL_OFFSET_Y
end

local function GetConfiguredItemID()
    return tonumber(GetSavedConfig().itemID)
end

local function GetConfiguredQuantity()
    local quantity = tonumber(GetSavedConfig().quantity) or DEFAULT_QUANTITY
    return math.max(1, math.floor(quantity))
end

local function GetConfiguredRecipientsText()
    return NormalizeRecipientText(GetSavedConfig().recipients)
end

local function GetItemNameByID(itemID)
    if not itemID then
        return "configured item"
    end

    local name = GetItemInfo(itemID)
    return name or ("item " .. itemID)
end

local function GetConfiguredItemName()
    return GetItemNameByID(GetConfiguredItemID())
end

local function GetRunItemID()
    return state.itemID or GetConfiguredItemID()
end

local function GetRunQuantity()
    return state.quantity or GetConfiguredQuantity()
end

local function GetRunItemName()
    return GetItemNameByID(GetRunItemID())
end

local function GetSavedJob()
    EnsureDatabases()
    local job = RaidMailerDB.job
    if type(job) ~= "table" or type(job.recipients) ~= "table" or type(job.itemID) ~= "number" then
        RaidMailerDB.job = nil
        return nil
    end

    local total = #job.recipients
    local nextIndex = math.floor(tonumber(job.nextIndex) or 1)
    if total == 0 or nextIndex < 1 or nextIndex > total then
        RaidMailerDB.job = nil
        return nil
    end

    local quantity = tonumber(job.quantity) or 1 -- v0.6.0 jobs did not store quantity.
    if quantity < 1 or quantity ~= math.floor(quantity) then
        quantity = 1
    end

    job.quantity = math.floor(quantity)
    job.nextIndex = nextIndex
    job.sent = math.max(0, math.min(total, tonumber(job.sent) or (nextIndex - 1)))
    return job
end

local function CreateSavedJob(itemID, quantity, recipients)
    EnsureDatabases()
    RaidMailerDB.job = {
        version = 2,
        itemID = itemID,
        quantity = quantity,
        recipients = CopyArray(recipients),
        nextIndex = 1,
        sent = 0,
        createdAt = time and time() or 0,
        updatedAt = time and time() or 0,
        pausedReason = nil,
    }
    return RaidMailerDB.job
end

local function SaveProgress(pausedReason)
    EnsureDatabases()
    local job = RaidMailerDB.job
    if type(job) ~= "table" then
        return
    end

    job.nextIndex = state.index
    job.sent = state.sent
    job.updatedAt = time and time() or 0
    job.pausedReason = pausedReason
end

local function ClearSavedJob()
    EnsureDatabases()
    RaidMailerDB.job = nil
end

local function NormalizeRealm(realm)
    if not realm then return nil end
    return realm:gsub("[%s%-]", ""):lower()
end

local function IsPlayerCharacter(recipient)
    local playerName = UnitName("player")
    if not playerName then return false end

    local name, realm = recipient:match("^([^%-]+)%-(.+)$")
    if not name then
        return recipient:lower() == playerName:lower()
    end

    if name:lower() ~= playerName:lower() then
        return false
    end

    local playerRealm = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
    return NormalizeRealm(realm) == NormalizeRealm(playerRealm)
end

local function ParseRecipients(text)
    text = NormalizeRecipientText(text ~= nil and text or GetConfiguredRecipientsText())
    local recipients = {}
    local seen = {}
    local duplicates = {}
    local skippedSelf = 0

    for line in (text .. "\n"):gmatch("(.-)\n") do
        local name = Trim(line)
        if name ~= "" and name:sub(1, 1) ~= "#" then
            if IsPlayerCharacter(name) then
                skippedSelf = skippedSelf + 1
            else
                local key = name:lower()
                if seen[key] then
                    duplicates[#duplicates + 1] = name
                else
                    seen[key] = true
                    recipients[#recipients + 1] = name
                end
            end
        end
    end

    return recipients, duplicates, skippedSelf
end

local function GetContainerInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        return C_Container.GetContainerItemInfo(bag, slot)
    end

    -- Compatibility fallback for older Classic API layouts.
    if GetContainerItemInfo then
        local texture, count, locked, quality, readable, lootable, link, filtered, noValue, itemID, isBound = GetContainerItemInfo(bag, slot)
        if not texture then return nil end
        return {
            iconFileID = texture,
            stackCount = count,
            isLocked = locked,
            quality = quality,
            hyperlink = link,
            itemID = itemID,
            isBound = isBound,
        }
    end
end

local function GetNumSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag)
    end
    return GetContainerNumSlots(bag)
end

local function CountItemInBags(itemID)
    if not itemID then return 0 end

    local total = 0
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == itemID then
                total = total + (info.stackCount or 0)
            end
        end
    end
    return total
end

local function CountConfiguredItemsInBags()
    return CountItemInBags(GetConfiguredItemID())
end

local function FindConfiguredExactStack()
    local itemID = GetRunItemID()
    local quantity = GetRunQuantity()
    if not itemID then return nil, nil, false end

    local foundLocked = false
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == itemID and (info.stackCount or 0) == quantity then
                if info.isLocked then
                    foundLocked = true
                else
                    return bag, slot, false
                end
            end
        end
    end

    return nil, nil, foundLocked
end

local function FindConfiguredSourceStack()
    local itemID = GetRunItemID()
    local quantity = GetRunQuantity()
    if not itemID then return nil, nil, nil, false end

    local foundLocked = false
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == itemID and (info.stackCount or 0) > quantity then
                if info.isLocked then
                    foundLocked = true
                else
                    return bag, slot, info.stackCount, false
                end
            end
        end
    end

    return nil, nil, nil, foundLocked
end

local function GetNumFreeSlots(bag)
    if C_Container and C_Container.GetContainerNumFreeSlots then
        return C_Container.GetContainerNumFreeSlots(bag)
    end
    return GetContainerNumFreeSlots(bag)
end

local function FindEmptyGeneralBagSlot()
    for bag = 0, 4 do
        local freeSlots, bagFamily = GetNumFreeSlots(bag)
        -- Backpack and ordinary bags use bagFamily 0. Avoid specialty bags
        -- because a generic configured item may not be allowed in them.
        if (freeSlots or 0) > 0 and (bag == 0 or not bagFamily or bagFamily == 0) then
            for slot = 1, GetNumSlots(bag) do
                if not GetContainerInfo(bag, slot) then
                    return bag, slot
                end
            end
        end
    end

    return nil, nil
end

local function PickupContainerSlot(bag, slot)
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        PickupContainerItem(bag, slot)
    end
end

local function SplitContainerStack(bag, slot, count)
    if C_Container and C_Container.SplitContainerItem then
        C_Container.SplitContainerItem(bag, slot, count)
    else
        SplitContainerItem(bag, slot, count)
    end
end

local function HasBlockingDraft()
    for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
        if GetSendMailItem(i) then
            return true, "an item attachment"
        end
    end

    if GetSendMailMoney and GetSendMailMoney() > 0 then
        return true, "attached money"
    end

    if GetSendMailCOD and GetSendMailCOD() > 0 then
        return true, "a C.O.D. amount"
    end

    -- A recipient by itself is intentionally NOT considered a blocking draft.
    -- RaidMailer owns the recipient field while a batch is running and
    -- SendNext() calls ClearSendMail() before composing every outgoing mail.
    -- This lets a stale/manual recipient be cleared automatically on start.

    if SendMailSubjectEditBox and Trim(SendMailSubjectEditBox:GetText() or "") ~= "" then
        return true, "a subject"
    end

    if SendMailBodyEditBox and Trim(SendMailBodyEditBox:GetText() or "") ~= "" then
        return true, "message text"
    end

    return false
end

local function ApplyPanelPosition()
    if not panel or not MailFrame then return end
    local mailFrameHeight = MailFrame:GetHeight()
    if mailFrameHeight and mailFrameHeight > 0 then
        panel:SetHeight(mailFrameHeight + PANEL_HEIGHT_CORRECTION)
    else
        panel:SetHeight(PANEL_HEIGHT_FALLBACK + PANEL_HEIGHT_CORRECTION)
    end
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", GetPanelOffsetX(), GetPanelOffsetY())
end

local function SetEditBoxEnabled(editBox, enabled)
    if not editBox then return end
    if enabled then
        editBox:Enable()
        editBox:SetTextColor(1, 1, 1)
    else
        editBox:Disable()
        editBox:SetTextColor(0.55, 0.55, 0.55)
    end
end

local function SetConfigEditorEnabled(enabled)
    SetEditBoxEnabled(quantityEdit, enabled)
    SetEditBoxEnabled(itemIDEdit, enabled)
    SetEditBoxEnabled(recipientsEdit, enabled)
end

local function GetPanelFormValues()
    local quantity = quantityEdit and tonumber(Trim(quantityEdit:GetText())) or nil
    local itemID = itemIDEdit and tonumber(Trim(itemIDEdit:GetText())) or nil
    local recipients = recipientsEdit and NormalizeRecipientText(recipientsEdit:GetText()) or ""
    return quantity, itemID, recipients
end

local function IsConfigFormDirty()
    if not quantityEdit or not itemIDEdit or not recipientsEdit then
        return false
    end

    local config = GetSavedConfig()
    local quantity, itemID, recipients = GetPanelFormValues()
    return quantity ~= tonumber(config.quantity)
        or itemID ~= tonumber(config.itemID)
        or recipients ~= NormalizeRecipientText(config.recipients)
end

local function UpdateRecipientEditHeight()
    if not recipientsEdit or not recipientsScrollFrame then return end

    -- Multiline EditBoxes calculate their own text height. Forcing a new height
    -- after every keystroke can desynchronize the widget's native cursor/mouse
    -- geometry from the ScrollFrame. Let WoW size the multiline text naturally
    -- and only ask the ScrollFrame to recalculate its scrollable rectangle.
    if recipientsScrollFrame.UpdateScrollChildRect then
        recipientsScrollFrame:UpdateScrollChildRect()
    end
end

local function UpdateItemNamePreview()
    if not itemNameText then return end
    local itemID = itemIDEdit and tonumber(Trim(itemIDEdit:GetText())) or nil
    if itemID and itemID > 0 and itemID == math.floor(itemID) then
        itemNameText:SetText(GetItemNameByID(itemID))
    else
        itemNameText:SetText("Enter a numeric item ID")
    end
end

local function LoadConfigIntoPanelFields()
    if not quantityEdit or not itemIDEdit or not recipientsEdit then return end
    local config = GetSavedConfig()
    quantityEdit:SetText(tostring(config.quantity or DEFAULT_QUANTITY))
    itemIDEdit:SetText(config.itemID and tostring(config.itemID) or "")
    recipientsEdit:SetText(NormalizeRecipientText(config.recipients))
    UpdateRecipientEditHeight()
    UpdateItemNamePreview()
    if UpdatePanel then UpdatePanel() end
end

local function SaveDistributionConfigFromUI()
    if state.running then
        Print("Cannot save distribution configuration while a batch is running.")
        return false
    end

    local quantity, itemID, recipients = GetPanelFormValues()
    if not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        Print("Quantity per mail must be a positive whole number.")
        return false
    end
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then
        Print("Item ID must be a positive whole-number WoW item ID.")
        return false
    end

    local config = GetSavedConfig()
    config.quantity = math.floor(quantity)
    config.itemID = math.floor(itemID)
    config.recipients = NormalizeRecipientText(recipients)

    LoadConfigIntoPanelFields()
    if GetSavedJob() then
        Print("Distribution configuration saved. The paused batch keeps its original item, quantity, and recipient snapshot until it is resumed, reset, or restarted.")
    else
        Print("Distribution configuration saved.")
    end
    return true
end

local function LoadSettingsIntoWindow()
    if not settingsXEdit or not settingsYEdit or not settingsDelayEdit then return end
    EnsureDatabases()
    settingsXEdit:SetText(tostring(RaidMailerSettingsDB.panelOffsetX or DEFAULT_PANEL_OFFSET_X))
    settingsYEdit:SetText(tostring(RaidMailerSettingsDB.panelOffsetY or DEFAULT_PANEL_OFFSET_Y))
    settingsDelayEdit:SetText(tostring(RaidMailerSettingsDB.interMailDelay or DEFAULT_NEXT_MAIL_DELAY))
end

local function SaveSettingsFromUI()
    local x = settingsXEdit and tonumber(Trim(settingsXEdit:GetText())) or nil
    local y = settingsYEdit and tonumber(Trim(settingsYEdit:GetText())) or nil
    local delay = settingsDelayEdit and tonumber(Trim(settingsDelayEdit:GetText())) or nil

    if not x or not y then
        Print("Panel X and Y offsets must be numbers.")
        return false
    end
    if not delay or delay < 0.75 or delay > 10.0 then
        Print("Inter-mail delay must be between 0.75 and 10 seconds.")
        return false
    end

    EnsureDatabases()
    RaidMailerSettingsDB.panelOffsetX = x
    RaidMailerSettingsDB.panelOffsetY = y
    RaidMailerSettingsDB.interMailDelay = delay
    ApplyPanelPosition()
    LoadSettingsIntoWindow()
    Print("RaidMailer settings saved.")
    return true
end

local function CreateSettingsWindow()
    if settingsFrame then return end

    settingsFrame = CreateFrame("Frame", "RaidMailerSettingsFrame", UIParent, "BackdropTemplate")
    settingsFrame:SetSize(330, 220)
    settingsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    settingsFrame:SetFrameStrata("DIALOG")
    settingsFrame:SetClampedToScreen(true)
    settingsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    settingsFrame:Hide()

    local title = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("RaidMailer Settings")

    local closeButton = CreateFrame("Button", nil, settingsFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)

    local xLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    xLabel:SetPoint("TOPLEFT", 20, -52)
    xLabel:SetText("Panel X offset")

    settingsXEdit = CreateFrame("EditBox", nil, settingsFrame, "InputBoxTemplate")
    settingsXEdit:SetSize(90, 22)
    settingsXEdit:SetPoint("LEFT", xLabel, "RIGHT", 22, 0)
    settingsXEdit:SetAutoFocus(false)
    settingsXEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    settingsXEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local yLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    yLabel:SetPoint("TOPLEFT", xLabel, "BOTTOMLEFT", 0, -28)
    yLabel:SetText("Panel Y offset")

    settingsYEdit = CreateFrame("EditBox", nil, settingsFrame, "InputBoxTemplate")
    settingsYEdit:SetSize(90, 22)
    settingsYEdit:SetPoint("LEFT", yLabel, "RIGHT", 22, 0)
    settingsYEdit:SetAutoFocus(false)
    settingsYEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    settingsYEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local delayLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    delayLabel:SetPoint("TOPLEFT", yLabel, "BOTTOMLEFT", 0, -28)
    delayLabel:SetText("Inter-mail delay")

    settingsDelayEdit = CreateFrame("EditBox", nil, settingsFrame, "InputBoxTemplate")
    settingsDelayEdit:SetSize(90, 22)
    settingsDelayEdit:SetPoint("LEFT", delayLabel, "RIGHT", 20, 0)
    settingsDelayEdit:SetAutoFocus(false)
    settingsDelayEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    settingsDelayEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local delaySuffix = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    delaySuffix:SetPoint("LEFT", settingsDelayEdit, "RIGHT", 6, 0)
    delaySuffix:SetText("seconds")

    local hint = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", delayLabel, "BOTTOMLEFT", 0, -25)
    hint:SetPoint("RIGHT", -20, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Positive X moves the mailbox panel right; positive Y moves it up. Settings are shared across characters.")

    settingsRevertButton = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
    settingsRevertButton:SetSize(90, 24)
    settingsRevertButton:SetPoint("BOTTOMRIGHT", -18, 16)
    settingsRevertButton:SetText("Revert")
    settingsRevertButton:SetScript("OnClick", function()
        LoadSettingsIntoWindow()
    end)

    settingsSaveButton = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
    settingsSaveButton:SetSize(90, 24)
    settingsSaveButton:SetPoint("RIGHT", settingsRevertButton, "LEFT", -8, 0)
    settingsSaveButton:SetText("Save")
    settingsSaveButton:SetScript("OnClick", SaveSettingsFromUI)

    if UISpecialFrames then
        table.insert(UISpecialFrames, "RaidMailerSettingsFrame")
    end
end

local function ShowSettingsWindow()
    CreateSettingsWindow()
    LoadSettingsIntoWindow()
    settingsFrame:Show()
    settingsFrame:Raise()
end

UpdatePanel = function()
    if not panel then return end
    ApplyPanelPosition()
    UpdateItemNamePreview()

    local itemID = GetConfiguredItemID()
    local quantity = GetConfiguredQuantity()
    local itemName = GetConfiguredItemName()
    local recipients, duplicates, skippedSelf = ParseRecipients()
    local items = CountConfiguredItemsInBags()
    local savedJob = GetSavedJob()
    local dirty = IsConfigFormDirty()

    SetConfigEditorEnabled(not state.running)
    if configSaveButton then
        if not state.running and dirty then configSaveButton:Enable() else configSaveButton:Disable() end
    end
    if configRevertButton then
        if not state.running and dirty then configRevertButton:Enable() else configRevertButton:Disable() end
    end

    if state.running then
        sendButton:SetText("Sending...")
        sendButton:Disable()
        cancelButton:SetText("Cancel")
        cancelButton:Enable()

        local total = #state.recipients
        local nextNumber = math.min(state.sent + 1, total)
        if state.awaitingRetry and state.currentRecipient then
            statusText:SetText(string.format("Retrying %d/%d: %s", nextNumber, total, state.currentRecipient))
        elseif state.currentRecipient then
            statusText:SetText(string.format("Sending %d/%d: %s", nextNumber, total, state.currentRecipient))
        else
            statusText:SetText(string.format("Sent %d/%d", state.sent, total))
        end
        detailText:SetText(string.format("%d %s per mail; %d remaining in bags.", GetRunQuantity(), GetRunItemName(), CountItemInBags(GetRunItemID())))
        return
    end

    if savedJob then
        local total = #savedJob.recipients
        local sent = savedJob.nextIndex - 1
        local remaining = total - sent
        local requiredItems = remaining * savedJob.quantity
        local savedItemName = GetItemNameByID(savedJob.itemID)
        local nextRecipient = savedJob.recipients[savedJob.nextIndex] or "?"
        local savedItems = CountItemInBags(savedJob.itemID)

        sendButton:SetText(string.format("Resume (%d left)", remaining))
        cancelButton:SetText("Restart")
        if dirty then cancelButton:Disable() else cancelButton:Enable() end

        if savedJob.pausedReason == "mailcap" then
            statusText:SetText(string.format("Paused: mail cap (%d/%d sent)", sent, total))
        else
            statusText:SetText(string.format("Paused: %d/%d sent", sent, total))
        end

        local dirtySuffix = dirty and " Unsaved form changes do not affect Resume; Save or Revert before Restart." or ""
        detailText:SetText(string.format("Next: %s. %d each; %d %s in bags.%s", nextRecipient, savedJob.quantity, savedItems, savedItemName, dirtySuffix))

        if savedItems < requiredItems then
            sendButton:Disable()
            detailText:SetText(string.format("Next: %s. Need %d %s to finish; %d are in bags.%s", nextRecipient, requiredItems, savedItemName, savedItems, dirtySuffix))
        else
            sendButton:Enable()
        end
        return
    end

    cancelButton:SetText("Cancel")
    cancelButton:Disable()
    sendButton:SetText(string.format("Send Items (%d)", #recipients))

    if dirty then
        statusText:SetText("Unsaved distribution changes")
        detailText:SetText("Save or Revert the quantity, item ID, and recipient list before starting a new batch.")
        sendButton:Disable()
    elseif not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then
        statusText:SetText("Invalid item configuration")
        detailText:SetText("Enter and save a valid numeric WoW item ID.")
        sendButton:Disable()
    elseif not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        statusText:SetText("Invalid quantity")
        detailText:SetText("Quantity per mail must be a positive whole number.")
        sendButton:Disable()
    elseif #duplicates > 0 then
        statusText:SetText("Fix duplicate recipient names")
        detailText:SetText(table.concat(duplicates, ", "))
        sendButton:Disable()
    elseif #recipients == 0 then
        statusText:SetText("No recipients configured")
        detailText:SetText("Enter one character name per line and click Save.")
        sendButton:Disable()
    elseif items < (#recipients * quantity) then
        statusText:SetText(string.format("Need %d; you have %d", #recipients * quantity, items))
        detailText:SetText(string.format("%d %s will be mailed to each recipient.", quantity, itemName))
        sendButton:Disable()
    else
        statusText:SetText(string.format("Ready: %d recipients, %d items", #recipients, items))
        if skippedSelf > 0 then
            detailText:SetText(string.format("%d %s per recipient. Your character is listed and will be skipped (%d time%s).", quantity, itemName, skippedSelf, skippedSelf == 1 and "" or "s"))
        else
            detailText:SetText(string.format("%d %s will be mailed to each listed character.", quantity, itemName))
        end
        sendButton:Enable()
    end
end

local function StopRun(message, isError)
    state.generation = state.generation + 1
    state.running = false
    state.awaitingResult = false
    state.awaitingAttachment = false
    state.attachmentStartedAt = nil
    state.awaitingSplit = false
    state.splitStartedAt = nil
    state.splitBag = nil
    state.splitSlot = nil
    state.awaitingRetry = false
    state.awaitingMailClear = false
    state.mailClearStartedAt = nil
    state.mailRetryCount = 0
    state.currentRecipient = nil
    state.itemID = nil
    state.quantity = nil
    state.cancelRequested = false

    ClearCursor()

    if MailFrame and MailFrame:IsShown() and ClearSendMail then
        ClearSendMail()
    end

    UpdatePanel()

    if message then
        if isError then
            Print("|cffff5555" .. message .. "|r")
        else
            Print(message)
        end
    end
end

local SendNext
local VerifyAttachmentAndSend
local VerifySplitAndAttach
local RetryCurrentMail
local VerifyPreviousMailCleared

local function AttachPreparedStackFromBag(generation, bag, slot, lockStartedAt)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit or state.awaitingRetry or state.awaitingMailClear then
        return
    end

    local quantity = GetRunQuantity()
    local info = GetContainerInfo(bag, slot)
    if not info or info.itemID ~= GetRunItemID() or (info.stackCount or 0) ~= quantity then
        StopRun(string.format("Stopped: the prepared %d-item stack is no longer available.", quantity), true)
        return
    end

    if info.isLocked then
        lockStartedAt = lockStartedAt or GetTime()
        if GetTime() - lockStartedAt < ITEM_LOCK_TIMEOUT then
            C_Timer.After(STATE_POLL_INTERVAL, function()
                AttachPreparedStackFromBag(generation, bag, slot, lockStartedAt)
            end)
            return
        end

        StopRun(string.format("Stopped: the prepared %d-item %s stack remained locked for more than %d seconds.", quantity, GetRunItemName(), ITEM_LOCK_TIMEOUT), true)
        return
    end

    ClearCursor()
    PickupContainerSlot(bag, slot)

    if not CursorHasItem() then
        StopRun(string.format("Stopped: could not pick up the prepared %d %s from your bags.", quantity, GetRunItemName()), true)
        return
    end

    state.awaitingAttachment = true
    state.attachmentStartedAt = GetTime()
    state.currentRecipient = state.recipients[state.index]
    UpdatePanel()

    ClickSendMailItemButton(1)

    C_Timer.After(STATE_POLL_INTERVAL, function()
        VerifyAttachmentAndSend(generation)
    end)
end

local function PrepareConfiguredQuantityInBag(generation, sourceBag, sourceSlot)
    local quantity = GetRunQuantity()
    local emptyBag, emptySlot = FindEmptyGeneralBagSlot()
    if not emptyBag then
        StopRun(string.format("Stopped: RaidMailer needs one empty slot in the backpack or an ordinary bag to prepare %d %s.", quantity, GetRunItemName()), true)
        return
    end

    ClearCursor()
    SplitContainerStack(sourceBag, sourceSlot, quantity)

    if not CursorHasItem() then
        StopRun(string.format("Stopped: could not split %d %s from the source stack.", quantity, GetRunItemName()), true)
        return
    end

    -- Put the split quantity into a real bag slot first. The Anniversary client
    -- can fail when a freshly split cursor stack is attached directly to mail.
    PickupContainerSlot(emptyBag, emptySlot)

    if CursorHasItem() then
        ClearCursor()
        StopRun("Stopped: could not place the split " .. GetRunItemName() .. " into an empty bag slot.", true)
        return
    end

    state.awaitingSplit = true
    state.splitStartedAt = GetTime()
    state.splitBag = emptyBag
    state.splitSlot = emptySlot
    state.currentRecipient = state.recipients[state.index]
    UpdatePanel()

    C_Timer.After(STATE_POLL_INTERVAL, function()
        VerifySplitAndAttach(generation)
    end)
end

local function BeginAttachConfiguredQuantity(generation, lockStartedAt)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit or state.awaitingRetry or state.awaitingMailClear then
        return
    end

    -- Prefer an existing stack of exactly the requested quantity. Otherwise
    -- split the requested quantity from a larger stack into a real bag slot.
    local exactBag, exactSlot, exactLocked = FindConfiguredExactStack()
    if exactBag then
        AttachPreparedStackFromBag(generation, exactBag, exactSlot)
        return
    end

    local bag, slot, stackCount, sourceLocked = FindConfiguredSourceStack()
    if bag then
        PrepareConfiguredQuantityInBag(generation, bag, slot)
        return
    end

    if exactLocked or sourceLocked then
        lockStartedAt = lockStartedAt or GetTime()
        if GetTime() - lockStartedAt < ITEM_LOCK_TIMEOUT then
            C_Timer.After(STATE_POLL_INTERVAL, function()
                BeginAttachConfiguredQuantity(generation, lockStartedAt)
            end)
            return
        end
    end

    local itemName = GetRunItemName()
    local quantity = GetRunQuantity()
    if exactLocked or sourceLocked then
        StopRun("Stopped: the remaining " .. itemName .. " stayed locked for more than " .. ITEM_LOCK_TIMEOUT .. " seconds.", true)
    else
        StopRun(string.format("Stopped: no accessible stack contains at least %d %s. Consolidate the item into a larger stack and resume.", quantity, itemName), true)
    end
end

VerifySplitAndAttach = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingSplit or state.awaitingResult or state.awaitingAttachment or state.awaitingRetry then
        return
    end

    local bag, slot = state.splitBag, state.splitSlot
    local quantity = GetRunQuantity()
    local info = bag and slot and GetContainerInfo(bag, slot) or nil

    if info and info.itemID == GetRunItemID() and (info.stackCount or 0) == quantity and not info.isLocked then
        state.awaitingSplit = false
        state.splitStartedAt = nil
        state.splitBag = nil
        state.splitSlot = nil

        C_Timer.After(STATE_POLL_INTERVAL, function()
            AttachPreparedStackFromBag(generation, bag, slot)
        end)
        return
    end

    local startedAt = state.splitStartedAt or GetTime()
    state.splitStartedAt = startedAt
    if GetTime() - startedAt < BAG_OPERATION_TIMEOUT then
        C_Timer.After(STATE_POLL_INTERVAL, function()
            VerifySplitAndAttach(generation)
        end)
        return
    end

    StopRun(string.format("Stopped: WoW did not finish creating the %d-item %s stack within %d seconds.", quantity, GetRunItemName(), BAG_OPERATION_TIMEOUT), true)
end

local function SendCurrentMail(generation)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingRetry then
        return
    end

    state.awaitingAttachment = false
    state.attachmentStartedAt = nil
    state.awaitingResult = true
    UpdatePanel()
    SendMail(state.currentRecipient, GetRunItemName(), BODY)
end

VerifyAttachmentAndSend = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingAttachment or state.awaitingResult or state.awaitingRetry then
        return
    end

    local quantity = GetRunQuantity()
    local name, itemID, _, count = GetSendMailItem(1)
    if name and itemID == GetRunItemID() and count == quantity then
        state.awaitingAttachment = false
        state.attachmentStartedAt = nil
        C_Timer.After(ATTACHMENT_SETTLE_DELAY, function()
            SendCurrentMail(generation)
        end)
        return
    end

    local startedAt = state.attachmentStartedAt or GetTime()
    state.attachmentStartedAt = startedAt
    if GetTime() - startedAt < ATTACHMENT_TIMEOUT then
        C_Timer.After(STATE_POLL_INTERVAL, function()
            VerifyAttachmentAndSend(generation)
        end)
        return
    end

    local reportedName, reportedItemID, _, reportedCount = GetSendMailItem(1)
    local diagnostic
    if reportedName then
        diagnostic = string.format(" API reports %s (itemID %s, count %s).", tostring(reportedName), tostring(reportedItemID), tostring(reportedCount))
    else
        diagnostic = " API reports attachment slot 1 as empty."
    end
    ClearCursor()
    StopRun(string.format("Stopped: WoW did not attach exactly %d %s within %d seconds.%s", quantity, GetRunItemName(), ATTACHMENT_TIMEOUT, diagnostic), true)
end

RetryCurrentMail = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingRetry then
        return
    end

    state.awaitingRetry = false

    local quantity = GetRunQuantity()
    local name, itemID, _, count = GetSendMailItem(1)
    if name and itemID == GetRunItemID() and count == quantity then
        SendCurrentMail(generation)
        return
    end

    ClearSendMail()
    state.currentRecipient = state.recipients[state.index]
    BeginAttachConfiguredQuantity(generation, GetTime())
end

VerifyPreviousMailCleared = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingMailClear then
        return
    end

    -- MAIL_SEND_SUCCESS means the server accepted the previous message, but the
    -- Anniversary compose UI can take noticeably longer to release/clear its
    -- attachment state.  Force the local compose frame clear only after the
    -- success event, then wait until the API agrees that slot 1 is empty.
    if ClearSendMail then
        ClearSendMail()
    end

    if not GetSendMailItem(1) then
        state.awaitingMailClear = false
        state.mailClearStartedAt = nil
        SendNext()
        return
    end

    local startedAt = state.mailClearStartedAt or GetTime()
    state.mailClearStartedAt = startedAt
    if GetTime() - startedAt < MAIL_CLEAR_TIMEOUT then
        C_Timer.After(STATE_POLL_INTERVAL, function()
            VerifyPreviousMailCleared(generation)
        end)
        return
    end

    SaveProgress("mailuistuck")
    StopRun("Paused: WoW did not clear the previous outgoing mail attachment within " .. MAIL_CLEAR_TIMEOUT .. " seconds. Use /rm resume after the mailbox finishes updating.", true)
end


SendNext = function()
    if not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit or state.awaitingRetry or state.awaitingMailClear then
        return
    end

    if not MailFrame or not MailFrame:IsShown() then
        StopRun("Stopped because the mailbox was closed.", true)
        return
    end

    if state.index > #state.recipients then
        local sent = state.sent
        local quantity = GetRunQuantity()
        local itemName = GetRunItemName()
        ClearSavedJob()
        StopRun(string.format("Complete: sent %d mail%s; %d %s distributed.", sent, sent == 1 and "" or "s", sent * quantity, itemName), false)
        return
    end

    -- Each successful send should clear the compose state, but explicitly
    -- clear it here as well so every outgoing message starts from a known state.
    ClearSendMail()
    BeginAttachConfiguredQuantity(state.generation, GetTime())
end

local function ValidateMailboxReady()
    if not MailFrame or not MailFrame:IsShown() then
        Print("Open a mailbox and select the Send Mail tab first.")
        return false
    end

    local hasDraft, draftPart = HasBlockingDraft()
    if hasDraft then
        Print("Cannot start while the normal Send Mail window contains " .. draftPart .. ". Clear the draft first.")
        return false
    end

    -- A leftover recipient is harmless: clear the normal compose state
    -- automatically instead of making the user fix it and click again.
    if SendMailNameEditBox and Trim(SendMailNameEditBox:GetText() or "") ~= "" then
        ClearSendMail()
    end

    return true
end

local function LaunchSavedJob(job, label)
    if state.running or not job then return end
    if not ValidateMailboxReady() then return end

    local remaining = #job.recipients - job.nextIndex + 1
    local requiredItems = remaining * job.quantity
    local items = CountItemInBags(job.itemID)
    if items < requiredItems then
        Print(string.format("Cannot resume: need %d %s but only %d are in your bags.", requiredItems, GetItemNameByID(job.itemID), items))
        return
    end

    state.generation = state.generation + 1
    state.running = true
    state.awaitingResult = false
    state.awaitingAttachment = false
    state.attachmentStartedAt = nil
    state.awaitingSplit = false
    state.splitStartedAt = nil
    state.splitBag = nil
    state.splitSlot = nil
    state.awaitingRetry = false
    state.awaitingMailClear = false
    state.mailClearStartedAt = nil
    state.mailRetryCount = 0
    state.recipients = CopyArray(job.recipients)
    state.itemID = job.itemID
    state.quantity = job.quantity
    state.index = job.nextIndex
    state.sent = job.nextIndex - 1
    state.currentRecipient = nil
    state.cancelRequested = false

    SaveProgress(nil)
    Print(string.format("%s: %d/%d already sent; %d remaining at %d item%s each. Next: %s.", label, state.sent, #state.recipients, remaining, state.quantity, state.quantity == 1 and "" or "s", state.recipients[state.index]))
    UpdatePanel()
    SendNext()
end

local function StartFreshRun()
    if state.running then return end

    if IsConfigFormDirty() then
        Print("Cannot start a new batch with unsaved distribution changes. Click Save or Revert first.")
        return
    end

    local itemID = GetConfiguredItemID()
    local quantity = GetConfiguredQuantity()
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then
        Print("Cannot start: save a valid numeric item ID in the RaidMailer panel.")
        return
    end
    if not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        Print("Cannot start: quantity per mail must be a positive whole number.")
        return
    end

    local recipients, duplicates, skippedSelf = ParseRecipients()
    if #duplicates > 0 then
        Print("Cannot start: duplicate recipient(s): " .. table.concat(duplicates, ", "))
        return
    end

    if #recipients == 0 then
        Print("Cannot start: no recipients are saved in the RaidMailer panel.")
        return
    end

    if not ValidateMailboxReady() then return end

    local requiredItems = #recipients * quantity
    local items = CountItemInBags(itemID)
    if items < requiredItems then
        Print(string.format("Cannot start: need %d %s but only %d are in your bags.", requiredItems, GetItemNameByID(itemID), items))
        return
    end

    local job = CreateSavedJob(itemID, quantity, recipients)
    local suffix = skippedSelf > 0 and " (your character skipped)" or ""
    Print(string.format("Starting new batch: %d recipient%s, %d item%s each%s.", #recipients, #recipients == 1 and "" or "s", quantity, quantity == 1 and "" or "s", suffix))
    LaunchSavedJob(job, "Batch started")
end

local function ResumeRun()
    if state.running then return end
    local job = GetSavedJob()
    if not job then
        Print("No saved batch is waiting to resume.")
        return
    end
    LaunchSavedJob(job, "Resuming")
end

local function StartOrResume()
    if GetSavedJob() then
        ResumeRun()
    else
        StartFreshRun()
    end
end

local function RestartRun()
    if state.running then return end
    local job = GetSavedJob()
    if job then
        Print(string.format("Restarting from the beginning; the new batch will replace progress for %d previously sent recipient%s.", job.nextIndex - 1, (job.nextIndex - 1) == 1 and "" or "s"))
    end
    -- StartFreshRun validates the current config and item count before
    -- CreateSavedJob replaces the old checkpoint.  If validation fails, the
    -- existing resumable job is left intact.
    StartFreshRun()
end

local function ResetSavedRun()
    if state.running then
        Print("Cannot reset saved progress while a batch is running. Cancel it first.")
        return
    end
    if GetSavedJob() then
        ClearSavedJob()
        UpdatePanel()
        Print("Saved batch progress cleared.")
    else
        Print("No saved batch progress to clear.")
    end
end

local function CancelRun()
    if not state.running then return end

    if state.awaitingResult then
        -- The current SendMail call is already in flight.  Let its result event
        -- resolve, then stop before preparing another recipient.
        state.cancelRequested = true
        if cancelButton then cancelButton:Disable() end
        if statusText then statusText:SetText("Stopping after current mail...") end
        Print("Stopping after the current mail finishes.")
    else
        SaveProgress("cancelled")
        StopRun("Paused. Use /rm resume or the Resume button to continue.", false)
    end
end

local function ConfirmRestartRun()
    local job = GetSavedJob()
    if not job then
        StartFreshRun()
        return
    end

    if not StaticPopupDialogs["RAIDMAILER_RESTART_CONFIRM"] then
        StaticPopupDialogs["RAIDMAILER_RESTART_CONFIRM"] = {
            text = "RaidMailer has already sent %d of %d mails. Restarting may send duplicate items to those recipients. Restart from the beginning?",
            button1 = YES,
            button2 = CANCEL,
            OnAccept = function(_, data)
                RestartRun()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    StaticPopup_Show("RAIDMAILER_RESTART_CONFIRM", job.nextIndex - 1, #job.recipients)
end

local function CreatePanel()
    if panel or not SendMailFrame then return end

    panel = CreateFrame("Frame", "RaidMailerPanel", SendMailFrame, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, ((MailFrame and MailFrame:GetHeight()) or PANEL_HEIGHT_FALLBACK) + PANEL_HEIGHT_CORRECTION)
    ApplyPanelPosition()
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -13)
    title:SetText("RaidMailer")

    settingsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    settingsButton:SetSize(76, 22)
    settingsButton:SetPoint("TOPRIGHT", -12, -10)
    settingsButton:SetText("Settings")
    settingsButton:SetScript("OnClick", ShowSettingsWindow)

    local quantityLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    quantityLabel:SetPoint("TOPLEFT", 16, -47)
    quantityLabel:SetText("Qty")

    quantityEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    quantityEdit:SetSize(54, 22)
    quantityEdit:SetPoint("TOPLEFT", 16, -64)
    quantityEdit:SetAutoFocus(false)
    quantityEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    quantityEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    quantityEdit:SetScript("OnTextChanged", function()
        if UpdatePanel then UpdatePanel() end
    end)

    local itemLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemLabel:SetPoint("TOPLEFT", 88, -47)
    itemLabel:SetText("Item ID")

    itemIDEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    itemIDEdit:SetSize(110, 22)
    itemIDEdit:SetPoint("TOPLEFT", 88, -64)
    itemIDEdit:SetAutoFocus(false)
    itemIDEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    itemIDEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    itemIDEdit:SetScript("OnTextChanged", function()
        UpdateItemNamePreview()
        if UpdatePanel then UpdatePanel() end
    end)

    itemNameText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    itemNameText:SetPoint("LEFT", itemIDEdit, "RIGHT", 8, 0)
    itemNameText:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    itemNameText:SetJustifyH("LEFT")

    local recipientsLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    recipientsLabel:SetPoint("TOPLEFT", 16, -99)
    recipientsLabel:SetText("Recipients (one character per line)")

    local recipientsBorder = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    recipientsBorder:SetPoint("TOPLEFT", 14, -116)
    recipientsBorder:SetPoint("TOPRIGHT", -14, -116)
    recipientsBorder:SetHeight(RECIPIENTS_VISIBLE_HEIGHT)
    recipientsBorder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    recipientsBorder:SetBackdropColor(0.03, 0.03, 0.03, 0.85)

    recipientsScrollFrame = CreateFrame("ScrollFrame", "RaidMailerRecipientsScrollFrame", recipientsBorder, "UIPanelScrollFrameTemplate")
    recipientsScrollFrame:SetPoint("TOPLEFT", 7, -7)
    recipientsScrollFrame:SetPoint("BOTTOMRIGHT", -28, 7)

    recipientsEdit = CreateFrame("EditBox", nil, recipientsScrollFrame)
    recipientsEdit:SetMultiLine(true)
    recipientsEdit:SetAutoFocus(false)
    recipientsEdit:SetFontObject(ChatFontNormal)
    recipientsEdit:SetWidth(280)
    recipientsEdit:SetHeight(RECIPIENTS_EDIT_MIN_HEIGHT)
    recipientsEdit:SetJustifyH("LEFT")
    recipientsEdit:SetMaxLetters(8192)
    recipientsEdit:SetHistoryLines(0)
    recipientsEdit:SetAltArrowKeyMode(false)
    recipientsEdit:EnableMouse(true)
    recipientsEdit:SetBlinkSpeed(0.5)
    recipientsEdit:SetTextColor(1, 1, 1, 1)

    -- Keep the actual EditBox above the ScrollFrame in the mouse hit-test order.
    -- The EditBox must receive the click itself for WoW to place the insertion
    -- cursor at the clicked character; merely focusing it is not sufficient.
    recipientsEdit:SetFrameLevel(recipientsScrollFrame:GetFrameLevel() + 1)

    -- Match Blizzard's native multiline scrolling-edit pattern. The EditBox is
    -- the ScrollFrame child and WoW is allowed to manage its multiline height.
    recipientsScrollFrame:SetScrollChild(recipientsEdit)

    if ScrollingEdit_OnCursorChanged then
        ScrollingEdit_OnCursorChanged(recipientsEdit, 0, 0, 0, 0)
    end

    recipientsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    recipientsEdit:SetScript("OnCursorChanged", function(self, x, y, w, h)
        if ScrollingEdit_OnCursorChanged then
            ScrollingEdit_OnCursorChanged(self, x, y, w, h)
        end
    end)
    recipientsEdit:SetScript("OnUpdate", function(self, elapsed)
        if ScrollingEdit_OnUpdate then
            ScrollingEdit_OnUpdate(self, elapsed, recipientsScrollFrame)
        end
    end)
    recipientsEdit:SetScript("OnTextChanged", function(self)
        if ScrollingEdit_OnTextChanged then
            ScrollingEdit_OnTextChanged(self, recipientsScrollFrame)
        elseif recipientsScrollFrame.UpdateScrollChildRect then
            recipientsScrollFrame:UpdateScrollChildRect()
        end
        if UpdatePanel then UpdatePanel() end
    end)

    configRevertButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    configRevertButton:SetSize(104, 23)
    configRevertButton:SetPoint("TOPRIGHT", recipientsBorder, "BOTTOMRIGHT", 0, -8)
    configRevertButton:SetText("Revert")
    configRevertButton:SetScript("OnClick", LoadConfigIntoPanelFields)

    configSaveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    configSaveButton:SetSize(82, 23)
    configSaveButton:SetPoint("RIGHT", configRevertButton, "LEFT", -8, 0)
    configSaveButton:SetText("Save")
    configSaveButton:SetScript("OnClick", SaveDistributionConfigFromUI)

    sendButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    sendButton:SetSize(210, 25)
    sendButton:SetPoint("BOTTOMLEFT", 14, 14)
    sendButton:SetScript("OnClick", function()
        if state.running then return end
        StartOrResume()
    end)

    cancelButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    cancelButton:SetSize(104, 25)
    cancelButton:SetPoint("LEFT", sendButton, "RIGHT", 8, 0)
    cancelButton:SetText("Cancel")
    cancelButton:SetScript("OnClick", function()
        if state.running then
            CancelRun()
        elseif GetSavedJob() then
            ConfirmRestartRun()
        end
    end)
    cancelButton:Disable()

    detailText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detailText:SetPoint("BOTTOMLEFT", sendButton, "TOPLEFT", 2, 12)
    detailText:SetPoint("BOTTOMRIGHT", cancelButton, "TOPRIGHT", -2, 12)
    detailText:SetJustifyH("LEFT")
    detailText:SetWordWrap(true)

    statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusText:SetPoint("BOTTOMLEFT", detailText, "TOPLEFT", 0, 5)
    statusText:SetPoint("BOTTOMRIGHT", detailText, "TOPRIGHT", 0, 5)
    statusText:SetJustifyH("LEFT")

    local separator = panel:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(0.35, 0.35, 0.35, 0.7)
    separator:SetPoint("BOTTOMLEFT", statusText, "TOPLEFT", -2, 11)
    separator:SetPoint("BOTTOMRIGHT", statusText, "TOPRIGHT", 2, 11)
    separator:SetHeight(1)

    LoadConfigIntoPanelFields()
    UpdatePanel()
end

local function IsMailRecipientCapError(errorType, message)
    if GetGameMessageInfo and errorType then
        local stringID = GetGameMessageInfo(errorType)
        if stringID == "ERR_MAIL_REACHED_CAP" then
            return true
        end
    end

    if ERR_MAIL_REACHED_CAP and message == ERR_MAIL_REACHED_CAP then
        return true
    end

    return message == "You have reached the in-game cap of unique mail recipients"
end

local function PauseForMailCap()
    if not state.running then return end
    local recipient = state.currentRecipient or state.recipients[state.index] or "next recipient"
    SaveProgress("mailcap")
    StopRun("Paused before " .. recipient .. ": WoW's unique mail recipient cap was reached. No further mail was sent. Resume this saved batch later with /rm resume or the Resume button.", true)
end

frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
frame:RegisterEvent("MAIL_FAILED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            EnsureDatabases()
        end

    elseif event == "MAIL_SHOW" then
        CreatePanel()
        UpdatePanel()

    elseif event == "MAIL_CLOSED" or event == "PLAYER_ENTERING_WORLD" then
        if settingsFrame and event == "MAIL_CLOSED" then settingsFrame:Hide() end
        if state.running then
            state.generation = state.generation + 1
            state.running = false
            state.awaitingResult = false
            state.awaitingAttachment = false
            state.attachmentStartedAt = nil
            state.awaitingSplit = false
            state.splitStartedAt = nil
            state.splitBag = nil
            state.splitSlot = nil
            state.awaitingRetry = false
            state.awaitingMailClear = false
            state.mailClearStartedAt = nil
            SaveProgress("mailboxclosed")
            state.mailRetryCount = 0
            state.currentRecipient = nil
            state.itemID = nil
            state.quantity = nil
            state.cancelRequested = false
            Print("Paused because the mailbox is no longer open. Reopen a mailbox and use Resume to continue.")
        end

    elseif event == "MAIL_SEND_INFO_UPDATE" then
        if state.running and state.awaitingAttachment and not state.awaitingResult then
            local generation = state.generation
            C_Timer.After(STATE_POLL_INTERVAL, function()
                VerifyAttachmentAndSend(generation)
            end)
        elseif state.running and state.awaitingMailClear then
            local generation = state.generation
            C_Timer.After(STATE_POLL_INTERVAL, function()
                VerifyPreviousMailCleared(generation)
            end)
        end

    elseif event == "MAIL_SEND_SUCCESS" then
        if not state.running or not state.awaitingResult then
            return
        end

        state.awaitingResult = false
        state.mailRetryCount = 0
        state.sent = state.sent + 1
        state.index = state.index + 1
        state.currentRecipient = nil
        SaveProgress(nil)

        if state.cancelRequested then
            SaveProgress("cancelled")
            StopRun(string.format("Paused after sending %d mail%s. Use /rm resume to continue.", state.sent, state.sent == 1 and "" or "s"), false)
            return
        end

        UpdatePanel()

        -- Do not begin manipulating the next bag item immediately after a
        -- successful send.  Give the compose UI a quiet period, then require
        -- the previous attachment slot to be genuinely clear before continuing.
        state.awaitingMailClear = true
        state.mailClearStartedAt = GetTime()
        local generation = state.generation
        C_Timer.After(GetNextMailDelay(), function()
            VerifyPreviousMailCleared(generation)
        end)

    elseif event == "UI_ERROR_MESSAGE" then
        local errorType, message = ...
        if state.running and IsMailRecipientCapError(errorType, message) then
            PauseForMailCap()
        end

    elseif event == "MAIL_FAILED" then
        if state.running and state.awaitingResult then
            local failedRecipient = state.currentRecipient or "unknown recipient"
            state.awaitingResult = false

            if state.mailRetryCount < MAX_MAIL_RETRIES then
                state.mailRetryCount = state.mailRetryCount + 1
                state.awaitingRetry = true
                local delay = MAIL_RETRY_DELAY * state.mailRetryCount
                Print(string.format("Mail attempt failed for %s; retrying the same recipient in %.0f second%s (%d/%d).", failedRecipient, delay, delay == 1 and "" or "s", state.mailRetryCount, MAX_MAIL_RETRIES))
                UpdatePanel()

                local generation = state.generation
                C_Timer.After(delay, function()
                    RetryCurrentMail(generation)
                end)
            else
                StopRun("Mail failed for " .. failedRecipient .. " after " .. (MAX_MAIL_RETRIES + 1) .. " attempts. No further mail was sent.", true)
            end
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        UpdatePanel()
        if state.running and state.awaitingSplit then
            local generation = state.generation
            C_Timer.After(STATE_POLL_INTERVAL, function()
                VerifySplitAndAttach(generation)
            end)
        end
    end
end)

SLASH_RAIDMAILER1 = "/rm"
SLASH_RAIDMAILER2 = "/raidmailer"
SlashCmdList.RAIDMAILER = function(msg)
    msg = Trim((msg or ""):lower())

    if msg == "send" then
        StartOrResume()
    elseif msg == "resume" then
        ResumeRun()
    elseif msg == "restart" then
        RestartRun()
    elseif msg == "reset" then
        ResetSavedRun()
    elseif msg == "cancel" or msg == "stop" then
        CancelRun()
    elseif msg == "settings" then
        ShowSettingsWindow()
    else
        local savedJob = GetSavedJob()
        if savedJob then
            local total = #savedJob.recipients
            local sent = savedJob.nextIndex - 1
            local remaining = total - sent
            Print(string.format("Saved batch: %s, %d per mail. %d/%d sent, %d remaining. Next: %s.", GetItemNameByID(savedJob.itemID), savedJob.quantity, sent, total, remaining, savedJob.recipients[savedJob.nextIndex]))
            Print("Commands: /rm resume, /rm restart, /rm reset, /rm cancel, /rm settings")
        else
            local recipients, duplicates, skippedSelf = ParseRecipients()
            Print(string.format("Item: %s. Quantity/mail: %d. %d recipient(s), %d in bags, %d duplicate(s), %d self entry/entries skipped.", GetConfiguredItemName(), GetConfiguredQuantity(), #recipients, CountConfiguredItemsInBags(), #duplicates, skippedSelf))
            Print("Open a mailbox and select the Send Mail tab to edit the distribution list. Commands: /rm send, /rm settings")
        end
    end
end
