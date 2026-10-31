# Autosave while reapply is on; no Save button

The footer has no Save button. A camera's Profile exists **exactly while "Reapply on connect" is
on**: turning it on creates the Profile from the current values, turning it off deletes it, and
while it is on every edit is autosaved once interaction settles (after the 500ms settle read-back).
Reset to Defaults keeps the flag and autosaves the defaults as the new Snapshot.

## Status

accepted

## Context

A saved Snapshot is only ever used by reapply-on-connect. Keeping a separate Save step meant two
pieces of state the user had to keep in sync in their head (flag and Snapshot), plus dirty
tracking to drive the button. The useful intent is simpler: "keep this camera the way I last left
it."

## Considered Options

- **Profile ⇔ flag on; autosave on settle (chosen).** One rule, no dirty state, no Save button.
- **Keep the Snapshot when the flag goes off.** Rejected: turning the flag back on captures the
  current values anyway, so a kept Snapshot would never be read.
- **Save on every slider write.** Rejected: floods the disk during a drag and stores the values we
  sent rather than the camera's clamped readings; the settle read-back gives both for free.

## Consequences

- No dirty tracking in `AppModel`; `isDirty`/`persistedSnapshot` are gone.
- Only user edits (via the settle read-back) and Reset trigger a save; camera switches, discovery,
  and post-reapply refreshes do not.
- An edit still waiting for its settle is saved immediately, with its in-memory values, when the
  selection changes or the app quits — otherwise that last edit would be lost.
- Reset no longer turns the flag off; its alert says the defaults will replace the saved settings
  when the flag is on.
- The on-disk `reapplyOnConnect` field is kept for file compatibility; it is always `true` for
  profiles written under this rule.
