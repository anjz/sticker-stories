import AVFoundation

/// The app's few interface sounds — a click for play and stop, a lift and
/// a place for stickers — as `.caf` files in `Sounds/`, preloaded once so
/// they start the instant they are asked for. The two sticker sounds cut
/// each other off: the latest action always wins.
///
/// Every audio call happens on one serial queue, never the main thread:
/// configuring and activating the session block on the audio server, and
/// `AVAudioPlayer.play()` re-activates it on each call — Xcode flags all of
/// them as hang risks on the main thread. The hop costs microseconds.
@MainActor
final class UISounds {
    enum Sound: String, CaseIterable {
        case playClick = "play-click"
        case stickerUp = "sticker-up"
        case stickerPlace = "sticker-place"
    }

    static let shared = UISounds()

    private let queue = DispatchQueue(label: "com.anj.stickerstories.ui-sounds", qos: .userInteractive)
    /// The players, owned by `queue`: only ever touched from it, which is
    /// what makes handing the box to the queue's closures safe.
    private nonisolated final class Bank: @unchecked Sendable {
        var players: [Sound: AVAudioPlayer] = [:]
    }
    private let bank = Bank()
    private var prepared = false

    private init() {}

    /// Loads the sounds and readies the audio session. Call it early, while
    /// the pack loads; it is queued ahead of any `play`, so the first sound
    /// waits for it rather than being lost.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        let bank = bank
        queue.async {
            // Interface sounds mix with whatever else is playing and respect
            // the silent switch; the narrator switches to `.playback` for a
            // story.
            let session = AVAudioSession.sharedInstance()
            if session.category == .soloAmbient {
                try? session.setCategory(.ambient)
            }
            try? session.setActive(true)
            for sound in Sound.allCases {
                guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
                    let player = try? AVAudioPlayer(contentsOf: url)
                else { continue }
                player.prepareToPlay()
                bank.players[sound] = player
            }
        }
    }

    func play(_ sound: Sound) {
        prepare()
        let bank = bank
        queue.async {
            func cut(_ other: Sound) {
                guard let player = bank.players[other], player.isPlaying else { return }
                player.pause()
                player.currentTime = 0
            }
            switch sound {
            case .stickerUp: cut(.stickerPlace)
            case .stickerPlace: cut(.stickerUp)
            case .playClick: break
            }
            guard let player = bank.players[sound] else { return }
            // pause + rewind rather than stop(): stop() drops the prepared
            // buffers and the next play would start late.
            player.pause()
            player.currentTime = 0
            player.play()
        }
    }
}
