import SpriteKit
import StickerStoriesKit
import SwiftUI

/// SwiftUI host for the SpriteKit canvas. The scene is owned by the caller
/// (so it can also drive undo/redo/clear); this view just presents it and
/// reports canvas snapshots and history state upward.
struct CanvasView: View {
    let scene: CanvasScene
    let onCanvasChange: (CanvasState) -> Void
    let onHistoryChange: (_ canUndo: Bool, _ canRedo: Bool, _ canClear: Bool) -> Void

    var body: some View {
        SpriteView(scene: scene, options: [.ignoresSiblingOrder])
            .ignoresSafeArea()
            .onAppear {
                scene.onCanvasChange = onCanvasChange
                scene.onHistoryChange = onHistoryChange
                onCanvasChange(scene.snapshot())
                onHistoryChange(scene.canUndo, scene.canRedo, scene.canClear)
            }
    }
}
