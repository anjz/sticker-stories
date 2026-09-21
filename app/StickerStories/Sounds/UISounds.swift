import AVFoundation

/// The app's few interface sounds — a click for play and stop, a lift and
/// a place for stickers — as `.caf` files in `Sounds/`, preloaded once so
/// they start the instant they are asked for. The two sticker sounds cut
/// each other off: the latest action always wins.
@MainActor
final class UISounds {
    enum Sound: String, CaseIterable {
        case playClick = "play-click"
        case stickerUp = "sticker-up"
        case stickerPlace = "sticker-place"
    }

    static let shared = UISounds()

    private var players: [Sound: AVAudioPlayer] = [:]

    private init() {
        // Interface sounds mix with whatever else is playing and respect the
        // silent switch; the narrator switches to `.playback` for a story.
        let session = AVAudioSession.sharedInstance()
        if session.category == .soloAmbient {
            try? session.setCategory(.ambient)
        }
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
                let player = try? AVAudioPlayer(contentsOf: url)
            else { continue }
            player.prepareToPlay()
            players[sound] = player
        }
    }

    func play(_ sound: Sound) {
        switch sound {
        case .stickerUp: cut(.stickerPlace)
        case .stickerPlace: cut(.stickerUp)
        case .playClick: break
        }
        guard let player = players[sound] else { return }
        // pause + rewind rather than stop(): stop() drops the prepared
        // buffers and the next play would start late.
        player.pause()
        player.currentTime = 0
        player.play()
    }

    private func cut(_ sound: Sound) {
        guard let player = players[sound], player.isPlaying else { return }
        player.pause()
        player.currentTime = 0
    }
}
