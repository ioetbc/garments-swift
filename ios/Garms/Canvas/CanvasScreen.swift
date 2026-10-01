import SwiftUI
import UIKit
import PhotosUI

struct CanvasScreen: View {
    @State private var session = CanvasSession()
    @State private var statuses: [String: String] = [:]
    @State private var showingImports = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var sendingLogs: Set<UUID> = []
    @State private var logDelivery: [UUID: String] = [:]
    @State private var searchExpanded = false
    @State private var showingPeople = false
    @State private var peopleQuery = ""
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
                    if session.isDrawing {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done", systemImage: "checkmark") { session.isDrawing = false }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { session.isDrawing = false; showingImports = true } label: {
                            Label("Imports (\(session.imports.items.filter { $0.state != "Ready" }.count))", systemImage: "square.and.arrow.down")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
                            .disabled(!session.history.canUndo)
                            .keyboardShortcut("z", modifiers: .command)
                        Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }
                            .disabled(!session.history.canRedo)
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                        Button {
                            searchExpanded = false
                            session.resolveInteraction?()
                            session.isDrawing.toggle()
                        } label: {
                            Label(session.isDrawing ? "Done drawing" : "Draw", systemImage: session.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        }
                        .tint(session.isDrawing ? .accentColor : .primary)
                        .accessibilityHint("Shows or hides pens, eraser and colours")
                    }
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            searchExpanded = false
                            session.searchQuery = ""
                            session.isDrawing = false
                            session.resolveInteraction?()
                            peopleQuery = ""
                            showingPeople = true
                        } label: {
                            Label("Find people", systemImage: "figure.2.arms.open")
                        }
                        .accessibilityHint("Opens user search and other people’s canvases")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
                .onChange(of: searchExpanded) { _, expanded in
                    if expanded {
                        session.isDrawing = false
                        session.resolveInteraction?()
                    } else {
                        session.searchQuery = ""
                    }
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
            .sheet(isPresented: $showingPeople) {
                peopleDrawer
                    .presentationDetents([.medium, .large])
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
                                            try await GarmsAPI.sendImportLog(report)
                                            logDelivery[id] = "Sent — check the terminal running the API server."
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
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Canvas needs attention",isPresented:Binding(get:{ session.error != nil },set:{ if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .onChange(of: selectedPhotos) { _, photos in
                guard !photos.isEmpty else { return }
                session.isDrawing = false
                session.resolveInteraction?()
                for (index, photo) in photos.enumerated() {
                    session.imports.importPhoto(title: "Imported photo \(index + 1)") {
                        guard let data = try await photo.loadTransferable(type: Data.self) else {
                            throw ImportedImageDownload.ImageError.detail("This photo could not be loaded. Retry or select another image.")
                        }
                        return data
                    }
                }
                selectedPhotos = []
            }
            .onChange(of:phase) { _,v in
                if v != .active { session.resolveInteraction?() }
                session.imports.setActive(v == .active)
            }
            .task { session.imports.setActive(phase == .active) }
            .task { await session.loadAvailability() }
    }

    private var peopleDrawer: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search users", text: $peopleQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Search users")
                    if !peopleQuery.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            peopleQuery = ""
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 12)

                let users = CanvasFixtures.matchingUsers(peopleQuery)
                List {
                    if users.isEmpty {
                        Text("No users found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(users) { user in
                        Button {
                            session.previewCanvas(user)
                            showingPeople = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName).font(.subheadline.bold())
                                    Text(user.username).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.primary)
                            .contentShape(Rectangle())
                        }
                        .disabled(!session.hasInitialLayout)
                        .accessibilityLabel("View \(user.username)’s canvas")
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Find people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingPeople = false }
                }
            }
        }
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $selectedPhotos, selectionBehavior: .ordered, matching: .images) {
            Label("Import photos", systemImage: "photo.badge.plus")
        }
        .accessibilityHint("Choose photos to add as separate items and remove their backgrounds")
    }

    @ViewBuilder
    private func productDetails(for placement: StickerPlacement, onDelete: @escaping () -> Void) -> some View {
        let _ = session.revision
        if let product = session.document.products[placement.productID] {
            CanvasImageDetails(product: product, library: session.importedAssets, status: Binding(
                get: { statuses[placement.id] ?? "Wishlist" },
                set: { statuses[placement.id] = $0 }
            ), notes: Binding(
                get: { session.document.products[product.id]?.notes ?? "" },
                set: { session.updateProductNotes(product.id, notes: $0) }
            ), onDelete: {
                onDelete()
                session.deletePlacement(placement.id)
                statuses[placement.id] = nil
                if let group = session.inspectedGroup {
                    session.inspectedGroup = session.document.namedGroups?.first { $0.id == group.id }
                }
            }, availability: session.classification(for: product), onAvailability: {
                session.updateAvailability($0, productID: product.id)
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
    let sum: Decimal
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
        sum = document.sum(for: group)
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
                LabeledContent(members.contains { document.products[$0.productID]?.price == nil } ? "Known-price subtotal" : "Cost of group", value: members.contains { document.products[$0.productID]?.price != nil } ? sum.formatted(.currency(code: "GBP")) : "Not available")
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

private struct CanvasGroupItemThumbnail: View {
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
            let data = library.data(for: asset)
            let image = await Task.detached(priority: .userInitiated) {
                return CanvasImageWorker.resolve(asset, data: data, tier: 192)
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
