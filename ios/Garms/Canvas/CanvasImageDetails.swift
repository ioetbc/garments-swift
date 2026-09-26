import SwiftUI

struct CanvasImageDetails: View {
    let product: SampleProduct
    let library: ImportedAssetLibrary
    @Binding var status: String
    let onDelete: () -> Void
    let availability: GarmsAPI.ProductClassification?
    let onAvailability: (GarmsAPI.ProductClassification) -> Void
    @State private var showingDeleteConfirmation = false
    @State private var productImage: CGImage?
    @State private var scrapingPage = false
    @State private var scrapedPage: GarmsAPI.ScrapedPage?
    @State private var scrapeError: String?
    @State private var showingMarkdown = false
    @State private var checkingConnection = false
    @State private var connectionMessage: String?
    @State private var connectionFailed = false
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
                        ForEach(0..<(product.isImported == true ? 1 : 5), id: \.self) { index in
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
                            .accessibilityLabel("\(product.title), image \(index + 1) of \(product.isImported == true ? 1 : 5)")
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
                    LabeledContent("Price", value: product.price?.formatted(.currency(code: "GBP")) ?? "Not available")
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
                    Picker("Status", selection: $status) {
                        ForEach(["Owned", "Wishlist", "Ordered", "Returning", "Returned", "Sold"], id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    if product.isImported != true {
                        LabeledContent("Colour", value: colour)
                        LabeledContent("Brand", value: brand)
                    }
                }
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
                    if let classification = scrapedPage?.classification ?? availability {
                        LabeledContent("Availability", value: classification.label)
                            .accessibilityIdentifier("productAvailability")
                        if let message = classification.error {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if scrapedPage != nil {
                        LabeledContent("Availability", value: "Unknown")
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
        .task(id: product.asset) {
            productImage = nil
            let asset = product.asset
            let data = library.data(for: asset)
            let image = await Task.detached(priority: .userInitiated) {
                return CanvasImageWorker.resolve(asset, data: data, tier: 1024)
            }.value
            guard !Task.isCancelled else { return }
            productImage = image
        }
    }
}
