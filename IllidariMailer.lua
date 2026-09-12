local ADDON_NAME = ...

local ITEM_ID = 32897 -- Mark of the Illidari
local ITEM_NAME = "Mark of the Illidari"
local SUBJECT = "Mark of the Illidari"
local BODY = ""
local NEXT_MAIL_DELAY = 0.10

local frame = CreateFrame("Frame")
local panel
local sendButton
local cancelButton
local statusText
local detailText

local state = {
    running = false,
    awaitingResult = false,
    recipients = {},
    index = 0,
    sent = 0,
    currentRecipient = nil,
    generation = 0,
    cancelRequested = false,
}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9482c9Illidari Mailer:|r " .. tostring(message))
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
    local text = IllidariMailerRecipientText or ""
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

local function CountMarksInBags()
    local total = 0
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == ITEM_ID then
                total = total + (info.stackCount or 0)
            end
        end
    end
    return total
end

local function FindMarkStack()
    local foundLocked = false

    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local info = GetContainerInfo(bag, slot)
            if info and info.itemID == ITEM_ID then
                if info.isLocked then
                    foundLocked = true
                elseif (info.stackCount or 0) > 0 then
                    return bag, slot, info.stackCount, false
                end
            end
        end
    end

    return nil, nil, nil, foundLocked
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

    local recipients, duplicates, skippedSelf = ParseRecipients()
    local marks = CountMarksInBags()

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
        detailText:SetText(string.format("Marks remaining: %d", marks))
        return
    end

    sendButton:SetText(string.format("Send Marks (%d)", #recipients))
    cancelButton:Disable()

    if #duplicates > 0 then
        statusText:SetText("Fix duplicate recipient names")
        detailText:SetText(table.concat(duplicates, ", "))
        sendButton:Disable()
    elseif #recipients == 0 then
        statusText:SetText("No recipients configured")
        detailText:SetText("Edit Recipients.lua: one character name per line.")
        sendButton:Disable()
    elseif marks < #recipients then
        statusText:SetText(string.format("Need %d Marks; you have %d", #recipients, marks))
        detailText:SetText("Not enough Marks of the Illidari in your bags.")
        sendButton:Disable()
    else
        statusText:SetText(string.format("Ready: %d recipients, %d Marks", #recipients, marks))
        if skippedSelf > 0 then
            detailText:SetText(string.format("Your character is listed and will be skipped (%d time%s).", skippedSelf, skippedSelf == 1 and "" or "s"))
        else
            detailText:SetText("One Mark will be mailed to each listed character.")
        end
        sendButton:Enable()
    end
end

local function StopRun(message, isError)
    state.generation = state.generation + 1
    state.running = false
    state.awaitingResult = false
    state.currentRecipient = nil
    state.cancelRequested = false

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

local function AttachOneMark()
    local bag, slot, stackCount, locked = FindMarkStack()
    if not bag then
        if locked then
            return false, "locked"
        end
        return false, "missing"
    end

    ClearCursor()

    if stackCount == 1 then
        if C_Container and C_Container.PickupContainerItem then
            C_Container.PickupContainerItem(bag, slot)
        else
            PickupContainerItem(bag, slot)
        end
    else
        if C_Container and C_Container.SplitContainerItem then
            C_Container.SplitContainerItem(bag, slot, 1)
        else
            SplitContainerItem(bag, slot, 1)
        end
    end

    if not CursorHasItem() then
        return false, "cursor"
    end

    ClickSendMailItemButton(1)

    local name, itemID, _, count = GetSendMailItem(1)
    if not name or itemID ~= ITEM_ID or count ~= 1 then
        ClearCursor()
        ClearSendMail()
        return false, "attachment"
    end

    return true
end

local SendNext

local function RetrySendNext(generation, retries)
    if generation ~= state.generation or not state.running or state.awaitingResult then
        return
    end

    local ok, reason = AttachOneMark()
    if ok then
        local recipient = state.recipients[state.index]
        state.currentRecipient = recipient
        state.awaitingResult = true
        UpdatePanel()
        SendMail(recipient, SUBJECT, BODY)
        return
    end

    if reason == "locked" and retries < 10 then
        C_Timer.After(0.10, function()
            RetrySendNext(generation, retries + 1)
        end)
        return
    end

    if reason == "missing" then
        StopRun("Stopped: no accessible " .. ITEM_NAME .. " remains in your bags.", true)
    elseif reason == "attachment" then
        StopRun("Stopped: WoW did not attach exactly one " .. ITEM_NAME .. ".", true)
    else
        StopRun("Stopped: could not pick up a " .. ITEM_NAME .. " from your bags.", true)
    end
end

SendNext = function()
    if not state.running or state.awaitingResult then
        return
    end

    if not MailFrame or not MailFrame:IsShown() then
        StopRun("Stopped because the mailbox was closed.", true)
        return
    end

    if state.index > #state.recipients then
        local sent = state.sent
        StopRun(string.format("Complete: sent %d %s%s.", sent, ITEM_NAME, sent == 1 and "" or "s"), false)
        return
    end

    -- Each successful send should clear the compose state, but explicitly
    -- clear it here as well so every outgoing message starts from a known state.
    ClearSendMail()
    RetrySendNext(state.generation, 0)
end

local function StartRun()
    if state.running then return end

    local recipients, duplicates, skippedSelf = ParseRecipients()

    if #duplicates > 0 then
        Print("Cannot start: duplicate recipient(s): " .. table.concat(duplicates, ", "))
        return
    end

    if #recipients == 0 then
        Print("Cannot start: no recipients are configured in Recipients.lua.")
        return
    end

    local hasDraft, draftPart = HasExistingDraft()
    if hasDraft then
        Print("Cannot start while the normal Send Mail window contains " .. draftPart .. ". Clear the draft first.")
        return
    end

    local marks = CountMarksInBags()
    if marks < #recipients then
        Print(string.format("Cannot start: need %d Marks but only %d are in your bags.", #recipients, marks))
        return
    end

    state.generation = state.generation + 1
    state.running = true
    state.awaitingResult = false
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

    panel = CreateFrame("Frame", "IllidariMailerPanel", SendMailFrame, "BackdropTemplate")
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
    title:SetText("Illidari Mailer")

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
            state.currentRecipient = nil
            state.cancelRequested = false
            Print("Stopped because the mailbox is no longer open.")
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
    end
end)

SLASH_ILLIDARIMAILER1 = "/illidarimailer"
SLASH_ILLIDARIMAILER2 = "/imailer"
SlashCmdList.ILLIDARIMAILER = function(msg)
    msg = Trim((msg or ""):lower())

    if msg == "send" then
        StartRun()
    elseif msg == "cancel" or msg == "stop" then
        CancelRun()
    else
        local recipients, duplicates, skippedSelf = ParseRecipients()
        Print(string.format("%d recipient(s), %d Mark(s) in bags, %d duplicate(s), %d self entry/entries skipped.", #recipients, CountMarksInBags(), #duplicates, skippedSelf))
        Print("Open a mailbox, select the Send Mail tab, and use the Illidari Mailer panel. Commands: /imailer send, /imailer cancel")
    end
end
