//
//  garment_swiftApp.swift
//  garment-swift
//
//  Created by William Cole on 24/09/2026.
//

import SwiftUI
import ClerkKit
import ClerkConvex
import ConvexMobile

@main
struct garment_swiftApp: App {
    private let convex: ConvexClientWithAuth<String>
    @State private var user: LocalUser

    init() {
        // Debug pairs Clerk development with Convex dev; Release pairs Clerk production with Convex prod.
        Clerk.configure(publishableKey: Bundle.main.object(forInfoDictionaryKey: "CLERK_PUBLISHABLE_KEY") as? String ?? "")
        #if DEBUG
        let address = ProcessInfo.processInfo.environment["CONVEX_URL"]
        #else
        let address: String? = nil
        #endif
        // Keeps the Convex token in sync with the Clerk session.
        let convex = ConvexClientWithAuth(
            deploymentUrl: address ?? Bundle.main.object(forInfoDictionaryKey: "CONVEX_URL") as? String ?? "",
            authProvider: ClerkConvexAuthProvider())
        self.convex = convex
        _user = State(initialValue: LocalUser(server: ConvexGarmsServer(client: convex)) { ConvexCanvasSync(client: convex) })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(user: user, convex: convex)
                .environment(Clerk.shared)
        }
    }
}
