import PencilKit
import UIKit

@main struct DrawingChecks {
    @MainActor static func main() {
        let session = CanvasSession()
        let canvas = CanvasInkView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        session.camera = CanvasCamera(center: WorldPoint(x: 195, y: 422), zoom: 1)
        canvas.updateCamera()

        // Never forward UIKit's internal scroll callbacks to the canvas itself.
        precondition(canvas.delegate != nil && canvas.delegate !== canvas)
        precondition(!canvas.delegate!.responds(to: #selector(UIScrollViewDelegate.scrollViewDidScroll(_:))))
        canvas.setDrawingEnabled(true)
        precondition(canvas.isUserInteractionEnabled && canvas.drawingPolicy == .anyInput)

        let points = [CGPoint(x: 40, y: 80), CGPoint(x: 90, y: 120)]
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        precondition(session.inkDrawing.strokes.count == 1)
        let worldBounds = session.inkDrawing.bounds

        canvas.setDrawingEnabled(false)
        precondition(!canvas.isUserInteractionEnabled)
        session.camera = CanvasCamera(center: WorldPoint(x: 100, y: 200), zoom: 2)
        canvas.updateCamera()
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        let restored = session.inkDrawing.bounds
        precondition(abs(restored.minX - worldBounds.minX) < 0.01)
        precondition(abs(restored.minY - worldBounds.minY) < 0.01)
        precondition(abs(restored.width - worldBounds.width) < 0.01)

        canvas.setDrawingEnabled(true)
        canvas.drawing = PKDrawing()
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        precondition(session.inkDrawing.strokes.isEmpty)
        canvas.setDrawingEnabled(false)
        precondition(!canvas.isUserInteractionEnabled)
        print("Drawing checks passed: delegate routing, finger input, ink updates, camera transforms, erasing and mode exit.")
    }
}
