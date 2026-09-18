#if DEBUG
import SpriteKit
import StickerStoriesKit
import SwiftUI

/// Developer-only: plays every effect on a real sticker at three intensities
/// so the library's numbers can be tuned against real art. Reached from
/// Settings in debug builds; never compiled into release.
struct EffectsGalleryView: View {
    let pack: LoadedPack
    @Environment(\.dismiss) private var dismiss
    @State private var scene: EffectsGalleryScene
    @State private var intensity = 0.6
    @State private var loop = false
    @State private var stickerID: String

    init(pack: LoadedPack) {
        self.pack = pack
        let first = pack.manifest.stickers.first?.id ?? ""
        _stickerID = State(initialValue: first)
        _scene = State(initialValue: EffectsGalleryScene(pack: pack, stickerID: first))
    }

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        HStack(spacing: 0) {
            SpriteView(scene: scene)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Effects gallery")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                    }
                    .accessibilityLabel("Close")
                }

                Picker("Sticker", selection: $stickerID) {
                    ForEach(pack.manifest.stickers) { sticker in
                        Text(verbatim: sticker.id).tag(sticker.id)
                    }
                }
                .onChange(of: stickerID) { scene.show(stickerID: stickerID) }

                Picker("Intensity", selection: $intensity) {
                    Text(verbatim: "0.3").tag(0.3)
                    Text(verbatim: "0.6").tag(0.6)
                    Text(verbatim: "1.0").tag(1.0)
                }
                .pickerStyle(.segmented)

                Toggle("Loop", isOn: $loop)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(EffectName.allCases, id: \.self) { effect in
                            Button {
                                var options = EffectOptions(
                                    repeatCount: loop ? .loop : .times(1), intensity: intensity)
                                if effect == .tint { options.color = RGBA(hex: "#FF6B8A") }
                                scene.play(effect, options: options)
                            } label: {
                                Text(verbatim: effect.rawValue)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(color(for: effect.category)))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(SquishyButtonStyle())
                        }
                    }
                }

                HStack {
                    Button("Play all") { scene.playAll(intensity: intensity) }
                        .buttonStyle(.bordered)
                    Button("Stop all") { scene.stopAll() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(width: 330)
            .background(Color(white: 0.96))
        }
        .statusBarHidden(true)
        .onAppear {
            // `-effectsGalleryDemo` launch argument: cycle through everything
            // unattended (simulator screenshots, quick eyeballing).
            if ProcessInfo.processInfo.arguments.contains("-effectsGalleryDemo") {
                scene.playAll(intensity: 1.0, repeating: true)
            }
        }
    }

    private func color(for category: EffectName.Category) -> Color {
        switch category {
        case .motion: Color(red: 0.36, green: 0.6, blue: 0.9)
        case .opacityAndColor: Color(red: 0.86, green: 0.5, blue: 0.3)
        case .particle: Color(red: 0.2, green: 0.55, blue: 0.3)
        }
    }
}

/// A tiny stand-in for the canvas: one sticker on the pack's background,
/// driven by the same applier, emitters and glow cache the real scene uses,
/// on a synthetic clock.
final class EffectsGalleryScene: SKScene {
    private let pack: LoadedPack
    private let background = SKSpriteNode()
    private let layer = SKNode()
    private var sticker: StickerNode?
    private let glowMasks = GlowMaskCache()
    private let runner = StickerEffectsRunner()
    private lazy var applier = EffectApplier { [weak self] node in
        guard let self, let definition = pack.sticker(withID: node.stickerID) else { return nil }
        return glowMasks.mask(for: node.stickerID) {
            UIImage(contentsOfFile: pack.url(forAssetPath: definition.image).path)
        }
    }
    private let emitters = EmitterCoordinator()
    private let clock = PlaybackClock { nil }
    private var pendingStickerID: String
    /// A `playAll` requested before the scene was presented (SwiftUI's
    /// `onAppear` fires before `didMove(to:)`).
    private var pendingPlayAll: (intensity: Double, repeating: Bool)?

    init(pack: LoadedPack, stickerID: String) {
        self.pack = pack
        pendingStickerID = stickerID
        super.init(size: CGSize(width: 700, height: 700))
        scaleMode = .resizeFill
        backgroundColor = UIColor(red: 0.49, green: 0.78, blue: 0.91, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        guard background.parent == nil else { return }
        if let image = UIImage(contentsOfFile: pack.url(forAssetPath: pack.manifest.background).path) {
            background.texture = SKTexture(image: image)
        }
        background.zPosition = 0
        layer.zPosition = 100
        addChild(background)
        addChild(layer)
        layoutBackground()
        show(stickerID: pendingStickerID)
        if let pending = pendingPlayAll {
            pendingPlayAll = nil
            playAll(intensity: pending.intensity, repeating: pending.repeating)
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard background.parent != nil else { return }
        layoutBackground()
        sticker?.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func layoutBackground() {
        guard let textureSize = background.texture?.size(), textureSize.width > 0 else { return }
        let fill = max(size.width / textureSize.width, size.height / textureSize.height)
        background.size = CGSize(width: textureSize.width * fill, height: textureSize.height * fill)
        background.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func show(stickerID: String) {
        pendingStickerID = stickerID
        guard background.parent != nil else { return }
        stopEffects()
        sticker?.removeFromParent()
        guard let definition = pack.sticker(withID: stickerID),
            let image = UIImage(contentsOfFile: pack.url(forAssetPath: definition.image).path)
        else { return }
        let texture = SKTexture(image: image)
        let side: CGFloat = 220
        let scale = side / max(texture.size().width, texture.size().height)
        let node = StickerNode(
            stickerID: stickerID, texture: texture,
            size: CGSize(width: texture.size().width * scale, height: texture.size().height * scale))
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        node.baseScale = 1.2
        node.setScale(1.2)
        node.zRotation = 0.15  // a little tilt so pivots are visibly right
        layer.addChild(node)
        sticker = node
    }

    func play(_ effect: EffectName, options: EffectOptions) {
        guard let sticker else { return }
        runner.play(effect, on: sticker.instanceID, options: options)
    }

    func stopAll() {
        removeAction(forKey: "play-all")
        stopEffects()
    }

    private func stopEffects() {
        runner.stopAll()
        emitters.clearAll()
        if let sticker { applier.restoreAll([sticker.instanceID: sticker]) }
    }

    /// Plays every effect in library order, one every 1.6 s.
    func playAll(intensity: Double, repeating: Bool = false) {
        guard sticker != nil else {
            pendingPlayAll = (intensity, repeating)
            return
        }
        stopAll()
        var steps: [SKAction] = []
        for effect in EffectName.allCases {
            steps.append(.run { [weak self] in
                var options = EffectOptions(intensity: intensity)
                if effect == .tint { options.color = RGBA(hex: "#FF6B8A") }
                self?.play(effect, options: options)
            })
            steps.append(.wait(forDuration: 1.6))
        }
        let sequence = SKAction.sequence(steps)
        run(repeating ? .repeatForever(sequence) : sequence, withKey: "play-all")
    }

    override func update(_ currentTime: TimeInterval) {
        guard let sticker else { return }
        let nodes = [sticker.instanceID: sticker]
        let time = clock.now()
        applier.apply(runner.tick(time), to: nodes)
        emitters.reconcile(runner.active, at: time, nodes: nodes)
    }
}
#endif
