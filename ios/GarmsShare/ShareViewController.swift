import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let add = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private var link: String?
    private var queued = false
    private var loading: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.text = "Reading shared link…"
        add.setTitle("Add", for: .normal)
        add.isEnabled = false
        add.addTarget(self, action: #selector(save), for: .touchUpInside)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, add, cancel])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                var urls: [String] = [], texts: [String] = []
                for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
                    if let text = item.attributedContentText?.string { texts.append(text) }
                    for provider in item.attachments ?? [] {
                        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                        guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
                        let value = try await load(provider, type: type)
                        try Task.checkCancellation()
                        if type == UTType.url.identifier { urls.append(value) } else { texts.append(value) }
                    }
                }
                link = try SharedLink.extract(urls: urls, texts: texts)
                label.text = link
                add.isEnabled = true
            } catch { if !Task.isCancelled { label.text = error.localizedDescription } }
        }
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = value as? URL { continuation.resume(returning: url.absoluteString) }
                else if let text = value as? String { continuation.resume(returning: text) }
                else { continuation.resume(throwing: SharedLink.LinkError.invalid) }
            }
        }
    }
    @objc private func save() {
        guard let link, !queued else { return }
        add.isEnabled = false
        cancel.isEnabled = false
        Task {
            defer { cancel.isEnabled = true }
            do {
                try await Task.detached { try SharedImportInbox().enqueue(SharedImport(url: link)) }.value
                queued = true
                label.text = "Queued — open Garms to finish importing"
                add.isHidden = true
                cancel.setTitle("Done", for: .normal)
            } catch { label.text = error.localizedDescription; add.isEnabled = true }
        }
    }
    @objc private func close() {
        loading?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
