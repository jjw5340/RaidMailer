Illidari Mailer 0.1.0
For WoW Burning Crusade Classic Anniversary 2.5.6 (Interface 20506)

PURPOSE
-------
Sends exactly one Mark of the Illidari (item ID 32897) to each character in a configured list.

SETUP
-----
1. Open Recipients.lua in a plain-text editor.
2. Inside the [[ ... ]] block, put one character name per line.
3. Remove the leading # from any placeholder lines you replace.
4. Save the file and /reload WoW.

Example:

IllidariMailerRecipientText = [[
Veliice
Thordi
Anothername
]]

USE
---
1. Have enough Marks of the Illidari in your normal bags.
2. Open a mailbox.
3. Select the normal Send Mail tab.
4. The Illidari Mailer panel appears to the right.
5. Click "Send Marks" once.

The addon sends one mail at a time. It waits for MAIL_SEND_SUCCESS before sending the next one and stops immediately on MAIL_FAILED.

SAFETY BEHAVIOR
---------------
- Duplicate recipient names prevent the batch from starting.
- Your current character is automatically skipped if listed.
- The batch will not start if the normal Send Mail form already contains a draft, money, C.O.D., or attachments.
- The batch will not start unless you have enough Marks for all recipients.
- Closing the mailbox stops the batch.
- Cancel stops before the next mail; if one mail is already in flight, it stops after that mail resolves.

SLASH COMMANDS
--------------
/imailer              Show status.
/imailer send         Start the batch (mailbox must be open).
/imailer cancel       Stop the batch.

INSTALLATION
------------
Copy the entire IllidariMailer folder to:
World of Warcraft\_anniversary_\Interface\AddOns\

The final path should be:
World of Warcraft\_anniversary_\Interface\AddOns\IllidariMailer\IllidariMailer.toc
