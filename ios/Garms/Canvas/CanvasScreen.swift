import SwiftUI
import UIKit
import PhotosUI
import Photos

struct CanvasScreen: View {
    let session: CanvasSession
    let onSettings: () -> Void
    @State private var statuses: [String: String] = [:]
    @State private var showingImports = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var sendingLogs: Set<UUID> = []
    @State private var logDelivery: [UUID: String] = [:]
    @State private var searchExpanded = false
    @State private var groupPlacement: StickerPlacement?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            CanvasHost(session: session)
                .ignoresSafeArea()
                .searchable(text: Binding(
                    get: { session.searchQuery },
                    set: { session.searchQuery = $0 }
                ), isPresented: $searchExpanded, prompt: "Search canvases")
                .searchSuggestions {
                    // Products with no Sticker are only reachable here; choosing one places it again.
                    ForEach(unplacedMatches) { product in
                        Button {
                            searchExpanded = false
                            session.placeSticker(of: product.id)
                        } label: {
                            Label(product.title, systemImage: "plus.circle")
                        }
                        .accessibilityHint("Places this product on the canvas")
                    }
                }
                .searchToolbarBehavior(.minimize)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "person.crop.circle") { onSettings() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingImports = true } label: {
                            Label("Imports (\(session.imports.pendingCount))", systemImage: "square.and.arrow.down")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
                            .disabled(!session.history.canUndo)
                            .keyboardShortcut("z", modifiers: .command)
                        Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }
                            .disabled(!session.history.canRedo)
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                    }
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
                .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
                .onChange(of: searchExpanded) { _, expanded in
                    if expanded {
                        session.resolveInteraction?()
                    } else {
                        session.searchQuery = ""
                    }
                }
        }
            .overlay(alignment: .top) {
                if session.hasLoaded && !session.isOnline {
                    Label("Offline — viewing only", systemImage: "wifi.slash")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .overlay {
                if session.imports.progress != nil {
                    ImportViewportProgress()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .sheet(item: Binding(
                get: { session.inspectedPlacement },
                set: { session.inspectedPlacement = $0 }
            )) { placement in
                productDetails(for: placement) {
                    session.inspectedPlacement = nil
                }
            }
            .sheet(item: Binding(
                get: { session.inspectedGroup },
                set: { session.inspectedGroup = $0 }
            ), onDismiss: {
                session.history.endCoalescing()
                groupPlacement = nil
            }) { group in
                let _ = session.revision
                CanvasGroupNameDrawer(
                    group: session.document.namedGroups?.first { $0.id == group.id } ?? group,
                    document: session.document,
                    library: session.importedAssets,
                    notes: Binding(
                        get: { session.document.namedGroups?.first { $0.id == group.id }?.notes ?? "" },
                        set: { session.updateGroupNotes(group.id, notes: $0) }
                    ),
                    onOpenItem: { placement in
                        groupPlacement = placement
                    }
                ) { name, colour in
                    session.updateGroup(group.id, name: name, backgroundColour: colour)
                }
                .sheet(item: $groupPlacement) { placement in
                    productDetails(for: placement) {
                        groupPlacement = nil
                    }
                }
                .presentationDetents([.height(410), .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingImports, onDismiss: { session.revealedMatch = nil }) {
                NavigationStack {
                    ScrollViewReader { proxy in
                    List {
                        Section {
                            photoPicker
                        }
                        if let notice = session.imports.notice { Text(notice).font(.callout) }
                        let awaiting = session.imports.awaitingMatch
                        let visible = session.imports.visibleItems
                        if visible.isEmpty && awaiting.isEmpty { Text("Choose photos or share a link to import items.") }
                        if !awaiting.isEmpty {
                            Section("Find the listing") {
                                ForEach(awaiting) { product in
                                    AwaitingMatchRow(product: product, library: session.importedAssets, imports: session.imports)
                                        .id(product.id)
                                }
                            }
                        }
                        ForEach(visible) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.displayName).lineLimit(2)
                                Text(item.failure ?? (item.stage == .loadingPhoto && item.state == "Processing" ? "Loading photo…" : item.stage == .removingBackground && item.state == "Processing" ? "Removing background…" : item.note ?? item.state)).font(.caption)
                                DisclosureGroup("Processing log") {
                                    Text(item.logs.joined(separator: "\n"))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                Button(sendingLogs.contains(item.id) ? "Sending…" : "Send log to Mac", systemImage: "desktopcomputer") {
                                    let id = item.id, report = item.diagnosticReport
                                    sendingLogs.insert(id)
                                    logDelivery[id] = nil
                                    Task {
                                        defer { sendingLogs.remove(id) }
                                        do {
                                            try await session.server.sendImportLog(report)
                                            logDelivery[id] = "Sent — check the Convex dashboard logs."
                                        } catch {
                                            logDelivery[id] = ImportDiagnostics.describe(error)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(sendingLogs.contains(item.id))
                                if let delivery = logDelivery[item.id] {
                                    Text(delivery).font(.caption).textSelection(.enabled)
                                }
                                HStack {
                                    Button("Copy log", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = item.diagnosticReport
                                    }.buttonStyle(.bordered)
                                    if item.state == "Failed" { Button("Retry") { session.imports.retry(item.id) }.buttonStyle(.bordered) }
                                    if item.canRetryBackground { Button("Retry background removal") { session.imports.retry(item.id) }.buttonStyle(.bordered) }
                                    Button("Dismiss", role: .destructive) { session.imports.dismiss(item.id) }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .navigationTitle("Imports")
                    .toolbar { Button("Done") { showingImports = false } }
                    .task(id: session.revealedMatch) {
                        if let id = session.revealedMatch { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .onChange(of: session.revealedMatch) { _, id in
                if id != nil { showingImports = true }
            }
            .alert("Canvas needs attention",isPresented:Binding(get:{ session.error != nil },set:{ if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .onChange(of: selectedPhotos) { _, photos in
                guard !photos.isEmpty else { return }
                session.resolveInteraction?()
                selectedPhotos = []
                Task {
                    for (index, photo) in photos.enumerated() {
                        // Screenshot check disabled for now: shared screenshots (e.g. saved from WhatsApp) aren't marked, so every photo is searched.
                        // let check = await Self.screenshotCheck(photo)
                        // session.imports.importPhoto(title: "Imported photo \(index + 1)", screenshot: check.isScreenshot, screenshotCheck: check.detail) {
                        session.imports.importPhoto(title: "Imported photo \(index + 1)", screenshot: true) {
                            guard let data = try await photo.loadTransferable(type: Data.self) else {
                                throw ImportedImageDownload.ImageError.detail("This photo could not be loaded. Retry or select another image.")
                            }
                            return data
                        }
                    }
                }
            }
            .onChange(of:phase) { _,v in
                if v != .active { session.resolveInteraction?() }
                session.imports.setActive(v == .active)
            }
            .task { session.imports.setActive(phase == .active) }
            .task(id: session.hasLoaded && session.isOnline) {
                if session.hasLoaded && session.isOnline { await session.loadAvailability() }
            }
    }

    private var unplacedMatches: [Product] {
        let query = session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let placed = Set(session.document.placements.values.map(\.productID))
        return session.document.products.values
            .filter { !placed.contains($0.id) && $0.matchesSearch(query) }
            .sorted { $0.title < $1.title }
    }

//     /// Whether Photos marks the picked image as a Screenshot, and why not. Needs library access; without it nothing is searched.
//     private static func screenshotCheck(_ item: PhotosPickerItem) async -> (isScreenshot: Bool, detail: String) {
//         guard let id = item.itemIdentifier else { return (false, "Screenshot check: the picker gave no Photos identifier.") }
//         var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
//         if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
//         guard status == .authorized || status == .limited else { return (false, "Screenshot check: Photos access is \(status.rawValue) (not authorized).") }
//         guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
//             return (false, "Screenshot check: Photos access is \(status == .limited ? "limited and excludes this photo" : "full but the photo was not found").")
//         }
//         let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
//         return (isScreenshot, "Screenshot check: Photos \(isScreenshot ? "marks" : "does not mark") this photo as a Screenshot (subtypes \(asset.mediaSubtypes.rawValue)).")
//     }

    private var photoPicker: some View {
        PhotosPicker(selection: $selectedPhotos, selectionBehavior: .ordered, matching: .images, photoLibrary: .shared()) {
            Label("Import photos", systemImage: "photo.badge.plus")
        }
        .accessibilityHint("Choose photos to add as separate items and remove their backgrounds")
    }

    @ViewBuilder
    private func productDetails(for placement: StickerPlacement, onDelete: @escaping () -> Void) -> some View {
        let _ = session.revision
        if let product = session.document.products[placement.productID] {
            CanvasImageDetails(product: product, library: session.importedAssets, server: session.server, status: Binding(
                get: { statuses[placement.id] ?? "Wishlist" },
                set: { statuses[placement.id] = $0 }
            ), title: Binding(
                get: { session.document.products[product.id]?.title ?? "" },
                set: { session.updateProductTitle(product.id, title: $0) }
            ), category: Binding(
                get: { session.document.products[product.id]?.category ?? "" },
                set: { session.updateProductCategory(product.id, category: $0) }
            ), price: Binding(
                get: { session.document.products[product.id]?.price },
                set: { session.updateProductPrice(product.id, price: $0) }
            ), notes: Binding(
                get: { session.document.products[product.id]?.notes ?? "" },
                set: { session.updateProductNotes(product.id, notes: $0) }
            ), onRemoveSticker: {
                onDelete()
                session.deletePlacement(placement.id)
                statuses[placement.id] = nil
                if let group = session.inspectedGroup {
                    session.inspectedGroup = session.document.namedGroups?.first { $0.id == group.id }
                }
            }, onDeleteProduct: {
                onDelete()
                session.deleteProduct(product.id)
                if let group = session.inspectedGroup {
                    session.inspectedGroup = session.document.namedGroups?.first { $0.id == group.id }
                }
            }, onBringToFront: {
                session.bringToFront(placement.id)
            }, onPlaceAnother: {
                onDelete()
                session.placeSticker(of: product.id)
            }, onAvailability: {
                session.recordAvailability($0, productID: product.id)
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .onDisappear { session.history.endCoalescing() }
        }
    }

}

private struct CanvasGroupNameDrawer: View {
    let onUpdate: (String, CanvasGroupColour?) -> Void
    let onOpenItem: (StickerPlacement) -> Void
    let document: CanvasDocument
    let members: [StickerPlacement]
    let library: ImportedAssetLibrary
    let totals: (byCurrency: [String: Decimal], hasUnpriced: Bool)
    @State private var name: String
    @State private var backgroundColour: CanvasGroupColour?
    @Binding private var notes: String
    @FocusState private var focused: Bool

    init(group: CanvasNamedGroup, document: CanvasDocument, library: ImportedAssetLibrary, notes: Binding<String>, onOpenItem: @escaping (StickerPlacement) -> Void, onUpdate: @escaping (String, CanvasGroupColour?) -> Void) {
        self.onUpdate = onUpdate
        self.onOpenItem = onOpenItem
        self.document = document
        self.library = library
        _notes = notes
        members = group.members.compactMap { document.placements[$0] }
        totals = document.totals(for: group)
        _name = State(initialValue: group.name)
        _backgroundColour = State(initialValue: group.backgroundColour)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                    .accessibilityLabel("Group name")
                    .focused($focused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { focused = false }
                    .onChange(of: name) { _, value in
                        if value.count > 60 { name = String(value.prefix(60)) }
                        onUpdate(String(value.prefix(60)), backgroundColour)
                    }
                // Currencies are never added together; unpriced items make it a subtotal.
                LabeledContent(totals.hasUnpriced ? "Known-price subtotal" : "Cost of group",
                               value: totals.byCurrency.isEmpty ? "No prices"
                                   : totals.byCurrency.sorted { $0.key < $1.key }
                                       .map { $0.value.formatted(.currency(code: $0.key)) }.joined(separator: " + "))
                Section("Notes") {
                    TextField("Add notes…", text: $notes, axis: .vertical)
                        .lineLimit(4...12)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .accessibilityLabel("Group notes")
                }
                Section("Background colour") {
                    ColorPicker("Colour", selection: Binding(
                        get: {
                            let rgb = backgroundColour?.rgb ?? (1, 1, 1)
                            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
                        },
                        set: { colour in
                            focused = false
                            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                            guard UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                            backgroundColour = CanvasGroupColour(red: Double(red), green: Double(green), blue: Double(blue))
                            onUpdate(name, backgroundColour)
                        }
                    ), supportsOpacity: false)
                    Button("Remove background colour") {
                        backgroundColour = nil
                        onUpdate(name, nil)
                    }
                    .disabled(backgroundColour == nil)
                }
                Section("Items") {
                    ForEach(members) { placement in
                        if let product = document.products[placement.productID] {
                            Button {
                                focused = false
                                onOpenItem(placement)
                            } label: {
                                HStack(spacing: 12) {
                                    CanvasGroupItemThumbnail(asset: product.asset, library: library)
                                    Text(product.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(product.title)
                            .accessibilityHint("Opens product details")
                        }
                    }
                }
            }
            .navigationTitle("Edit group")
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)

        }

    }

}

struct CanvasGroupItemThumbnail: View {
    let asset: String
    let library: ImportedAssetLibrary
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
        .task(id: asset) {
            thumbnail = nil
            let asset = asset
            guard let data = await library.load(asset) else { return }
            let image = await Task.detached(priority: .userInitiated) {
                CanvasImageWorker.decode(data: data, tier: 192)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}

/// Resolve the device's corner geometry through SwiftUI, including at the trim seam.
private struct ImportViewportProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    private let lineWidth: CGFloat = 3

    var body: some View {
        Group {
            if reduceMotion {
                ConcentricRectangle()
                    .stroke(.tint.opacity(0.7), lineWidth: lineWidth)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSince(started)
                        .truncatingRemainder(dividingBy: 3.5) / 3.5
                    let end = phase + 0.18
                    ZStack {
                        ConcentricRectangle()
                            .trim(from: phase, to: min(end, 1))
                            .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        if end > 1 {
                            ConcentricRectangle()
                                .trim(from: 0, to: end - 1)
                                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .accentColor.opacity(0.6), radius: 5)
                }
            }
        }
        // Inset only the stroke's centerline; its outside edge remains flush.
        // ConcentricRectangle resolves the corresponding inset corner geometry.
        .padding(lineWidth / 2)
    }
}
