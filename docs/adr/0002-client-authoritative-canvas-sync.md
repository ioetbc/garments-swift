# Client-authoritative canvas sync with row-level diffs

While a Canvas is being edited, the in-memory `CanvasDocument` on the device is the source of truth, not the Convex query. The Canvas loads via a subscription; each committed edit (the single `CanvasSession.complete(before)` choke point) diffs before/after and sends one mutation with the changed Stickers, Groups and Products — on gesture end, never per frame. Undo/redo stays client-side and syncs as ordinary edits. Remote updates are applied only between gestures. We chose this because the Convex Swift client has no optimistic updates, so rendering straight from queries would make drags lag and snap back.

## Considered Options

- **Server-driven rendering** (every action a mutation, UI from the query) — simplest, but round-trip latency on every gesture.
- **Whole-document blob, debounced** — least code, but discards the per-entity model and makes the whole Canvas last-write-wins.

## Consequences

- Concurrent edits from two devices resolve last-write-wins per row; acceptable while a Canvas has one User.
- Offline, the Canvas is read-only. A durable offline write queue is deliberately out of scope.
- Stacking order is a per-Sticker fractional key, so reordering writes one row instead of rewriting an order array.
