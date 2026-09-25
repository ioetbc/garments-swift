import SwiftUI

struct CanvasImageDetails: View {
    let product: SampleProduct
    @Binding var status: String
    let onDelete: () -> Void
    @State private var showingDeleteConfirmation = false
    @State private var productImage: CGImage?
    @Environment(\.dismiss) private var dismiss

    // Placeholder details derived from the bundled sample names.
    private var colour: String {
        let colours = ["Blue", "Beige", "Taupe", "White", "Black", "Green", "Red", "Burgundy", "Pink", "Khaki", "Gray"]
        return colours.first { product.title.components(separatedBy: " ").contains($0) } ?? "Black"
    }

    private var brand: String {
        product.title.components(separatedBy: " \(colour) ").first ?? "Lemaire"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TabView {
                        ForEach(0..<5) { index in
                            Group {
                                if let productImage {
                                    Image(decorative: productImage, scale: 1)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 48)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(product.title), image \(index + 1) of 5")
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .frame(height: 300)
                    .id(product.id)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Name", value: product.title)
                    LabeledContent("Price", value: "£250.00")
                    LabeledContent("URL") {
                        if let url = URL(string: "https://example.com/products/\(product.id)") {
                            Link(destination: url) {
                                Text(url.absoluteString)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .accessibilityHint("Opens in your browser")
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(["Owned", "Wishlist", "Ordered", "Returning", "Returned", "Sold"], id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("Colour", value: colour)
                    LabeledContent("Brand", value: brand)
                }
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete product", systemImage: "trash")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .listRowBackground(Color.red.opacity(0.10))
                }
            }
            .navigationTitle("Product details")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Delete product?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) { onDelete() }
            } message: {
                Text("Are you sure you want to delete this product from the canvas?")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: product.asset) {
            productImage = nil
            let asset = product.asset
            let image = await Task.detached(priority: .userInitiated) {
                guard let url = CanvasImageWorker.sourceURL(asset) else { return nil as CGImage? }
                return CanvasImageWorker.decode(url: url, tier: 1024)
            }.value
            guard !Task.isCancelled else { return }
            productImage = image
        }
    }
}
