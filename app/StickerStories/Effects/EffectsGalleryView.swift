#if DEBUG
import SpriteKit
import StickerStoriesKit
import SwiftUI

/// Developer-only: plays every sticker effect on a real sticker at three
/// intensities, and every canvas effect over the pack's art, so the
/// library's numbers can be tuned against real art. Reached from Settings
/// in debug builds; never compiled into release.
struct EffectsGalleryView: View {
    let pack: LoadedPack
    @Environment(\.dismiss) private var dismiss
    @State private var scene: EffectsGalleryScene
    @State private var intensity = 0.6
    @State private var loop = false
    @State private var canvasDuration = 6.0
    @State private var stickerID: String
    /// Live animations found in the pack (`StickerAnimation`), by sticker.
    private let animations: [StickerAnimation]

    init(pack: LoadedPack) {
        self.pack = pack
        let first = pack.manifest.stickers.first?.id ?? ""
        _stickerID = State(initialValue: first)
        _scene = State(initialValue: EffectsGalleryScene(pack: pack, stickerID: first))
        animations = StickerAnimation.available(in: pack)
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
                                effectLabel(effect.rawValue, color(for: effect.category))
                            }
                            .buttonStyle(SquishyButtonStyle())
                        }
                    }

                    Text("Live")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                    let live = animations.filter { $0.sticker == stickerID }
                    if live.isEmpty {
                        Text("No live animations for this sticker")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(live) { animation in
                                ForEach(parts(of: animation), id: \.label) { part in
                                    Button { scene.playLive(animation, part: part.part) } label: {
                                        effectLabel(part.label, liveColor)
                                    }
                                    .buttonStyle(SquishyButtonStyle())
                                }
                            }
                        }
                    }

                    HStack {
                        Text("Canvas")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        Spacer()
                        Picker("Duration", selection: $canvasDuration) {
                            Text(verbatim: "3 s").tag(3.0)
                            Text(verbatim: "6 s").tag(6.0)
                            Text(verbatim: "20 s").tag(20.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                    .padding(.top, 12)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(CanvasEffectName.allCases, id: \.self) { effect in
                            Button {
                                scene.play(effect, options: CanvasEffectOptions(intensity: intensity, duration: canvasDuration))
                            } label: {
                                effectLabel(effect.rawValue, canvasColor)
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
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-effectsGalleryDemo") {
                scene.playAll(intensity: 1.0, repeating: true)
            }
            // `-canvasDemo snow,night+fireflies`: loop just those canvas
            // effects at full strength, 12 s each; `+` plays a group together
            // (screenshots of one effect, or of the layers it is meant for).
            if let index = arguments.firstIndex(of: "-canvasDemo"), index + 1 < arguments.count {
                let groups = arguments[index + 1].split(separator: ",").map { group in
                    group.split(separator: "+").compactMap { CanvasEffectName(rawValue: String($0)) }
                }
                scene.playCanvas(groups.filter { !$0.isEmpty })
            }
            // `-liveDemo [sticker | sticker.animation]`: loop a live animation
            // on its sticker (the first one, the named sticker's first, or
            // the named one); a move travels 3 s each time round.
            if let index = arguments.firstIndex(of: "-liveDemo"),
                let animation = animations.first(where: {
                    index + 1 < arguments.count ? $0.sticker == arguments[index + 1] || $0.key == arguments[index + 1] : true
                }) ?? animations.first
            {
                stickerID = animation.sticker
                scene.playLive(animation, part: animation.kind == .move ? .move(travel: 3) : .whole, repeating: true)
            }
        }
    }

    /// The ways the gallery plays an animation: an action whole, held and
    /// resumed when it has a pause frame; a move travelling for 3 s.
    private func parts(of animation: StickerAnimation) -> [(label: String, part: LivePart)] {
        switch animation.kind {
        case .move:
            return [(animation.id, .move(travel: 3))]
        case .action:
            var out: [(label: String, part: LivePart)] = [(animation.id, .whole)]
            if animation.frames.pause != nil {
                out.append(("\(animation.id) hold", .toPause))
                out.append(("\(animation.id) resume", .fromPause(held: true)))
            }
            return out
        }
    }

    private func effectLabel(_ name: String, _ color: Color) -> some View {
        Text(verbatim: name)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(color))
            .foregroundStyle(.white)
    }

    private func color(for category: EffectName.Category) -> Color {
        switch category {
        case .motion: Color(red: 0.36, green: 0.6, blue: 0.9)
        case .opacityAndColor: Color(red: 0.86, green: 0.5, blue: 0.3)
        case .particle: Color(red: 0.2, green: 0.55, blue: 0.3)
        }
    }

    private var canvasColor: Color { Color(red: 0.5, green: 0.38, blue: 0.75) }
    private var liveColor: Color { Color(red: 0.85, green: 0.35, blue: 0.45) }
}

/// A tiny stand-in for the canvas: one sticker on the pack's background,
/// driven by the same applier, emitters, glow cache and canvas effect layer
/// the real scene uses, on a synthetic clock.
final class EffectsGalleryScene: SKScene {
    private let pack: LoadedPack
    private let background = SKSpriteNode()
    private let layer = SKNode()
    private let canvasEffects = CanvasEffectLayer()
    private var sticker: StickerNode?
    private let glowMasks = GlowMaskCache()
    private let shadows = StickerShadowCache()
    private let runner = StickerEffectsRunner()
    private let canvasRunner = CanvasEffectsRunner()
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
    /// Sprite sheets of the sticker on show, loaded on first play and let
    /// go of when the gallery moves to another sticker (each is a large
    /// texture; ten animated stickers must not pile up).
    private var sheets: [String: SKTexture] = [:]
    /// A `playLive` requested before its sticker was on show.
    private var pendingLive: (animation: StickerAnimation, part: LivePart, repeating: Bool)?
    /// The animation on show, which part, since when (scene time) and
    /// whether it starts over when done.
    private var liveRun: (loaded: LoadedLiveAnimation, part: LivePart, start: TimeInterval, repeating: Bool)?
    private var sceneTime: TimeInterval = 0

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
        // `-galleryBackdrop 0B1030`: a plain colour instead of the pack's
        // art, to judge space and underwater effects without a pack of that
        // kind.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-galleryBackdrop"), index + 1 < arguments.count,
            let hex = Int(arguments[index + 1], radix: 16)
        {
            background.isHidden = true
            backgroundColor = UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        layer.zPosition = 100  // the rainbow (50) sits behind the sticker, the rest (500) in front
        addChild(background)
        addChild(layer)
        addChild(canvasEffects)
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
        canvasEffects.layout(world: CGRect(origin: .zero, size: size))
        guard let textureSize = background.texture?.size(), textureSize.width > 0 else { return }
        let fill = max(size.width / textureSize.width, size.height / textureSize.height)
        background.size = CGSize(width: textureSize.width * fill, height: textureSize.height * fill)
        background.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func show(stickerID: String) {
        pendingStickerID = stickerID
        guard background.parent != nil else { return }
        stopEffects()
        sheets.removeAll()
        shadows.forgetShadowSheets()
        sticker?.removeFromParent()
        guard let definition = pack.sticker(withID: stickerID),
            let image = UIImage(contentsOfFile: pack.url(forAssetPath: definition.image).path)
        else { return }
        let texture = SKTexture(image: image)
        let side: CGFloat = 220
        let scale = side / max(texture.size().width, texture.size().height)
        let node = StickerNode(
            stickerID: stickerID, texture: texture,
            size: CGSize(width: texture.size().width * scale, height: texture.size().height * scale),
            shadow: shadows.shadow(for: stickerID) { image })
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        node.baseScale = 1.2
        node.setScale(1.2)
        node.zRotation = 0.15  // a little tilt so pivots are visibly right
        layer.addChild(node)
        sticker = node
        if let pending = pendingLive, pending.animation.sticker == stickerID {
            pendingLive = nil
            playLive(pending.animation, part: pending.part, repeating: pending.repeating)
        }
    }

    /// Plays a live animation on the sticker on show; waits for it if the
    /// gallery is still switching to that sticker.
    func playLive(_ animation: StickerAnimation, part: LivePart, repeating: Bool = false) {
        guard let sticker, sticker.stickerID == animation.sticker else {
            pendingLive = (animation, part, repeating)
            return
        }
        let sheet: SKTexture
        var image: UIImage?
        if let cached = sheets[animation.key] {
            sheet = cached
        } else {
            guard let loaded = UIImage(contentsOfFile: pack.url(forAssetPath: animation.sheet).path) else { return }
            image = loaded
            sheet = SKTexture(image: loaded)
            sheets[animation.key] = sheet
        }
        let shadowSheet = shadows.shadowSheet(for: animation) {
            image ?? UIImage(contentsOfFile: pack.url(forAssetPath: animation.sheet).path)
        }
        liveRun = (LoadedLiveAnimation(animation: animation, sheet: sheet, shadowSheet: shadowSheet), part, sceneTime, repeating)
    }

    func play(_ effect: EffectName, options: EffectOptions) {
        guard let sticker else { return }
        runner.play(effect, on: sticker.instanceID, options: options)
    }

    /// Canvas effects ignore the pack's setting here: the gallery is for
    /// looking at all of them over whatever art the pack has.
    func play(_ effect: CanvasEffectName, options: CanvasEffectOptions) {
        canvasRunner.play(effect, options: options)
    }

    func stopAll() {
        removeAction(forKey: "play-all")
        pendingLive = nil
        stopEffects()
    }

    private func stopEffects() {
        liveRun = nil
        sticker?.stopLive()
        runner.stopAll()
        canvasRunner.stopAll()
        emitters.clearAll()
        canvasEffects.clearAll()
        if let sticker { applier.restoreAll([sticker.instanceID: sticker]) }
    }

    /// Plays every sticker effect in library order, one every 1.6 s, then
    /// every canvas effect for 4 s each.
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
        for effect in CanvasEffectName.allCases {
            steps.append(.run { [weak self] in
                self?.play(effect, options: CanvasEffectOptions(intensity: intensity, duration: 4))
            })
            steps.append(.wait(forDuration: 4.5))
        }
        let sequence = SKAction.sequence(steps)
        run(repeating ? .repeatForever(sequence) : sequence, withKey: "play-all")
    }

    /// Loops the given groups of canvas effects at full strength, 12 s each;
    /// the effects in a group play together.
    func playCanvas(_ groups: [[CanvasEffectName]]) {
        guard !groups.isEmpty else { return }
        stopAll()
        var steps: [SKAction] = []
        for group in groups {
            steps.append(.run { [weak self] in
                for effect in group { self?.play(effect, options: CanvasEffectOptions(intensity: 1, duration: 12)) }
            })
            steps.append(.wait(forDuration: 12.5))
        }
        run(.repeatForever(.sequence(steps)), withKey: "play-all")
    }

    override func update(_ currentTime: TimeInterval) {
        sceneTime = currentTime
        guard let sticker else { return }
        if let run = liveRun {
            if let state = run.loaded.timing.state(run.part, at: currentTime - run.start) {
                sticker.showLive(run.loaded, state: state)
            } else if run.repeating {
                liveRun?.start = currentTime
            } else {
                liveRun = nil
                sticker.stopLive()
            }
        }
        let nodes = [sticker.instanceID: sticker]
        let time = clock.now()
        applier.apply(runner.tick(time), to: nodes)
        emitters.reconcile(runner.active, at: time, nodes: nodes)
        canvasEffects.apply(canvasRunner.tick(time), at: time)
    }
}
#endif
