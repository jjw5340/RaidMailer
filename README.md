RaidMailer 0.2.0
For WoW Burning Crusade Classic Anniversary 2.5.6 (Interface 20506)

PURPOSE
-------
Sends exactly one configured item to each character in a configured list.

SETUP
-----
1. Open RaidMailerConfig.lua in a plain-text editor.
2. Set itemID to the numeric WoW item ID for the item you want to distribute.
3. Inside the recipients [[ ... ]] block, put one character name per line.
4. Remove the leading # from any placeholder lines you replace.
5. Save the file and /reload WoW.

Example:

RaidMailerConfig = {
    itemID = 32897, -- Mark of the Illidari

    recipients = [[
Veliice
Thordi
Anothername
]],
}

USE
---
1. Have enough of the configured item in your normal bags.
2. Open a mailbox.
3. Select the normal Send Mail tab.
4. The RaidMailer panel appears to the right.
5. Click the Send button once.

The addon sends one mail at a time. It waits for MAIL_SEND_SUCCESS before sending the next one and stops immediately on MAIL_FAILED.

SAFETY BEHAVIOR
---------------
- Duplicate recipient names prevent the batch from starting.
- Your current character is automatically skipped if listed.
- The batch will not start if the normal Send Mail form already contains a draft, money, C.O.D., or attachments.
- The batch will not start unless you have enough of the configured item for all recipients.
- Closing the mailbox stops the batch.
- Cancel stops before the next mail; if one mail is already in flight, it stops after that mail resolves.

SLASH COMMANDS
--------------
/rm              Show status.
/rm send         Start the batch (mailbox must be open).
/rm cancel       Stop the batch.

INSTALLATION
------------
Copy the entire RaidMailer folder to:
World of Warcraft\_anniversary_\Interface\AddOns\

The final path should be:
World of Warcraft\_anniversary_\Interface\AddOns\RaidMailer\RaidMailer.toc
