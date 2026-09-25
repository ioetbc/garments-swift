import SwiftUI

struct CanvasHost: UIViewRepresentable {
    let session: CanvasSession
    func makeUIView(context:Context) -> GarmsCanvasView { GarmsCanvasView(session:session) }
    func updateUIView(_ view:GarmsCanvasView,context:Context) { /* Commands travel through the stable session. */ }
    static func dismantleUIView(_ view:GarmsCanvasView,coordinator:()) { view.shutdown() }
}
