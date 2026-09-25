# Garms — Product specification

Working name: Garms. Native Swift app for iOS, focused on fashion and clothing.

This document consolidates the product discussion. **Agreed** features define the intended experience, not a promise that every feature ships in the first release. **Proposed** details are implementation or interaction recommendations. **Future ideas** and **open decisions** are not committed scope.

## 1. Product vision

A near-infinite canvas for collecting clothes, arranging outfits, and deciding what to buy. Clothing images become movable cutout stickers while their original images, source links, metadata, and notes remain available.

The app brings together clothes already owned, potential purchases, and saved outfit inspiration. It should feel easy to collect something now and organise it visually later.

Keep the interface strictly focused on fashion for now. Structure the underlying data so other kinds of items could be supported later without designing a generic interface today.

## 2. Core concepts

| Concept | Responsibility |
| --- | --- |
| Product/item | The saved record: original images, cutout assets, metadata, notes, and ownership status. An outfit screenshot may initially be a single inspiration item. |
| Sticker | One placement of an item on a canvas, with its own position, size, stacking order, and group membership. |
| Group/outfit | A collection of sticker placements arranged together, optionally named. |
| Canvas | The space containing stickers and groups, with a saved viewing position and zoom. |

**Key rule:** duplicating a sticker does not duplicate its product. Multiple stickers reference the same product, while keeping independent layouts.

## 3. Collecting clothing

### Images and automatic cutouts — Agreed

- Import clothing images and automatically generate transparent foreground cutouts for use as stickers.
- Preserve the original images separately and make them accessible from the product.
- Place successfully imported stickers on the canvas automatically.
- Support photographs of clothes as well as saved screenshots and outfit inspiration.

**Constraint:** foreground extraction can select an entire person wearing clothes. Isolating an individual garment from a model or splitting a complete outfit into separate products is a different, more complex feature. A complete outfit screenshot initially remains one saved reference.

### Import from shared links — Agreed

From another app or website, such as Vinted, use the iOS share sheet to send a listing to Garms.

Intended flow:

1. Receive the shared URL and any images supplied with it.
2. Save the source and original images.
3. Extract available product metadata.
4. Generate a sticker cutout.
5. Add the linked sticker to the canvas.

Capture information where available; missing fields remain empty and editable. Automatic extraction from every site is not guaranteed. Actual Vinted shares need to be tested early.

**Proposed reliability behaviour:** save the link even if extraction fails, show import progress, support retry and manual image selection, and finish expensive processing when the main app runs if the share extension cannot complete it.

### Photos discovery onboarding — Agreed

- Offer an optional connection to Apple Photos through the system permission flow.
- Search accessible screenshots for likely clothing and outfit images using image analysis.
- Present candidates in a swipe review: right to include, left to skip.
- Include visible accept/skip buttons and undo.
- Accepted images enter the item and cutout import flow.
- Skipping never deletes the image from Photos.
- Respect limited photo access and allow onboarding to be skipped.

**Proposed:** review manageable batches rather than waiting for the entire library to be scanned. Clearly distinguish queued, analysed, and accepted images.

### Duplicate detection — Agreed

- Detect repeated source links and exact image matches.
- Flag visually similar images as possible duplicates rather than silently merging them.
- Offer to use the existing product or save a separate product.
- Reusing an existing product can create another sticker linked to it.

**Proposed:** treat different sizes or colour variants as separate products. Similar-looking clothes and different listings may be distinct items; visual similarity alone should not merge them.

## 4. Product information and search

### Product fields — Agreed

| Field | Behaviour |
| --- | --- |
| Name | Product name or editable title. |
| Brand | Optional. |
| Category | For example shoes, jacket, trousers, or shirt; used for search and alternatives. |
| Colour | Optional; allow more than one. |
| Price | Nullable: unknown is distinct from zero. |
| Currency | Saved with a known price. |
| Source | Original website/app link. |
| Images | Preserved originals and generated cutout assets. |
| Status | Exactly one of Considering, Owned, Ordered, Returned; radio buttons at product level. |
| Notes | Free-form text, including size, fit, occasions, and personal comments. |

New imports default to **Considering**. No separate structured size or fit field is required for the current scope; these belong in notes.

Product edits are shared by every sticker linked to that product. A saved price is a snapshot, not a promise of the current listing price.

### Notes and search — Agreed

- Index product metadata and notes for search.
- A note such as “Perfect for Elliot’s wedding” makes the product discoverable by “Elliot” or “wedding.”
- Support useful filters such as category, colour, brand, and ownership status.
- Search results can locate existing placements on the canvas or add another linked sticker.

**Future option:** semantic/vector search for meaning-based queries. Exact text search and filters remain useful regardless of whether semantic search is added.

## 5. Canvas interactions

### Navigation and placement — Agreed

- Near-infinite space for arranging clothing visually.
- Drag empty canvas space to pan; pinch to zoom the canvas.
- Drag a sticker to move it.
- Tap a sticker to select it and access its product information and actions.
- Preserve placement and size across sessions.

**Proposed:** add new imports near the last viewed area without obscuring existing items, and provide an import inbox so new arrivals remain easy to find.

### Resizing — Agreed

- Resize each sticker independently of canvas zoom.
- Show corner handles when a sticker is selected.
- Drag a corner to scale while preserving image proportions.
- Pinch a selected sticker to resize it; pinch elsewhere to zoom the canvas.
- Scale a selected group while preserving relative positions and sizes.
- Use resized sticker bounds for magnetic grouping.

**Interaction validation needed:** prototype gesture precedence so sticker resizing, canvas zoom, dragging, and alternative browsing do not conflict.

### Automatic stacking — Agreed

- The most recently dragged sticker comes to the front.
- Moving an entire group preserves the relative stacking order within that group.
- Allow garments to overlap naturally.

Manual forward/backward controls are not part of the agreed primary interaction.

### Duplicate and delete — Agreed

- Duplicate creates another placement of the same product.
- Copies have independent position, scale, stacking order, and group membership.
- Deleting a sticker removes that placement only.
- Deleting the product is a separate action affecting all linked stickers.

**Proposed safeguard:** make the impact of deleting a product explicit and support recovery.

## 6. Magnetic groups and outfits

### Grouping — Agreed

- Nearby stickers can magnetically join into a group.
- Preview the join subtly before the user releases the sticker.
- Joined stickers can move together while remaining easy to detach.
- Support group resizing without disturbing the internal composition.

**Proposed interaction:** use a slightly larger detach distance than attach distance to avoid unstable joining, and keep proximity thresholds consistent on screen at different zoom levels. Long-pressing an individual member and pulling it away detaches it.

### Naming — Agreed

Naming a newly formed group should become obvious without interrupting arrangement.

**Proposed interaction:** show a subtle group outline and an “Add outfit name” label. After naming, the label becomes a way to select or drag the group. Naming is optional.

### Cost — Agreed

- Show the total known product cost for an outfit.
- Show how much is still needed to purchase unowned pieces.
- Missing prices are nullable and explicitly disclosed, for example “£145 · 2 items unpriced.”
- Count a product once within the group even if it has multiple sticker placements.

**Open details:** define how Ordered and Returned affect the remaining-to-buy amount. Do not add unlike currencies into a single total without an explicit conversion policy; separate currency subtotals are a possible starting point.

### Export — Agreed

- Export a group as a clean image.
- Exclude selection outlines, handles, and other editing controls.
- Optionally include the group name and known total.

**Open details:** background choices, output resolution, and whether product labels should also be optional.

## 7. Fitting room for alternatives

### Purpose — Agreed

Try different pieces within an existing outfit without rearranging everything. For example, swipe through alternative shoes while keeping the rest of the outfit unchanged.

### Interaction — Agreed direction

1. Select a sticker and choose **Try alternatives**.
2. Swipe left or right to preview other products in the same category.
3. Keep the replacement in the same position and at a comparable visual size.
4. Show its name, known price, and ownership status.
5. Choose **Keep** to accept the replacement or **Cancel** to restore the original.

Use an explicit mode so swiping through alternatives does not conflict with dragging or panning.

- Default candidates come from the user’s saved collection.
- Filter by Owned, Considering, or All.
- Allow a handpicked shortlist for focused comparisons.
- **Save as another outfit** preserves both combinations side by side.
- Refresh the outfit cost when an alternative is previewed or selected.

### Data behaviour

- Accepting an alternative changes only the selected placement’s product reference.
- The original product remains saved and unchanged in other outfits.
- Cancelling restores the original placement and its appearance.
- Saving as another outfit creates new placements referencing existing products, not duplicate product records.
- Keep the position, group membership, and stacking order stable during comparison. Determine visual scale from the visible cutout rather than transparent image margins where possible.

## 8. Recommended foundations — Proposed, not yet confirmed

These were suggested as supporting features rather than explicitly committed release scope:

- Undo/redo for canvas changes, grouping, replacements, and deletions.
- Recently Deleted for products.
- Autosave and a clear backup strategy.
- Fit everything, go to outfit, and search-to-placement navigation.
- Correct imported metadata, choose another source image, and retry or adjust cutouts.
- Import states with retry and source preservation on failure.
- An import inbox for items not yet arranged.
- Accessible controls alongside gestures.
- Cross-device sync, subject to a decision about iPhone/iPad scope.

## 9. Future ideas — Not committed

- **Pre-made stickers and widgets:** offer decorative markers users can place beside collections/groups to distinguish them visually. For example, a big pink heart could indicate the best iteration or a finalised group; users can give these markers their own meaning.
- **Calendar on the canvas:** let users add a calendar graphic to the canvas and place groups/outfits onto different days to plan when to wear them. The calendar layout and how groups attach to days remain to be explored.
- **Live listing availability:** keep saved products linked to their source websites and surface availability changes, such as a one-of-a-kind Etsy item selling or an eBay listing becoming unavailable. A sold or unavailable product could appear greyed out or at reduced opacity on the canvas, with a clear availability label, while remaining saved in the user's collection. Website support, refresh frequency, and handling unknown or stale availability remain to be explored; a failed check should not imply that an item has sold.
- **Auction countdowns:** for products linked to auctions, such as on eBay, show a countdown over the product or another visual indicator that the auction ends soon. The exact presentation and behaviour when an auction ends remain to be explored.
- **Outfit variations:** create a more casual, warmer, or otherwise adapted version beside an existing outfit.
- **Inspiration matching:** match pieces in an outfit screenshot to items in the collection and identify gaps.
- **Similar-owned-item prompts:** surface clothes already owned when considering a similar purchase.
- **Capsule wardrobe and packing:** plan multiple outfits from a small set of products and generate a unique-item checklist.
- **Outfit history:** record when an outfit was worn and how it felt.
- **Visual similarity search:** search the collection using an image or sticker.
- **Garment-specific segmentation:** separate individual pieces from photos of people or full outfits.
- **Semantic search:** retrieve products by meaning across metadata and notes.
- **Multiple boards:** separate collections or projects if one canvas becomes limiting.
- **Generic use cases:** extend beyond clothing only after the fashion experience is established.

## 10. Technical direction — Proposed

- Native Swift app with SwiftUI for product screens and controls.
- Prototype a UIKit-backed canvas embedded in SwiftUI for gesture handling and rendering.
- Apple Vision foreground extraction for automatic cutouts.
- iOS Share Extension with an App Group import queue/shared container.
- Local database for records and relationships; file storage for original images and cutouts.
- Separate persistent canvas coordinates from screen coordinates.
- Load thumbnails at appropriate sizes and render nearby content rather than all full-resolution images.
- Keep extraction replaceable: generic page metadata first, source-specific handling where necessary.
- Start with indexed text search and filters; add embeddings only when there is a validated use case.

Technical references consulted during planning:

- [Apple: Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/)
- [Apple: Sharing data between an extension and its containing app](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- [Apple: App extension resource constraints](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

## 11. Suggested build sequence — Proposed

1. **Core proof:** image import, original preservation, cutouts, persistent canvas, moving and resizing.
2. **Outfit composition:** magnetic groups, naming, automatic stacking, duplicate placements, product details, status, notes, and costs.
3. **Collection workflow:** shared-link imports, duplicate detection, Photos discovery and swipe review, indexed search, and group export.
4. **Fitting room:** category-based alternatives, filters, shortlist, keep/cancel, and saving outfit variations.
5. **Further intelligence:** recommendations and semantic/visual search after the core experience is reliable.

Validate Vinted extraction and cutout quality early, alongside the canvas prototype. Their reliability may affect the import design. Add autosave and suitable recovery behaviour as the relevant editing features are built.

## 12. Decisions still to make

- Minimum iOS version and whether iPad is included at launch.
- One main canvas at launch or multiple boards; one canvas with named groups is the current recommendation.
- First-release boundary within the agreed feature set.
- Local-only storage versus cross-device sync and backup.
- On-device versus server processing for screenshot classification and difficult imports.
- Exact group selection/detachment and pinch gesture behaviour after prototyping.
- Remaining-to-buy cost rules and mixed-currency handling.
- Export options and quality.
- How full-outfit inspiration references differ from individual products in the UI.

## 13. Key acceptance scenarios

- Import an image, retain the original, generate a cutout, and find the resulting sticker on the canvas.
- Duplicate a sticker, resize the copy, and confirm both placements still open the same product and notes.
- Delete one placement without deleting its product or other placements.
- Arrange and name a group, move and resize it, then detach one piece without destroying the saved products.
- Search for “wedding” and find a product through its free-form notes.
- Review Photos suggestions, accept some and skip others without modifying the Photos originals.
- Re-share a known listing and reuse the existing product instead of silently creating another record.
- Preview replacement shoes, cancel to restore the original, then repeat and keep a replacement without changing other outfits.
- Calculate a group’s known cost with missing prices disclosed and repeated product placements counted once.
- Export a group image with no editing controls visible.
