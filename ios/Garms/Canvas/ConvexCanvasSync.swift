import Foundation
import Combine
import ConvexMobile

extension CanvasChangeSet: ConvexEncodable {}

/// CanvasSync over Convex: one subscription to the whole Canvas and one mutation per committed edit.
/// The last snapshot is kept on disk so the Canvas can be viewed offline.
@MainActor final class ConvexCanvasSync: CanvasSync {
    private let client: ConvexClient
    private var canvas: String?
    private var connected = false
    private var subscriptions: Set<AnyCancellable> = []
    // ponytail: one cached Canvas per device; key it by User when sign-in lands.
    private let cache = URL.cachesDirectory.appending(path: "canvas.json")

    init(deploymentURL: String) { client = ConvexClient(deploymentUrl: deploymentURL) }

    /// The deployment from CONVEX_URL (scheme environment in Debug, Info.plist otherwise).
    static func configured() -> ConvexCanvasSync {
        #if DEBUG
        let address = ProcessInfo.processInfo.environment["CONVEX_URL"]
        #else
        let address: String? = nil
        #endif
        let url = address ?? Bundle.main.object(forInfoDictionaryKey: "CONVEX_URL") as? String ?? ""
        return ConvexCanvasSync(deploymentURL: url)
    }

    func connect(snapshot: @escaping @MainActor (CanvasRemote) -> Void, online: @escaping @MainActor (Bool) -> Void) {
        if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(CanvasRemote.self, from: data) {
            snapshot(cached)
        }
        // Editable only once connected and the Canvas is known, so no edit is sent before it can be saved.
        online(false)
        client.watchWebSocketState()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                connected = state == .connected
                online(connected && canvas != nil)
            }
            .store(in: &subscriptions)
        Task { [weak self] in
            // The first request creates the User and their Canvas; retry until reachable.
            while let self, self.canvas == nil {
                do { self.canvas = try await self.client.mutation("canvases:start") }
                catch { try? await Task.sleep(for: .seconds(3)) }
            }
            guard let self, let canvas = self.canvas else { return }
            online(self.connected)
            self.client.subscribe(to: "canvases:load", with: ["canvas": canvas], yielding: CanvasRemote.self)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] remote in
                    snapshot(remote)
                    guard let self, let data = try? JSONEncoder().encode(remote) else { return }
                    try? data.write(to: self.cache, options: .atomic)
                })
                .store(in: &self.subscriptions)
        }
    }

    private func call(_ name: String, _ args: [String: ConvexEncodable?], completion: @escaping @MainActor (Error?) -> Void) {
        Task {
            do { try await client.mutation(name, with: args); completion(nil) }
            catch { completion(error) }
        }
    }

    func apply(_ changes: CanvasChangeSet, completion: @escaping @MainActor (Error?) -> Void) {
        guard let canvas else { return completion(URLError(.notConnectedToInternet)) }
        call("canvases:apply", ["canvas": canvas, "changes": changes], completion: completion)
    }

    func saveViewport(_ viewport: CanvasRemote.Viewport) {
        guard let canvas else { return }
        call("canvases:saveViewport", ["canvas": canvas, "viewport": ["x": viewport.x, "y": viewport.y, "zoom": viewport.zoom]]) { _ in }
    }

    func deleteProduct(_ id: String, completion: @escaping @MainActor (Error?) -> Void) {
        call("products:remove", ["product": id], completion: completion)
    }

    func upload(_ data: Data, key: String, completion: @escaping @MainActor (Error?) -> Void) {
        Task {
            do {
                let address: String = try await client.mutation("files:generateUploadUrl")
                guard let url = URL(string: address) else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("image/png", forHTTPHeaderField: "Content-Type")
                let (body, response) = try await URLSession.shared.upload(for: request, from: data)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                struct Uploaded: Decodable { let storageId: String }
                let storageId = try JSONDecoder().decode(Uploaded.self, from: body).storageId
                try await client.mutation("files:attach", with: ["key": key, "storageId": storageId])
                completion(nil)
            } catch { completion(error) }
        }
    }
}
