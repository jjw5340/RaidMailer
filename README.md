# RaidMailer

RaidMailer is a World of Warcraft addon for distributing a configured quantity of an item to a saved list of characters through in-game mail.

**Current tagged release:** 0.6.0  
**Game:** WoW Burning Crusade Classic Anniversary 2.5.6  
**Interface:** 20506

> The current development source contains unreleased in-game configuration UI and quantity-per-mail changes. The `.toc` version remains `0.6.0` until a later commit is selected and tagged as the next release.

## Purpose

RaidMailer automates repetitive raid-item distribution while retaining safeguards around mailbox state, server lag, failed sends, and WoW's unique-recipient mail cap.

A distribution job snapshots its item, quantity, and recipient list when it begins. Confirmed progress is saved after every `MAIL_SEND_SUCCESS`, so an interrupted or capped batch can be resumed later without resending completed recipients.

## Installation

Copy the entire `RaidMailer` folder to:

```text
World of Warcraft\_anniversary_\Interface\AddOns\
```

The resulting folder should contain at least:

```text
RaidMailer\
├── RaidMailer.lua
├── RaidMailer.toc
├── RaidMailerConfig.lua   # temporary legacy-migration source
└── README.md
```

## In-Game Configuration

Normal configuration is now performed in game. Players should not need to edit addon files.

Open a mailbox and select the normal **Send Mail** tab. The RaidMailer panel appears beside the mailbox and contains:

- **Quantity / mail** — number of the configured item sent to each recipient; default is `1`.
- **Item ID** — numeric WoW item ID to distribute.
- **Recipients** — one character name per line.
- **Save** — validates the quantity and item ID, then copies the displayed values into RaidMailer's per-character SavedVariables configuration.
- **Revert** — discards unsaved form changes and reloads the last saved values.

Unsaved distribution changes prevent a new batch from starting. A previously saved/paused job can still be resumed because it retains its own snapshot.

### Settings Window

Use the **Settings** button in the top-right of the RaidMailer panel, or `/rm settings`.

The Settings window contains:

- **Panel X offset** — positive values move the panel right.
- **Panel Y offset** — positive values move the panel up.
- **Inter-mail delay** — minimum quiet time after a confirmed successful mail before RaidMailer prepares the next one. Valid range: `0.75` to `10` seconds. Default/recommended: `1.0` second.

These preferences are account-wide and shared by all characters.

## SavedVariables Layout

RaidMailer uses two SavedVariables databases:

```lua
RaidMailerSettingsDB = {
    panelOffsetX = 8,
    panelOffsetY = -32,
    interMailDelay = 1.0,
}
```

`RaidMailerSettingsDB` is account-wide.

```lua
RaidMailerDB = {
    config = {
        quantity = 1,
        itemID = 32897,
        recipients = [[
CharacterOne
CharacterTwo
CharacterThree
]],
    },

    job = {
        -- Snapshot of an active/paused distribution job.
    },
}
```

`RaidMailerDB` is saved per character.

Clicking **Save** updates the SavedVariables table immediately in memory. WoW itself writes SavedVariables to the WTF folder during normal SavedVariables flushes such as `/reload`, logout, or client exit; addons cannot force an immediate disk write.

## Legacy `RaidMailerConfig.lua` Migration

The development build still loads `RaidMailerConfig.lua` for one-time migration from v0.6.0 and earlier.

If `RaidMailerDB.config` does not already exist, RaidMailer imports:

- `itemID` into the per-character distribution configuration;
- `recipients` into the per-character distribution configuration;
- `interMailDelay`, `panelOffsetX`, and `panelOffsetY` into the account-wide settings database;
- quantity defaults to `1`.

After the values have been migrated, normal configuration is performed through the in-game UI and subsequent changes to `RaidMailerConfig.lua` are ignored.

For an existing customized installation, preserve the old `RaidMailerConfig.lua` for the first login or `/reload` with this development build so RaidMailer can import it.

## Use

1. Open a mailbox and select the normal **Send Mail** tab.
2. Enter or review the quantity, item ID, and recipient list.
3. Click **Save** if the form has unsaved changes.
4. Have enough of the configured item in normal bags. If RaidMailer must split a stack, keep at least one empty slot in the backpack or an ordinary bag.
5. Click **Send Items**.
6. RaidMailer sends the configured quantity to each recipient and checkpoints progress after every confirmed successful mail.
7. If the job pauses, use **Resume** later to continue at the first recipient without a confirmed successful send.

If an exact stack of the configured quantity already exists, RaidMailer prefers it. Otherwise it splits the requested quantity from a larger stack into an empty normal bag slot, waits for bag synchronization, and then attaches that prepared stack to the mail.

## Normal Send-Mail Draft Handling

- A recipient already typed into the normal Send Mail recipient field is cleared automatically when RaidMailer starts or resumes.
- Existing attachments, money/COD, subject text, or body text are treated as a real draft and block RaidMailer so meaningful draft contents are not overwritten.

## Persistent / Resume Behavior

- An active job snapshots its item ID, quantity, and recipient list.
- Only `MAIL_SEND_SUCCESS` advances the saved recipient index.
- Closing the mailbox, cancelling, logging out, `/reload`, or an error leaves the batch resumable.
- If WoW reports `ERR_MAIL_REACHED_CAP`, RaidMailer pauses immediately rather than wasting retries against the recipient cap.
- **Resume** continues the saved snapshot.
- **Restart** discards the old progress only after current configuration validates and begins again from the saved distribution configuration. Restarting can resend items to recipients already completed by the previous job, so RaidMailer asks for confirmation.
- `/rm reset` clears saved job progress without sending anything.
- Saved jobs created by v0.6.0 are automatically interpreted as quantity `1`.

## Timing and Synchronization

RaidMailer deliberately waits for WoW's bag and mail APIs to agree with the visible UI rather than assuming operations complete instantly.

- Default minimum inter-mail delay: `1.0` second.
- After `MAIL_SEND_SUCCESS`, RaidMailer waits for the configured delay and then verifies that outgoing attachment slot 1 has actually cleared.
- Bag, attachment, item-lock, and mail-clear synchronization can wait up to 12 seconds for server/UI lag.
- Mail attachment verification checks both item ID and the configured quantity.
- Failed sends retry the same recipient rather than advancing the distribution.

## Slash Commands

- `/rm` — show current/saved status.
- `/rm send` — start a new batch or resume an existing saved batch.
- `/rm resume` — resume the saved batch.
- `/rm restart` — restart from the beginning using the current saved distribution configuration.
- `/rm reset` — forget saved batch progress without sending.
- `/rm cancel` — pause the running batch after any in-flight mail resolves.
- `/rm settings` — open the Settings window.

## Development Notes

The item entry currently accepts only a numeric item ID. Future versions may support item names and shift-clicked item links.

`RaidMailerConfig.lua` is retained temporarily only so pre-UI installations can migrate their existing values. It can be removed from the addon once legacy migration is no longer needed.
