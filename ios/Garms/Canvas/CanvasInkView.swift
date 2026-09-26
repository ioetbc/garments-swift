import PencilKit
import UIKit

@MainActor private final class CanvasInkDelegate: NSObject, PKCanvasViewDelegate {
    weak var owner: CanvasInkView?

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        owner?.beginStroke()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        owner?.storeDrawing()
    }
}

/// PencilKit and system undo gestures use the same canvas timeline as the toolbar.
@MainActor private final class CanvasHistoryUndoManager: UndoManager {
    weak var session: CanvasSession?
    override var canUndo: Bool { session?.history.canUndo == true }
    override var canRedo: Bool { session?.history.canRedo == true }
    override func undo() { session?.undo() }
    override func redo() { session?.redo() }
}

/// Keep ink in world coordinates so it follows the canvas when navigating.
@MainActor final class CanvasInkView: PKCanvasView {
    private let session: CanvasSession
    private let picker = PKToolPicker()
    private let drawingUndoManager = CanvasHistoryUndoManager()
    private let drawingDelegate = CanvasInkDelegate()
    private var worldToView: CGAffineTransform?
    private var applyingCamera = false
    private var displayedInk: PKDrawing?
    private var displayedDrawing: PKDrawing?
    private var strokeKey: String?
    override var undoManager: UndoManager? { drawingUndoManager }

    init(session: CanvasSession) {
        self.session = session
        super.init(frame: .zero)
        drawingUndoManager.session = session
        drawingUndoManager.disableUndoRegistration()
        backgroundColor = .clear
        isOpaque = false
        isScrollEnabled = false
        contentInsetAdjustmentBehavior = .never
        drawingPolicy = .anyInput
        isUserInteractionEnabled = false
        // PKCanvasView handles scroll-view delegate callbacks internally. Making
        // the canvas its own external delegate can forward those back into itself.
        drawingDelegate.owner = self
        delegate = drawingDelegate
        picker.addObserver(self)
        tool = PKInkingTool(.pen, color: .black, width: 3)
        accessibilityLabel = "Drawing canvas"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDrawingEnabled(_ enabled: Bool) {
        isUserInteractionEnabled = enabled
        if enabled {
            updateCamera()
            if window != nil {
                picker.setVisible(true, forFirstResponder: self)
                becomeFirstResponder()
            }
        } else {
            picker.setVisible(false, forFirstResponder: self)
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && isUserInteractionEnabled { setDrawingEnabled(true) }
    }

    func updateCamera() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let camera = session.camera
        let transform = CGAffineTransform(a: camera.zoom, b: 0, c: 0, d: camera.zoom,
                                         tx: bounds.width / 2 - camera.center.x * camera.zoom,
                                         ty: bounds.height / 2 - camera.center.y * camera.zoom)
        let data = session.inkDrawing
        guard worldToView != transform || displayedInk != data else { return }
        applyingCamera = true
        worldToView = transform
        drawing = session.inkDrawing.transformed(using: transform)
        displayedInk = data
        displayedDrawing = drawing
        strokeKey = nil
        // Screen-space undo snapshots from the previous camera would move ink.
        drawingUndoManager.removeAllActions()
        applyingCamera = false
    }

    fileprivate func beginStroke() { strokeKey = UUID().uuidString }

    fileprivate func storeDrawing() {
        guard !applyingCamera, let transform = worldToView else { return }
        let data = drawing
        guard data != displayedDrawing else { return }
        session.updateInk(drawing.transformed(using: transform.inverted()), key: strokeKey)
        displayedDrawing = data
        displayedInk = session.inkDrawing
    }
}
