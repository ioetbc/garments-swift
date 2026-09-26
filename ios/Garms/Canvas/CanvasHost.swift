import SwiftUI

struct CanvasHost: UIViewRepresentable {
    let session: CanvasSession
    func makeUIView(context:Context) -> GarmsCanvasView { GarmsCanvasView(session:session) }
    func updateUIView(_ view:GarmsCanvasView,context:Context) { view.setDrawingEnabled(session.isDrawing) }
    static func dismantleUIView(_ view:GarmsCanvasView,coordinator:()) { view.shutdown() }
}
