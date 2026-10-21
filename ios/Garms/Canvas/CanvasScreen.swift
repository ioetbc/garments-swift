import SwiftUI
import UIKit
import PhotosUI
import Photos

struct CanvasScreen: View {
    let session: CanvasSession
    let onSettings: () -> Void
    @State private var showingImports = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
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
                .searchToolbarBehavior(.minimize)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "person.crop.circle") { onSettings() }
                    }
                    if session.imports.progress != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            ProgressView().accessibilityLabel("Importing")
                        }
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
                    group: session.document.namedGroups.first { $0.id == group.id } ?? group,
                    document: session.document,
                    library: session.importedAssets,
                    notes: Binding(
                        get: { session.document.namedGroups.first { $0.id == group.id }?.notes ?? "" },
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
            .sheet(isPresented: $showingImports) {
                NavigationStack {
                    List {
                        Section {
                            photoPicker
                        }
                        if session.imports.items.isEmpty { Text("Choose photos or share a link to import items.") }
                        ForEach(session.imports.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.displayName).lineLimit(2)
                                Text(item.status).font(.caption)
                                HStack {
                                    if case .failed = item.phase { Button("Retry") { session.imports.retry(item.id) }.buttonStyle(.bordered) }
                                    if item.canRetryBackground { Button("Retry background removal") { session.imports.retry(item.id) }.buttonStyle(.bordered) }
                                    Button("Dismiss", role: .destructive) { session.imports.dismiss(item.id) }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .navigationTitle("Imports")
                    .toolbar { Button("Done") { showingImports = false } }
                }
                .presentationDetents([.medium, .large])
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
                        session.imports.importPhoto(title: "Imported photo \(index + 1)") {
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
                // Links shared while Garms was in the background wait in the inbox.
                if v == .active { session.imports.checkInbox() }
            }
            .task { session.imports.checkInbox() }
    }

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
            CanvasImageDetails(product: product, library: session.importedAssets, title: Binding(
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
            ), onDeleteProduct: {
                onDelete()
                session.deleteProduct(product.id)
                if let group = session.inspectedGroup {
                    session.inspectedGroup = session.document.namedGroups.first { $0.id == group.id }
                }
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
                                    CanvasGroupItemThumbnail(asset: product.cutout, library: library)
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
