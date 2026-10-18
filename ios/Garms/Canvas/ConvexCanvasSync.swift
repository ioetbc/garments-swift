import Foundation
import Combine
import ConvexMobile

extension CanvasChangeSet: ConvexEncodable {}

/// CanvasSync over Convex: one subscription to the whole Canvas and one mutation per committed edit.
/// The last snapshot is kept on disk so the Canvas can be viewed offline.
@MainActor final class ConvexCanvasSync: CanvasSync {
    private let client: ConvexClientWithAuth<String>
    private var canvas: String?
    private var connected = false
    private var authenticated = false
    private var subscriptions: Set<AnyCancellable> = []
    private var cache: URL { LocalUser.directory.appending(path: "canvas.json") }

    init(client: ConvexClientWithAuth<String>) { self.client = client }

    func connect(snapshot: @escaping @MainActor (CanvasRemote) -> Void, online: @escaping @MainActor (Bool) -> Void) {
        if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(CanvasRemote.self, from: data) {
            snapshot(cached)
        }
        // Editable only once connected and the Canvas is known, so no edit is sent before it can be saved.
        online(false)
        client.authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .authenticated = state { self?.authenticated = true } else { self?.authenticated = false }
            }
            .store(in: &subscriptions)
        client.watchWebSocketState()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                connected = state == .connected
                online(connected && canvas != nil)
            }
            .store(in: &subscriptions)
        Task { [weak self, client] in
            // The first request creates the User and their Canvas; retry until reachable and authenticated.
            // Held weakly between attempts, so teardown ends the loop.
            var canvas: String?
            while canvas == nil, self != nil {
                // Calling before Clerk's token reaches Convex is rejected as Not signed in, so wait for it.
                if self?.authenticated == true, let started: String = try? await client.mutation("canvases:start") {
                    canvas = started
                } else {
                    try? await Task.sleep(for: .seconds(3))
                    // Launching offline leaves Convex unauthenticated; retry from Clerk's cached session.
                    if self?.authenticated == false { _ = await client.loginFromCache() }
                }
            }
            guard let self, let canvas else { return }
            self.canvas = canvas
            online(self.connected)
            self.client.subscribe(to: "canvases:load", with: ["canvas": canvas], yielding: CanvasRemote.self)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] remote in
                    snapshot(remote)
                    guard let self, let data = try? JSONEncoder().encode(remote) else { return }
                    try? FileManager.default.createDirectory(at: LocalUser.directory, withIntermediateDirectories: true)
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

    func findCandidates(_ jpeg: Data) async throws -> [Product.Match.Candidate] {
        var args: [String: ConvexEncodable?] = ["image": jpeg.base64EncodedString()]
        if let region = Locale.current.region?.identifier, region.count == 2 { args["region"] = region }
        return try await client.action("matches:search", with: args)
    }
}
