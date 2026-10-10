import SwiftUI

struct CanvasImageDetails: View {
    let product: Product
    let library: ImportedAssetLibrary
    @Binding var status: String
    @Binding var title: String
    @Binding var category: String
    @Binding var price: Price?
    @Binding var notes: String
    let onRemoveSticker: () -> Void
    let onDeleteProduct: () -> Void
    let onBringToFront: () -> Void
    let onPlaceAnother: () -> Void
    let onAvailability: (GarmsAPI.ProductClassification) -> Void
    @State private var showingDeleteConfirmation = false
    @State private var scrapingPage = false
    @State private var scrapedPage: GarmsAPI.ScrapedPage?
    @State private var scrapeError: String?
    @State private var showingMarkdown = false
    @State private var checkingConnection = false
    @State private var connectionMessage: String?
    @State private var connectionFailed = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Form {
                    Section {
                        TabView {
                            ForEach(Array(product.detailAssets.enumerated()), id: \.element) { index, asset in
                                let label = asset == product.asset ? (product.originalAsset == nil || product.originalAsset == asset ? nil : "Cutout")
                                    : asset == product.originalAsset ? "Original" : "Photo"
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
                        if !product.product_url.isEmpty {
                            LabeledContent("URL") {
                                if let url = URL(string: product.product_url) {
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
                        Picker("Status", selection: $status) {
                            ForEach(["Owned", "Wishlist", "Ordered", "Returning", "Returned", "Sold"], id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("Notes") {
                        TextField("Add notes…", text: $notes, axis: .vertical)
                            .lineLimit(4...12)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                            .accessibilityLabel("Product notes")
                    }
                    if !product.product_url.isEmpty {
                        Section("Listing availability") {
                            Button {
                                scrapingPage = true
                            } label: {
                                HStack {
                                    Label(scrapingPage ? "Checking availability…" : "Check availability", systemImage: "arrow.clockwise")
                                    Spacer()
                                    if scrapingPage { ProgressView() }
                                }
                            }
                            .disabled(scrapingPage || product.product_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let scrapeError {
                                Text(scrapeError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            if let availability = product.availability {
                                LabeledContent("Availability", value: availability.label)
                                    .accessibilityIdentifier("productAvailability")
                                Text("Checked \(Date(timeIntervalSince1970: availability.checkedAt / 1000).formatted(.relative(presentation: .named)))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let classification = scrapedPage?.classification {
                                if let message = classification.error {
                                    Text(message)
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                            }
                            if let scrapedPage {
                                Button("View Markdown") { showingMarkdown = true }
                                Text(scrapedPage.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let code = scrapedPage.statusCode, code >= 400 {
                                    Text("The source page returned HTTP \(code).")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    Section("Connection") {
                        Button {
                            checkingConnection = true
                        } label: {
                            HStack {
                                Label("Test connection", systemImage: "network")
                                Spacer()
                                if checkingConnection { ProgressView() }
                            }
                        }
                        .disabled(checkingConnection)
                        if let connectionMessage {
                            Label(connectionMessage, systemImage: connectionFailed ? "exclamationmark.circle" : "checkmark.circle")
                                .font(.footnote)
                                .foregroundStyle(connectionFailed ? Color.red : Color.secondary)
                                .accessibilityIdentifier("connectionResult")
                        }
                    }
                    Section {
                        Button("Place another sticker", systemImage: "plus.square.on.square", action: onPlaceAnother)
                        Button("Bring to front", systemImage: "square.3.layers.3d.top.filled", action: onBringToFront)
                        Button("Remove from canvas", systemImage: "rectangle.portrait.slash", action: onRemoveSticker)
                            .accessibilityHint("Keeps the product so you can find it in search")
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
        .sheet(isPresented: $showingMarkdown) {
            NavigationStack {
                ScrollView {
                    Text(verbatim: scrapedPage?.markdown ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Markdown")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingMarkdown = false }
                    }
                    if let scrapedPage {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: scrapedPage.markdown)
                        }
                    }
                }
            }
        }
        .task(id: scrapingPage) {
            guard scrapingPage else { return }
            scrapedPage = nil
            scrapeError = nil
            defer { scrapingPage = false }
            do {
                let page = try await GarmsAPI.scrapePage(url: product.product_url)
                try Task.checkCancellation()
                scrapedPage = page
                if let classification = page.classification { onAvailability(classification) }
            } catch {
                guard !Task.isCancelled else { return }
                scrapeError = error.localizedDescription
            }
        }
        .task(id: checkingConnection) {
            guard checkingConnection else { return }
            connectionMessage = nil
            connectionFailed = false
            defer { checkingConnection = false }
            do {
                let message = try await GarmsAPI.checkConnection()
                try Task.checkCancellation()
                connectionMessage = message
            } catch {
                guard !Task.isCancelled else { return }
                connectionFailed = true
                connectionMessage = error.localizedDescription
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
