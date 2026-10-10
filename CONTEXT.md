# Garms

A personal canvas for collecting clothing a person is considering buying, arranged spatially and grouped into wishlists.

## Language

**User**:
A person with a Garms account. Owns their Canvases and everything on them; nothing is shared between Users. A User exists from their first sign-in until they delete themselves; deleting a User removes everything they own.
_Avoid_: Account (except in UI copy), customer, member

**Canvas**:
An infinite board owned by one User, on which Products are placed and drawn on. A User has one Canvas today and may have several later.
_Avoid_: Board, document, workspace

**Viewport**:
The position and zoom a Canvas was last viewed at, shared across the User's devices.
_Avoid_: Camera (code name), view state

**Product**:
A clothing item a User has saved: its images, source link, title, price snapshot and notes. Belongs to the User, not to a Canvas, so edits show on every Sticker of it. A Product survives losing its last Sticker; only an explicit delete removes it.
_Avoid_: Item, listing, garment

**Cutout**:
A Product's transparent foreground image, the one its Stickers show.
_Avoid_: Asset, sticker image

**Original**:
A Product's image as imported, before background removal.
_Avoid_: Source image, originalAsset

**Photos**:
Extra images attached to a Product beyond its Cutout and Original.
_Avoid_: Gallery, galleryAssets

**Category**:
An optional, User-editable free-text label for what kind of garment a Product is (e.g. "Coat", "Shoes"), used for search.
_Avoid_: Type, kind

**Price**:
An optional amount in a currency recorded on a Product, a snapshot rather than the listing's live price. Prices in different currencies are never added together.
_Avoid_: Cost, listing price

**Availability**:
Whether a Product can still be bought from its source link, as last checked: available, sold, removed, out of stock, or unknown, plus when it was checked.
_Avoid_: Status, stock

**Sticker**:
One appearance of a Product on a Canvas, with its own position, size, stacking order and Group membership. A Product can have many Stickers, across one or several Canvases.
_Avoid_: Placement (code name), item, card

**Group**:
A set of Stickers on one Canvas joined by arranging them near each other, with an optional name, colour and notes. An outfit or a wishlist is a use of a Group, not a separate concept.
_Avoid_: Outfit, cluster, collection, named group

**Recent uploads**:
The one Group per Canvas where newly imported Stickers land. Otherwise an ordinary Group: Stickers can be dragged out of it.
_Avoid_: Inbox, imports group
