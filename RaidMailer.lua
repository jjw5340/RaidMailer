local ADDON_NAME = ...

local BODY = ""
local DEFAULT_NEXT_MAIL_DELAY = 1.00
local DEFAULT_PANEL_OFFSET_X = 8
local DEFAULT_PANEL_OFFSET_Y = -32
local ATTACHMENT_SETTLE_DELAY = 0.35
local MAIL_CLEAR_TIMEOUT = 12.0
local STATE_POLL_INTERVAL = 0.10
local BAG_OPERATION_TIMEOUT = 12.0
local ATTACHMENT_TIMEOUT = 12.0
local ITEM_LOCK_TIMEOUT = 12.0
local MAIL_RETRY_DELAY = 2.0
local MAX_MAIL_RETRIES = 3


local function GetNextMailDelay()
    local configured = RaidMailerConfig and tonumber(RaidMailerConfig.interMailDelay)
    if configured then
        -- Very short gaps are where the Anniversary mail UI has proven flaky.
        -- Keep a conservative floor even if the config is accidentally lower.
        return math.max(0.75, math.min(configured, 10.0))
    end
    return DEFAULT_NEXT_MAIL_DELAY
end

local function GetPanelOffsetX()
    local configured = RaidMailerConfig and tonumber(RaidMailerConfig.panelOffsetX)
    return configured or DEFAULT_PANEL_OFFSET_X
end

local function GetPanelOffsetY()
    local configured = RaidMailerConfig and tonumber(RaidMailerConfig.panelOffsetY)
    return configured or DEFAULT_PANEL_OFFSET_Y
end

local function GetConfiguredItemID()
    return RaidMailerConfig and tonumber(RaidMailerConfig.itemID) or nil
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
    index = 0,
    sent = 0,
    currentRecipient = nil,
    generation = 0,
    cancelRequested = false,
}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9482c9RaidMailer:|r " .. tostring(message))
end

local function GetRunItemID()
    return state.itemID or GetConfiguredItemID()
end

local function GetRunItemName()
    return GetItemNameByID(GetRunItemID())
end

local function EnsureDB()
    if type(RaidMailerDB) ~= "table" then
        RaidMailerDB = {}
    end
end

local function CopyArray(source)
    local copy = {}
    for i = 1, #source do
        copy[i] = source[i]
    end
    return copy
end

local function GetSavedJob()
    EnsureDB()
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

    job.nextIndex = nextIndex
    job.sent = math.max(0, math.min(total, tonumber(job.sent) or (nextIndex - 1)))
    return job
end

local function CreateSavedJob(itemID, recipients)
    EnsureDB()
    RaidMailerDB.job = {
        version = 1,
        itemID = itemID,
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
    EnsureDB()
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
    EnsureDB()
    RaidMailerDB.job = nil
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

local function FindConfiguredSingleton()
    local itemID = GetRunItemID()
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
    local itemID = GetRunItemID()
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
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", GetPanelOffsetX(), GetPanelOffsetY())
end

local function UpdatePanel()
    if not panel then return end
    ApplyPanelPosition()

    local itemID = GetConfiguredItemID()
    local itemName = GetRunItemName()
    local recipients, duplicates, skippedSelf = ParseRecipients()
    local items = CountConfiguredItemsInBags()
    local savedJob = GetSavedJob()

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
        detailText:SetText(string.format("%s remaining: %d", GetRunItemName(), CountItemInBags(GetRunItemID())))
        return
    end

    if savedJob then
        local total = #savedJob.recipients
        local sent = savedJob.nextIndex - 1
        local remaining = total - sent
        local savedItemName = GetItemNameByID(savedJob.itemID)
        local nextRecipient = savedJob.recipients[savedJob.nextIndex] or "?"

        sendButton:SetText(string.format("Resume (%d left)", remaining))
        cancelButton:SetText("Restart")
        cancelButton:Enable()

        if savedJob.pausedReason == "mailcap" then
            statusText:SetText(string.format("Paused: mail cap (%d/%d sent)", sent, total))
        else
            statusText:SetText(string.format("Paused: %d/%d sent", sent, total))
        end
        detailText:SetText(string.format("Next: %s. %d %s in bags.", nextRecipient, CountItemInBags(savedJob.itemID), savedItemName))

        if CountItemInBags(savedJob.itemID) < remaining then
            sendButton:Disable()
            detailText:SetText(string.format("Next: %s. Need %d more %s to finish.", nextRecipient, remaining, savedItemName))
        else
            sendButton:Enable()
        end
        return
    end

    cancelButton:SetText("Cancel")
    cancelButton:Disable()
    sendButton:SetText(string.format("Send Items (%d)", #recipients))

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

local function AttachSingletonFromBag(generation, bag, slot, lockStartedAt)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit or state.awaitingRetry or state.awaitingMailClear then
        return
    end

    local info = GetContainerInfo(bag, slot)
    if not info or info.itemID ~= GetRunItemID() or (info.stackCount or 0) ~= 1 then
        StopRun("Stopped: the prepared 1-item stack is no longer available.", true)
        return
    end

    if info.isLocked then
        lockStartedAt = lockStartedAt or GetTime()
        if GetTime() - lockStartedAt < ITEM_LOCK_TIMEOUT then
            C_Timer.After(STATE_POLL_INTERVAL, function()
                AttachSingletonFromBag(generation, bag, slot, lockStartedAt)
            end)
            return
        end

        StopRun("Stopped: the prepared 1-item " .. GetRunItemName() .. " stack remained locked for more than " .. ITEM_LOCK_TIMEOUT .. " seconds.", true)
        return
    end

    ClearCursor()
    PickupContainerSlot(bag, slot)

    if not CursorHasItem() then
        StopRun("Stopped: could not pick up a single " .. GetRunItemName() .. " from your bags.", true)
        return
    end

    -- MAIL_SEND_INFO_UPDATE may fire from inside ClickSendMailItemButton(),
    -- so mark this state before dropping the cursor item into the mail slot.
    state.awaitingAttachment = true
    state.attachmentStartedAt = GetTime()
    state.currentRecipient = state.recipients[state.index]
    UpdatePanel()

    ClickSendMailItemButton(1)

    C_Timer.After(STATE_POLL_INTERVAL, function()
        VerifyAttachmentAndSend(generation)
    end)
end

local function PrepareOneItemInBag(generation, sourceBag, sourceSlot)
    local emptyBag, emptySlot = FindEmptyGeneralBagSlot()
    if not emptyBag then
        StopRun("Stopped: RaidMailer needs one empty slot in the backpack or an ordinary bag to split " .. GetRunItemName() .. ".", true)
        return
    end

    ClearCursor()
    SplitContainerStack(sourceBag, sourceSlot, 1)

    if not CursorHasItem() then
        StopRun("Stopped: could not split one " .. GetRunItemName() .. " from the source stack.", true)
        return
    end

    -- Put the split item into a real bag slot first.  The Anniversary client
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

    -- BAG_UPDATE_DELAYED is the normal continuation path.  Keep a timer
    -- fallback in case another addon/client quirk swallows that event.
    C_Timer.After(STATE_POLL_INTERVAL, function()
        VerifySplitAndAttach(generation)
    end)
end

local function BeginAttachOneConfiguredItem(generation, lockStartedAt)
    if generation ~= state.generation or not state.running or state.awaitingResult or state.awaitingAttachment or state.awaitingSplit or state.awaitingRetry or state.awaitingMailClear then
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

    if singleLocked or largeLocked then
        lockStartedAt = lockStartedAt or GetTime()
        if GetTime() - lockStartedAt < ITEM_LOCK_TIMEOUT then
            C_Timer.After(STATE_POLL_INTERVAL, function()
                BeginAttachOneConfiguredItem(generation, lockStartedAt)
            end)
            return
        end
    end

    local itemName = GetRunItemName()
    if singleLocked or largeLocked then
        StopRun("Stopped: the remaining " .. itemName .. " stayed locked for more than " .. ITEM_LOCK_TIMEOUT .. " seconds.", true)
    else
        StopRun("Stopped: no accessible " .. itemName .. " remains in your bags.", true)
    end
end

VerifySplitAndAttach = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingSplit or state.awaitingResult or state.awaitingAttachment or state.awaitingRetry then
        return
    end

    local bag, slot = state.splitBag, state.splitSlot
    local info = bag and slot and GetContainerInfo(bag, slot) or nil

    if info and info.itemID == GetRunItemID() and (info.stackCount or 0) == 1 and not info.isLocked then
        state.awaitingSplit = false
        state.splitStartedAt = nil
        state.splitBag = nil
        state.splitSlot = nil

        -- Give the bag system one additional frame after the slot becomes
        -- readable before picking the new singleton back up.
        C_Timer.After(STATE_POLL_INTERVAL, function()
            AttachSingletonFromBag(generation, bag, slot)
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

    StopRun("Stopped: WoW did not finish creating the 1-item " .. GetRunItemName() .. " stack within " .. BAG_OPERATION_TIMEOUT .. " seconds.", true)
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

    local name, itemID, _, count = GetSendMailItem(1)
    if name and itemID == GetRunItemID() and count == 1 then
        -- GetSendMailItem() can become readable slightly before the mail UI/server
        -- is fully settled.  Stop further attachment verification now, then
        -- give WoW a short quiet period before calling SendMail().
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
    StopRun("Stopped: WoW did not attach exactly one " .. GetRunItemName() .. " within " .. ATTACHMENT_TIMEOUT .. " seconds." .. diagnostic, true)
end

RetryCurrentMail = function(generation)
    if generation ~= state.generation or not state.running or not state.awaitingRetry then
        return
    end

    state.awaitingRetry = false

    -- A failed SendMail attempt normally leaves the attachment in the compose
    -- window.  Reuse it when it is still exactly the configured singleton.
    local name, itemID, _, count = GetSendMailItem(1)
    if name and itemID == GetRunItemID() and count == 1 then
        SendCurrentMail(generation)
        return
    end

    -- If WoW returned the attachment to the bags instead, rebuild the same
    -- recipient's message.  Never advance the recipient index on MAIL_FAILED.
    ClearSendMail()
    state.currentRecipient = state.recipients[state.index]
    BeginAttachOneConfiguredItem(generation, GetTime())
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
        local itemName = GetRunItemName()
        ClearSavedJob()
        StopRun(string.format("Complete: sent %d item%s (%s).", sent, sent == 1 and "" or "s", itemName), false)
        return
    end

    -- Each successful send should clear the compose state, but explicitly
    -- clear it here as well so every outgoing message starts from a known state.
    ClearSendMail()
    BeginAttachOneConfiguredItem(state.generation, GetTime())
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
    local items = CountItemInBags(job.itemID)
    if items < remaining then
        Print(string.format("Cannot resume: need %d %s but only %d are in your bags.", remaining, GetItemNameByID(job.itemID), items))
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
    state.index = job.nextIndex
    state.sent = job.nextIndex - 1
    state.currentRecipient = nil
    state.cancelRequested = false

    SaveProgress(nil)
    Print(string.format("%s: %d/%d already sent; %d remaining. Next: %s.", label, state.sent, #state.recipients, remaining, state.recipients[state.index]))
    UpdatePanel()
    SendNext()
end

local function StartFreshRun()
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

    if not ValidateMailboxReady() then return end

    local items = CountItemInBags(itemID)
    if items < #recipients then
        Print(string.format("Cannot start: need %d %s but only %d are in your bags.", #recipients, GetItemNameByID(itemID), items))
        return
    end

    local job = CreateSavedJob(itemID, recipients)
    local suffix = skippedSelf > 0 and " (your character skipped)" or ""
    Print(string.format("Starting new batch: %d recipient%s%s.", #recipients, #recipients == 1 and "" or "s", suffix))
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
    panel:SetSize(255, 128)
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
    sendButton:SetScript("OnClick", function()
        if state.running then return end
        StartOrResume()
    end)

    cancelButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    cancelButton:SetSize(78, 24)
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
            EnsureDB()
        end

    elseif event == "MAIL_SHOW" then
        CreatePanel()
        UpdatePanel()

    elseif event == "MAIL_CLOSED" or event == "PLAYER_ENTERING_WORLD" then
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
    else
        local savedJob = GetSavedJob()
        if savedJob then
            local total = #savedJob.recipients
            local sent = savedJob.nextIndex - 1
            local remaining = total - sent
            Print(string.format("Saved batch: %s. %d/%d sent, %d remaining. Next: %s.", GetItemNameByID(savedJob.itemID), sent, total, remaining, savedJob.recipients[savedJob.nextIndex]))
            Print("Commands: /rm resume, /rm restart, /rm reset, /rm cancel")
        else
            local recipients, duplicates, skippedSelf = ParseRecipients()
            Print(string.format("Item: %s. %d recipient(s), %d in bags, %d duplicate(s), %d self entry/entries skipped.", GetConfiguredItemName(), #recipients, CountConfiguredItemsInBags(), #duplicates, skippedSelf))
            Print("Open a mailbox, select the Send Mail tab, and use the RaidMailer panel. Commands: /rm send, /rm resume, /rm restart, /rm reset, /rm cancel")
        end
    end
end
