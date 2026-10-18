import SwiftUI

/// One Product Awaiting match: the listing its search found, a link field, and the way out.
struct AwaitingMatchRow: View {
    let product: Product
    let library: ImportedAssetLibrary
    let imports: ImportCoordinator
    @State private var link = ""

    var body: some View {
        let match = product.match ?? .init(status: .searching)
        let loading = imports.isLoadingMatch(product.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CanvasGroupItemThumbnail(asset: product.asset, library: library)
                VStack(alignment: .leading) {
                    Text(product.title).lineLimit(1)
                    Group {
                        if loading { Text("Importing the listing…") }
                        else {
                            switch match.status {
                            case .searching: Text("Searching for the listing…")
                            case .found: Text("Found this listing")
                            case .notFound: Text("No matches found")
                            case .failed: Text("Couldn't search")
                            case .loadFailed: Text("Couldn't load that page")
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !loading, let candidate = match.candidate {
                Button { imports.confirm(product.id, url: candidate.url) } label: {
                    VStack(alignment: .leading) {
                        Text(candidate.domain).font(.caption).foregroundStyle(.secondary)
                        Text(candidate.title ?? candidate.url).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Imports this listing")
            }
            HStack {
                TextField("Paste a link", text: $link)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { imports.confirm(product.id, url: link) }
                Button("Use link") { imports.confirm(product.id, url: link) }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .buttonStyle(.bordered)
            HStack {
                if match.status == .failed { Button("Retry search") { imports.retrySearch(product.id) } }
                Button(match.candidate == nil ? "Skip" : "Not this one") { imports.skipMatch(product.id) }
            }
            .buttonStyle(.bordered)
        }
        .disabled(loading)
    }
}
