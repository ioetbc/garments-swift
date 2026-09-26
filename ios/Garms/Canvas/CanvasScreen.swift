import SwiftUI
import UIKit

struct CanvasScreen: View {
    @State private var session = CanvasSession()
    @State private var statuses: [String: String] = [:]
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
                ), isPresented: $searchExpanded, prompt: "Group, brand, colour or name")
                .searchToolbarBehavior(.minimize)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar {
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
                groupPlacement = nil
            }) { group in
                CanvasGroupNameDrawer(
                    group: session.document.namedGroups?.first { $0.id == group.id } ?? group,
                    document: session.document,
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
            .alert("Canvas needs attention",isPresented:Binding(get:{ session.error != nil },set:{ if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .onChange(of:phase) { _,v in
                if v != .active { session.resolveInteraction?() }
            }
            .task { await session.loadAvailability() }
    }

    @ViewBuilder
    private func productDetails(for placement: StickerPlacement, onDelete: @escaping () -> Void) -> some View {
        if let product = session.document.products[placement.productID] {
            CanvasImageDetails(product: product, status: Binding(
                get: { statuses[placement.id] ?? "Wishlist" },
                set: { statuses[placement.id] = $0 }
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

}

private struct CanvasGroupNameDrawer: View {
    let onUpdate: (String, CanvasGroupColour?) -> Void
    let onOpenItem: (StickerPlacement) -> Void
    let document: CanvasDocument
    let members: [StickerPlacement]
    let sum: Decimal
    @State private var name: String
    @State private var backgroundColour: CanvasGroupColour?
    @FocusState private var focused: Bool

    init(group: CanvasNamedGroup, document: CanvasDocument, onOpenItem: @escaping (StickerPlacement) -> Void, onUpdate: @escaping (String, CanvasGroupColour?) -> Void) {
        self.onUpdate = onUpdate
        self.onOpenItem = onOpenItem
        self.document = document
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
                LabeledContent("Cost of group", value: sum.formatted(.currency(code: "GBP")))
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
                                    CanvasGroupItemThumbnail(asset: product.asset)
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
            .navigationBarTitleDisplayMode(.inline)

        }

    }

}

private struct CanvasGroupItemThumbnail: View {
    let asset: String
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
            let image = await Task.detached(priority: .userInitiated) {
                guard let url = CanvasImageWorker.sourceURL(asset) else { return nil as CGImage? }
                return CanvasImageWorker.decode(url: url, tier: 192)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
