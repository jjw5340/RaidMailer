RaidMailer 0.5.1
For WoW Burning Crusade Classic Anniversary 2.5.6 (Interface 20506)

PURPOSE
-------
Sends exactly one configured item to each character in a configured list.
Batch progress is saved per sender character and can be resumed later.

SETUP
-----
1. Open RaidMailerConfig.lua in a plain-text editor.
2. Set itemID to the numeric WoW item ID for the item you want to distribute.
3. Inside the recipients [[ ... ]] block, put one character name per line.
4. Optional: interMailDelay controls the minimum quiet time between a confirmed
   successful send and preparation of the next mail. Default/recommended: 1.0 s.
5. Save the file and /reload WoW.

USE
---
1. Have enough of the configured item in your normal bags. If the items are stacked, keep at least one empty slot in the backpack or an ordinary bag.
2. Open a mailbox and select the normal Send Mail tab.
3. Click Send Items to begin a new batch.
4. RaidMailer checkpoints progress after every MAIL_SEND_SUCCESS.
5. If a batch is paused, the main button changes to Resume and shows how many recipients remain.

PERSISTENT / RESUME BEHAVIOR
----------------------------
- Progress is stored in RaidMailerDB as a SavedVariablesPerCharacter database.
- The saved batch snapshots the item ID and recipient list at the time it starts.
- Only MAIL_SEND_SUCCESS advances the saved recipient index.
- Closing the mailbox, cancelling, logging out, /reload, or an error leaves the batch resumable.
- If WoW reports ERR_MAIL_REACHED_CAP (unique recipient anti-spam cap), RaidMailer pauses immediately instead of retrying the same blocked mail.
- Resume continues at the first recipient that has NOT received a confirmed successful mail.
- Restart begins again from the current config and can resend to already-completed recipients; the panel asks for confirmation.
- Reset clears the saved checkpoint without sending anything.

SLASH COMMANDS
--------------
/rm              Show current/saved status.
/rm send         Start a new batch, or resume an existing saved batch.
/rm resume       Resume the saved batch.
/rm restart      Start again from the beginning using the current config.
/rm reset        Forget saved batch progress without sending.
/rm cancel       Pause the running batch (after the current in-flight mail resolves).

TIMING / 0.5.1 CHANGE
---------------------
- Restored the normal minimum inter-mail delay to 1.0 second (configurable).
- After MAIL_SEND_SUCCESS, RaidMailer now waits for that minimum quiet period,
  then verifies that outgoing attachment slot 1 has actually cleared before
  manipulating the next bag item.
- The mail-clear verification can wait up to 12 seconds for server/UI lag.
- Bag/attachment/lock synchronization ceilings remain 12 seconds.
- Attachment timeout errors now include what GetSendMailItem(1) actually reports,
  which makes any remaining Anniversary-client race easier to diagnose.

INSTALLATION
------------
Copy the entire RaidMailer folder to:
World of Warcraft\_anniversary_\Interface\AddOns\

UPDATING FROM 0.5.0
-------------------
You may replace only RaidMailer.lua. Your existing RaidMailerConfig.lua remains
compatible and will use the 1.0-second default automatically. If desired, add:

    interMailDelay = 1.0,

to RaidMailerConfig next to itemID so the delay is easy to tune later.
