-- LEGACY MIGRATION SOURCE (v0.6.0 and earlier)
--
-- RaidMailer is now configured in game. This file remains temporarily so an
-- existing customized installation can be imported into SavedVariables on the
-- first load of the new development build. After RaidMailerDB.config exists,
-- changes to this file are ignored.
--
-- IMPORTANT FOR EXISTING USERS: preserve your customized copy of this file for
-- the first /reload after updating so RaidMailer can import it.
--
-- Legacy fields follow.
--
-- ITEM
-- Set itemID to the numeric WoW item ID for the item you want to distribute.
-- RaidMailer sends exactly ONE of this item to each configured recipient.
-- Example: Mark of the Illidari = 32897
--
-- TIMING
-- interMailDelay is the minimum quiet time (seconds) after a confirmed
-- MAIL_SEND_SUCCESS before RaidMailer begins preparing the next mail.
-- 1.0 is the recommended default. Increase to 1.25 or 1.5 if your server/UI
-- is especially laggy. RaidMailer also verifies that the previous outgoing
-- attachment slot has actually cleared before proceeding.
--
-- PANEL POSITION
-- The RaidMailer panel is anchored with its TOPLEFT corner to the mailbox
-- window's TOPRIGHT corner. panelOffsetX moves it horizontally (positive =
-- right); panelOffsetY moves it vertically (positive = up). The defaults
-- below reproduce the original RaidMailer position.
--
-- RECIPIENTS
-- Put ONE character name per line inside the [[ ... ]] block.
-- Blank lines and lines beginning with # are ignored.
-- You may use Name-Realm if your server/mail rules support it.
--
-- If your own character appears in the list, RaidMailer skips it
-- automatically (the assumption is that you simply keep your own item).

RaidMailerConfig = {
    itemID = 32897,
    interMailDelay = 1.0,
    panelOffsetX = 8,
    panelOffsetY = -32,

    recipients = [[
# Character01
# Character02
# Character03
# Character04
# Character05
# Character06
# Character07
# Character08
# Character09
# Character10
# Character11
# Character12
# Character13
# Character14
# Character15
# Character16
# Character17
# Character18
# Character19
# Character20
# Character21
# Character22
# Character23
# Character24
# Character25
]],
}
