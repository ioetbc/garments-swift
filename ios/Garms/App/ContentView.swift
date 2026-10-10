import SwiftUI
import ClerkKit
import ConvexMobile

/// Switches on Clerk's auth state: a plain launch screen while loading, the gate with no
/// session, otherwise the Canvas. A cached session opens the Canvas even offline.
struct ContentView: View {
    let user: LocalUser
    let convex: ConvexClientWithAuth<String>
    @Environment(Clerk.self) private var clerk
    @State private var showingSettings = false

    var body: some View {
        Group {
            if let canvas = user.canvas {
                CanvasScreen(session: canvas) { showingSettings = true }
                    .sheet(isPresented: $showingSettings) { SettingsSheet(convex: convex) }
            } else if clerk.isLoaded && clerk.session == nil {
                GateScreen()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        // Only an ended session reaches nil; a refresh that fails offline keeps the cached one.
        .onChange(of: clerk.isLoaded ? Optional(clerk.user?.id) : nil, initial: true) { _, id in
            guard let id else { return }
            if id == nil { showingSettings = false }
            user.follow(id)
        }
    }
}
