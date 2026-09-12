-- RaidMailer configuration
--
-- ITEM
-- Set itemID to the numeric WoW item ID for the item you want to distribute.
-- RaidMailer sends exactly ONE of this item to each configured recipient.
-- Example: Mark of the Illidari = 32897
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
