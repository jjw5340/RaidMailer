local ADDON_NAME = ...

local BODY = ""
local NEXT_MAIL_DELAY = 0.10

local function GetConfiguredItemID()
    return RaidMailerConfig and tonumber(RaidMailerConfig.itemID) or nil
end

local function GetConfiguredItemName()
    local itemID = GetConfiguredItemID()
    if not itemID then
        return "configured item"
    end

    local name = GetItemInfo(itemID)
    return name or ("item " .. itemID)
end

local frame = CreateFrame("Frame")
local panel
local sendButton
local cancelButton
local statusText
local detailText

local state = {
    running = false,
    awaitingResult = false,
    awaitingAttachment = false,
    attachmentVerifyAttempts = 0,
    awaitingSplit = false,
    splitVerifyAttempts = 0,
    splitBag = nil,
    splitSlot = nil,
    recipients = {},
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
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function ParseRecipients()
    local text = (RaidMailerConfig and RaidMailerConfig.recipients) or ""
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
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

local function CountConfiguredItemsInBags()
    local itemID = GetConfiguredItemID()
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

local function FindConfiguredSingleton()
    local itemID = GetConfiguredItemID()
    if not itemID then return nil, nil, false end

    local foundLocked = false

    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == itemID and (info.stackCount or 0) == 1 then
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

local function FindConfiguredLargeStack()
    local itemID = GetConfiguredItemID()
    if not itemID then return nil, nil, nil, false end

    local foundLocked = false

    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == itemID and (info.stackCount or 0) > 1 then
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

local function HasExistingDraft()
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

    if SendMailNameEditBox and Trim(SendMailNameEditBox:GetText() or "") ~= "" then
        return true, "a recipient"
    end

    if SendMailSubjectEditBox and Trim(SendMailSubjectEditBox:GetText() or "") ~= "" then
        return true, "a subject"
    end

    if SendMailBodyEditBox and Trim(SendMailBodyEditBox:GetText() or "") ~= "" then
        return true, "message text"
    end

    return false
end

local function UpdatePanel()
    if not panel then return end

    local itemID = GetConfiguredItemID()
    local itemName = GetConfiguredItemName()
    local recipients, duplicates, skippedSelf = ParseRecipients()
    local items = CountConfiguredItemsInBags()

    if state.running then
        sendButton:SetText("Sending...")
        sendButton:Disable()
        cancelButton:Enable()

        local total = #state.recipients
        local nextNumber = math.min(state.sent + 1, total)
        if state.currentRecipient then
            statusText:SetText(string.format("Sending %d/%d: %s", nextNumber, total, state.currentRecipient))
        else
            statusText:SetText(string.format("Sent %d/%d", state.sent, total))
        end
        detailText:SetText(string.format("%s remaining: %d", itemName, items))
        return
    end

    sendButton:SetText(string.format("Send Items (%d)", #recipients))
    cancelButton:Disable()

    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then
        statusText:SetText("Invalid item configuration")
        detailText:SetText("Set itemID in RaidMailerConfig.lua to a valid numeric WoW item ID.")
        sendButton:Disable()
    elseif #duplicates > 0 then
        statusText:SetText("Fix duplicate recipient names")
        detailText:SetText(table.concat(duplicates, ", "))
        sendButton:Disable()
    elseif #recipients == 0 then
        statusText:SetText("No recipients configured")
        detailText:SetText("Edit RaidMailerConfig.lua: one character name per line.")
        sendButton:Disable()
    elseif items < #recipients then
        statusText:SetText(string.format("Need %d; you have %d", #recipients, items))
        detailText:SetText("Configured item: " .. itemName)
        sendButton:Disable()
    else
        statusText:SetText(string.format("Ready: %d recipients, %d items", #recipients, items))
        if skippedSelf > 0 then
            detailText:SetText(string.format("%s. Your character is listed and will be skipped (%d time%s).", itemName, skippedSelf, skippedSelf == 1 and "" or "s"))
        else
            detailText:SetText("One " .. itemName .. " will be mailed to each listed character.")
        end
        sendButton:Enable()
    end
end

local function StopRun(message, isError)
    state.generation = state.generation + 1
    state.running = false
    state.awaitingResult = false
    state.awaitingAttachment = false
    state.attachmentVerifyAttempts = 0
    state.awaitingSplit = false
    state.splitVerifyAttempts = 0
    state.splitBag = nil
    state.splitSlot = nil
    state.currentRecipient = nil
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

local function AttachSingletonFromBag(generation, bag, slot)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit then
        return
    end

    local info = GetContainerInfo(bag, slot)
    if not info or info.itemID ~= GetConfiguredItemID() or (info.stackCount or 0) ~= 1 then
        StopRun("Stopped: the prepared 1-item stack is no longer available.", true)
        return
    end

    if info.isLocked then
        C_Timer.After(0.05, function()
            AttachSingletonFromBag(generation, bag, slot)
        end)
        return
    end

    ClearCursor()
    PickupContainerSlot(bag, slot)

    if not CursorHasItem() then
        StopRun("Stopped: could not pick up a single " .. GetConfiguredItemName() .. " from your bags.", true)
        return
    end

    -- MAIL_SEND_INFO_UPDATE may fire from inside ClickSendMailItemButton(),
    -- so mark this state before dropping the cursor item into the mail slot.
    state.awaitingAttachment = true
    state.attachmentVerifyAttempts = 0
    state.currentRecipient = state.recipients[state.index]
    UpdatePanel()

    ClickSendMailItemButton(1)

    C_Timer.After(0.05, function()
        VerifyAttachmentAndSend(generation)
    end)
end

local function PrepareOneItemInBag(generation, sourceBag, sourceSlot)
    local emptyBag, emptySlot = FindEmptyGeneralBagSlot()
    if not emptyBag then
        StopRun("Stopped: RaidMailer needs one empty slot in the backpack or an ordinary bag to split " .. GetConfiguredItemName() .. ".", true)
        return
    end

    ClearCursor()
    SplitContainerStack(sourceBag, sourceSlot, 1)

    if not CursorHasItem() then
        StopRun("Stopped: could not split one " .. GetConfiguredItemName() .. " from the source stack.", true)
        return
    end

    -- Put the split item into a real bag slot first.  The Anniversary client
    -- can fail when a freshly split cursor stack is attached directly to mail.
    PickupContainerSlot(emptyBag, emptySlot)

    if CursorHasItem() then
        ClearCursor()
        StopRun("Stopped: could not place the split " .. GetConfiguredItemName() .. " into an empty bag slot.", true)
        return
    end

    state.awaitingSplit = true
    state.splitVerifyAttempts = 0
    state.splitBag = emptyBag
    state.splitSlot = emptySlot
    state.currentRecipient = state.recipients[state.index]
    UpdatePanel()

    -- BAG_UPDATE_DELAYED is the normal continuation path.  Keep a timer
    -- fallback in case another addon/client quirk swallows that event.
    C_Timer.After(0.05, function()
        VerifySplitAndAttach(generation)
    end)
end

local function BeginAttachOneConfiguredItem(generation, retries)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit then
        return
    end

    -- Prefer an existing 1-item stack.  This both matches the proven manual
    -- workflow and prevents a large stack earlier in bag order from winning.
    local singleBag, singleSlot, singleLocked = FindConfiguredSingleton()
    if singleBag then
        AttachSingletonFromBag(generation, singleBag, singleSlot)
        return
    end

    local bag, slot, stackCount, largeLocked = FindConfiguredLargeStack()
    if bag then
        PrepareOneItemInBag(generation, bag, slot)
        return
    end

    if (singleLocked or largeLocked) and retries < 20 then
        C_Timer.After(0.05, function()
            BeginAttachOneConfiguredItem(generation, retries + 1)
        end)
        return
    end

    local itemName = GetConfiguredItemName()
    if singleLocked or largeLocked then
        StopRun("Stopped: the remaining " .. itemName .. " is still locked in your bags.", true)
    else
        StopRun("Stopped: no accessible " .. itemName .. " remains in your bags.", true)
    end
end

VerifySplitAndAttach = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingSplit or state.awaitingResult or state.awaitingAttachment then
        return
    end

    local bag, slot = state.splitBag, state.splitSlot
    local info = bag and slot and GetContainerInfo(bag, slot) or nil

    if info and info.itemID == GetConfiguredItemID() and (info.stackCount or 0) == 1 and not info.isLocked then
        state.awaitingSplit = false
        state.splitVerifyAttempts = 0
        state.splitBag = nil
        state.splitSlot = nil

        -- Do not pick the newly created stack back up in the same bag-update
        -- tick in which it became available.
        C_Timer.After(0.02, function()
            AttachSingletonFromBag(generation, bag, slot)
        end)
        return
    end

    state.splitVerifyAttempts = state.splitVerifyAttempts + 1
    if state.splitVerifyAttempts < 40 then
        C_Timer.After(0.05, function()
            VerifySplitAndAttach(generation)
        end)
        return
    end

    StopRun("Stopped: WoW did not finish creating the 1-item " .. GetConfiguredItemName() .. " stack in the temporary bag slot.", true)
end

VerifyAttachmentAndSend = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingAttachment or state.awaitingResult then
        return
    end

    local name, itemID, _, count = GetSendMailItem(1)
    if name and itemID == GetConfiguredItemID() and count == 1 then
        state.awaitingAttachment = false
        state.attachmentVerifyAttempts = 0
        state.awaitingResult = true
        UpdatePanel()
        SendMail(state.currentRecipient, GetConfiguredItemName(), BODY)
        return
    end

    state.attachmentVerifyAttempts = state.attachmentVerifyAttempts + 1
    if state.attachmentVerifyAttempts < 20 then
        C_Timer.After(0.05, function()
            VerifyAttachmentAndSend(generation)
        end)
        return
    end

    ClearCursor()
    StopRun("Stopped: WoW did not attach exactly one " .. GetConfiguredItemName() .. ".", true)
end

SendNext = function()
    if not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit then
        return
    end

    if not MailFrame or not MailFrame:IsShown() then
        StopRun("Stopped because the mailbox was closed.", true)
        return
    end

    if state.index > #state.recipients then
        local sent = state.sent
        StopRun(string.format("Complete: sent %d item%s (%s).", sent, sent == 1 and "" or "s", GetConfiguredItemName()), false)
        return
    end

    -- Each successful send should clear the compose state, but explicitly
    -- clear it here as well so every outgoing message starts from a known state.
    ClearSendMail()
    BeginAttachOneConfiguredItem(state.generation, 0)
end

local function StartRun()
    if state.running then return end

    local itemID = GetConfiguredItemID()
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then
        Print("Cannot start: set a valid numeric itemID in RaidMailerConfig.lua.")
        return
    end

    local recipients, duplicates, skippedSelf = ParseRecipients()

    if #duplicates > 0 then
        Print("Cannot start: duplicate recipient(s): " .. table.concat(duplicates, ", "))
        return
    end

    if #recipients == 0 then
        Print("Cannot start: no recipients are configured in RaidMailerConfig.lua.")
        return
    end

    local hasDraft, draftPart = HasExistingDraft()
    if hasDraft then
        Print("Cannot start while the normal Send Mail window contains " .. draftPart .. ". Clear the draft first.")
        return
    end

    local items = CountConfiguredItemsInBags()
    if items < #recipients then
        Print(string.format("Cannot start: need %d %s but only %d are in your bags.", #recipients, GetConfiguredItemName(), items))
        return
    end

    state.generation = state.generation + 1
    state.running = true
    state.awaitingResult = false
    state.awaitingAttachment = false
    state.attachmentVerifyAttempts = 0
    state.awaitingSplit = false
    state.splitVerifyAttempts = 0
    state.splitBag = nil
    state.splitSlot = nil
    state.recipients = recipients
    state.index = 1
    state.sent = 0
    state.currentRecipient = nil
    state.cancelRequested = false

    Print(string.format("Starting: %d recipient%s%s.", #recipients, #recipients == 1 and "" or "s", skippedSelf > 0 and " (your character skipped)" or ""))
    UpdatePanel()
    SendNext()
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
        StopRun("Cancelled.", false)
    end
end

local function CreatePanel()
    if panel or not SendMailFrame then return end

    panel = CreateFrame("Frame", "RaidMailerPanel", SendMailFrame, "BackdropTemplate")
    panel:SetSize(255, 128)
    panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 8, -32)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("RaidMailer")

    statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", 12, -38)
    statusText:SetPoint("TOPRIGHT", -12, -38)
    statusText:SetJustifyH("LEFT")

    detailText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detailText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -5)
    detailText:SetPoint("TOPRIGHT", statusText, "BOTTOMRIGHT", 0, -5)
    detailText:SetJustifyH("LEFT")
    detailText:SetWordWrap(true)

    sendButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    sendButton:SetSize(145, 24)
    sendButton:SetPoint("BOTTOMLEFT", 12, 12)
    sendButton:SetScript("OnClick", StartRun)

    cancelButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    cancelButton:SetSize(78, 24)
    cancelButton:SetPoint("LEFT", sendButton, "RIGHT", 8, 0)
    cancelButton:SetText("Cancel")
    cancelButton:SetScript("OnClick", CancelRun)
    cancelButton:Disable()

    UpdatePanel()
end

frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
frame:RegisterEvent("MAIL_FAILED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        CreatePanel()
        UpdatePanel()

    elseif event == "MAIL_CLOSED" or event == "PLAYER_ENTERING_WORLD" then
        if state.running then
            state.generation = state.generation + 1
            state.running = false
            state.awaitingResult = false
            state.awaitingAttachment = false
            state.attachmentVerifyAttempts = 0
            state.awaitingSplit = false
            state.splitVerifyAttempts = 0
            state.splitBag = nil
            state.splitSlot = nil
            state.currentRecipient = nil
            state.cancelRequested = false
            Print("Stopped because the mailbox is no longer open.")
        end

    elseif event == "MAIL_SEND_INFO_UPDATE" then
        if state.running and state.awaitingAttachment and not state.awaitingResult then
            local generation = state.generation
            C_Timer.After(0.01, function()
                VerifyAttachmentAndSend(generation)
            end)
        end

    elseif event == "MAIL_SEND_SUCCESS" then
        if not state.running or not state.awaitingResult then
            return
        end

        state.awaitingResult = false
        state.sent = state.sent + 1
        state.index = state.index + 1
        state.currentRecipient = nil

        if state.cancelRequested then
            StopRun(string.format("Cancelled after sending %d mail%s.", state.sent, state.sent == 1 and "" or "s"), false)
            return
        end

        UpdatePanel()

        local generation = state.generation
        C_Timer.After(NEXT_MAIL_DELAY, function()
            if state.running and state.generation == generation then
                SendNext()
            end
        end)

    elseif event == "MAIL_FAILED" then
        if state.running and state.awaitingResult then
            local failedRecipient = state.currentRecipient or "unknown recipient"
            state.awaitingResult = false
            StopRun("Mail failed for " .. failedRecipient .. ". No further mail was sent.", true)
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        UpdatePanel()
        if state.running and state.awaitingSplit then
            local generation = state.generation
            C_Timer.After(0.01, function()
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
        StartRun()
    elseif msg == "cancel" or msg == "stop" then
        CancelRun()
    else
        local recipients, duplicates, skippedSelf = ParseRecipients()
        Print(string.format("Item: %s. %d recipient(s), %d in bags, %d duplicate(s), %d self entry/entries skipped.", GetConfiguredItemName(), #recipients, CountConfiguredItemsInBags(), #duplicates, skippedSelf))
        Print("Open a mailbox, select the Send Mail tab, and use the RaidMailer panel. Commands: /rm send, /rm cancel")
    end
end
