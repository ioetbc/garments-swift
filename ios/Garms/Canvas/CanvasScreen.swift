import SwiftUI
import UIKit

struct CanvasScreen: View {
    @State private var session = CanvasSession()
    @State private var statuses: [String: String] = [:]
    @State private var searchExpanded = false
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
                if let product = session.document.products[placement.productID] {
                    CanvasImageDetails(product: product, status: Binding(
                        get: { statuses[placement.id] ?? "Wishlist" },
                        set: { statuses[placement.id] = $0 }
                    ), onDelete: {
                        session.inspectedPlacement = nil
                        session.deletePlacement(placement.id)
                        statuses[placement.id] = nil
                    })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: Binding(
                get: { session.inspectedGroup },
                set: { session.inspectedGroup = $0 }
            )) { group in
                CanvasGroupNameDrawer(group: group) { name, colour in
                    session.updateGroup(group.id, name: name, backgroundColour: colour)
                }
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
            }
            .alert("Canvas needs attention",isPresented:Binding(get:{ session.error != nil },set:{ if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .onChange(of:phase) { _,v in
                if v != .active { session.resolveInteraction?() }
            }
    }

}

private struct CanvasGroupNameDrawer: View {
    let onUpdate: (String, CanvasGroupColour?) -> Void
    @State private var name: String
    @State private var backgroundColour: CanvasGroupColour?
    @FocusState private var focused: Bool

    init(group: CanvasNamedGroup, onUpdate: @escaping (String, CanvasGroupColour?) -> Void) {
        self.onUpdate = onUpdate
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
            }
            .navigationTitle("Edit group")
            .navigationBarTitleDisplayMode(.inline)

        }

    }

}
