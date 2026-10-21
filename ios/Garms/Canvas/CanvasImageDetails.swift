import SwiftUI

struct CanvasImageDetails: View {
    let product: Product
    let library: ImportedAssetLibrary
    @Binding var title: String
    @Binding var category: String
    @Binding var price: Price?
    @Binding var notes: String
    let onDeleteProduct: () -> Void
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Form {
                    Section {
                        TabView {
                            ForEach(Array(product.detailAssets.enumerated()), id: \.element) { index, asset in
                                let label = asset == product.cutout ? (product.original == nil || product.original == asset ? nil : "Cutout")
                                    : asset == product.original ? "Original" : "Photo"
                                CanvasDetailsImagePage(asset: asset, library: library, label: label,
                                    accessibility: "\(product.title), \(label ?? "image") \(index + 1) of \(product.detailAssets.count)")
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
                        .frame(height: max(360, geometry.size.height * 0.68))
                        .id(product.id)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        TextField("Name", text: $title)
                            .accessibilityLabel("Product name")
                        TextField("Category, e.g. Coat", text: $category)
                            .textInputAutocapitalization(.words)
                            .accessibilityLabel("Category")
                        CanvasPriceField(price: $price)
                        if !product.sourceUrl.isEmpty {
                            LabeledContent("URL") {
                                if let url = URL(string: product.sourceUrl) {
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
                        }
                    }
                    Section("Notes") {
                        TextField("Add notes…", text: $notes, axis: .vertical)
                            .lineLimit(4...12)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                            .accessibilityLabel("Product notes")
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
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Product details")
                .navigationBarTitleDisplayMode(.inline)
                .alert("Delete product?", isPresented: $showingDeleteConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) { onDeleteProduct() }
                } message: {
                    Text("This deletes the product, every sticker of it and its photos. It can't be undone.")
                }
            }
        }
    }
}

private struct CanvasDetailsImagePage: View {
    let asset: String
    let library: ImportedAssetLibrary
    let label: String?
    let accessibility: String
    @State private var productImage: CGImage?

    var body: some View {
        VStack {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            if let productImage {
                Image(decorative: productImage, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .task(id: asset) {
            productImage = nil
            guard let data = await library.load(asset) else { return }
            let image = await Task.detached(priority: .userInitiated) {
                CanvasImageWorker.decode(data: data, tier: 1024)
            }.value
            guard !Task.isCancelled else { return }
            productImage = image
        }
    }
}

/// An optional Price: an amount in a chosen currency, or none.
private struct CanvasPriceField: View {
    @Binding var price: Price?
    @State private var amount: Decimal?
    @State private var currency: String
    private static let currencies = ["GBP", "EUR", "USD", "JPY", "AUD", "CAD", "CHF", "SEK", "DKK"]

    init(price: Binding<Price?>) {
        _price = price
        _amount = State(initialValue: price.wrappedValue?.major)
        _currency = State(initialValue: price.wrappedValue?.currency ?? Locale.current.currency?.identifier ?? "GBP")
    }

    var body: some View {
        HStack {
            TextField("No price", value: $amount, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .accessibilityLabel("Price")
            Picker("Currency", selection: $currency) {
                ForEach(Set(Self.currencies + [currency]).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .onChange(of: amount) { save() }
        .onChange(of: currency) { save() }
    }

    private func save() {
        price = amount.flatMap { $0 >= 0 ? Price(major: $0, currency: currency) : nil }
    }
}
