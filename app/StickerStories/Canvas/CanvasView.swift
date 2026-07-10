import SpriteKit
import StickerStoriesKit
import SwiftUI

/// SwiftUI host for the SpriteKit canvas. Creates the scene once per pack and
/// reports canvas snapshots upward.
struct CanvasView: View {
    let onCanvasChange: (CanvasState) -> Void

    @State private var scene: CanvasScene

    init(pack: LoadedPack, onCanvasChange: @escaping (CanvasState) -> Void) {
        self.onCanvasChange = onCanvasChange
        _scene = State(initialValue: CanvasScene(pack: pack))
    }

    var body: some View {
        SpriteView(scene: scene, options: [.ignoresSiblingOrder])
            .ignoresSafeArea()
            .onAppear {
                scene.onCanvasChange = onCanvasChange
                onCanvasChange(scene.snapshot())
            }
    }
}
