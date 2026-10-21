import Foundation

/// Import steps. Each lands through `edit`; enrichment after the insert is carried into undo, not added to it.
extension CanvasSession {
    func insertImport(_ record: SharedImport, artwork: ImportedImageDownload.Artwork) -> String? {
        guard hasInitialLayout, artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        resolveInteraction?()
        guard document.namedGroups.contains(where: \.isRecentUploads) else { return nil }
        let productID = UUID().uuidString
        let product = Product(id: productID, title: record.suggestedTitle ?? URL(string: record.url)?.host ?? "Saved link",
                              cutout: importedAssets.insert(artwork.data), aspect: artwork.aspect, sourceUrl: record.url)
        guard let id = edit({ snapshot -> String? in
            guard let id = snapshot.document.addToRecentUploads(productID: productID, aspect: artwork.aspect, fallback: camera.center) else { return nil }
            snapshot.document.products[productID] = product
            return id
        }), document.placements[id] != nil else { return nil }
        revealImport(id)
        return id
    }
    @discardableResult
    func appendImportPhoto(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], var product = document.products[placement.productID],
              artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        let asset = importedAssets.insert(artwork.data)
        product.photos.append(asset)
        edit(history: .enrich) { $0.document.products[product.id] = product }
        return document.products[product.id] == product ? asset : nil
    }
    @discardableResult
    func installImportOriginal(_ id: String, title: String?, price: Price?, artwork: ImportedImageDownload.Artwork) -> String? {
        updateImport(id, title: title, price: price, artwork: artwork, original: true)
    }
    @discardableResult
    func applyImportCutout(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], document.products[placement.productID]?.original != nil else { return nil }
        return updateImport(id, title: nil, price: nil, artwork: artwork, original: false)
    }
    @discardableResult
    func updateImport(_ id: String, title: String?, price: Price?, artwork: ImportedImageDownload.Artwork?, original: Bool = true) -> String? {
        guard document.placements[id] != nil else { return nil }
        resolveInteraction?()
        guard let placement = document.placements[id], var product = document.products[placement.productID] else { return nil }
        if let artwork { guard artwork.aspect.isFinite, artwork.aspect > 0 else { return nil } }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { product.title = title }
        if let price { product.price = price }
        if let artwork {
            product.cutout = importedAssets.insert(artwork.data)
            if original { product.original = product.cutout }
            product.aspect = artwork.aspect
        }
        edit(history: .enrich) { snapshot in
            snapshot.document.products[product.id] = product
            guard let artwork else { return }
            // Every Sticker shows the Product's image, so each keeps its centre and longest edge at the new aspect.
            for (sticker, shown) in snapshot.document.placements where shown.productID == product.id {
                snapshot.document.placements[sticker]?.fit(aspect: artwork.aspect)
            }
        }
        return document.products[product.id] == product ? product.cutout : nil
    }
    /// Records the listing found for an imported photo once it has been imported onto the Product like a shared link,
    /// keeping the photo as the first Photo.
    func attachListing(_ productID: String, url: String, screenshot: String) {
        guard document.products[productID] != nil else { return }
        resolveInteraction?()
        edit(history: .enrich) { snapshot in
            snapshot.document.products[productID]?.sourceUrl = url
            snapshot.document.products[productID]?.photos.insert(screenshot, at: 0)
        }
    }
}
