import SwiftUI
import ClerkKit
import ConvexMobile

/// Who is signed in, and the account actions. Teardown follows the session ending (see ContentView).
struct SettingsSheet: View {
    let convex: ConvexClientWithAuth<String>
    @Environment(Clerk.self) private var clerk
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                // Apple may give no name, and a relay address or no email.
                Section("Signed in as") {
                    let name = [clerk.user?.firstName, clerk.user?.lastName].compactMap { $0 }.joined(separator: " ")
                    if !name.isEmpty { LabeledContent("Name", value: name) }
                    if let email = clerk.user?.primaryEmailAddress?.emailAddress { LabeledContent("Email", value: email) }
                    if name.isEmpty && clerk.user?.primaryEmailAddress == nil { Text("Apple ID") }
                }
                Section {
                    Button("Sign out") { run { try await Clerk.shared.auth.signOut() } }
                }
                Section {
                    Button("Delete account", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Deletes your canvas, products and images from Garms. This can't be undone.")
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .disabled(working)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    run {
                        try await convex.action("users:remove")
                        // The Clerk user is gone, so this only clears the session on this device.
                        try? await Clerk.shared.auth.signOut()
                    }
                }
            } message: {
                Text("Everything you've saved in Garms will be permanently deleted.")
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { try await action() } catch { failure = error.localizedDescription }
        }
    }
}
