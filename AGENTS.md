# Continuing WalkingPad

On Michael's machine, read `/Users/michael/Documents/SUPERAPP/AGENTS.md` and `CURRENT_STATE.md` when starting or resuming work. For external AI access, read `/Users/michael/Documents/SUPERAPP_CONTROL/START_HERE.md`.

Elsewhere, start with `README.md`, `macos/README.md` and the relevant protocol notes. Inspect the checkout and preserve unrelated uncommitted changes.

Keep Walk focused on status, speed and Stop. Details belong in History or Settings. Prefer native controls and inexpensive updates. Explain non-obvious state transitions, persistence recovery and device protocol invariants beside the code.

Physical control belongs to the native app; the Python MCP surface is read-only. Use fake transport for tests. Stop must supersede pending Start/speed retries. A command acknowledgement does not prove the belt stopped. Preserve unsaved sessions and incomplete Health batches.

Separate automated checks from actual device reconnects and iPhone Health delivery. The phone import currently cannot guarantee exactly-once behavior after partial imports. Keep generated builds, personal health records, local research and credentials out of Git, especially the public repository.
