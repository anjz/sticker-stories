import BackgroundAssets
import Foundation
import Observation
import OSLog
import StickerStoriesKit
import System

/// The packs' narration, which reaches the device per language as
/// Apple-hosted asset packs (docs/asset-delivery.md): where a story's
/// narration is, which languages are on the device, and fetching and
/// tidying them. The narrators play from it, Settings shows it, and the
/// story screen falls back through it while a language downloads.
@MainActor
@Observable
final class NarrationLibrary {
    /// A language's narration, across every pack the family has.
    enum LanguageState: Equatable {
        case onDevice
        /// Arriving: how much of it, 0...1.
        case downloading(Double)
        /// Asked for but not arriving (no network, a failure): the system
        /// keeps trying.
        case waiting
        /// Not on the device; its size in bytes when known.
        case notDownloaded(bytes: Int?)
    }

    /// Every pack language's state, for Settings.
    private(set) var states: [String: LanguageState] = [:]
    /// The languages the family's packs are in (the first pack's order).
    private(set) var languages: [String] = []

    private var packs: [LoadedPack] = []
    /// Download progress by asset pack ID, while one is arriving.
    private var progress: [String: Double] = [:]
    private var failed: Set<String> = []
    private var sizes: [String: Int] = [:]
    private var watching: Set<String> = []
    /// The language the family chose (resolved for the first pack), which
    /// the tidy-up keeps.
    private var current: String?
    private let log = Logger(subsystem: "com.anj.stickerstories", category: "narration")

    private static let recentKey = "narration.recentLanguages"
    private static let knownKey = "narration.knownAssetPacks"

    /// Debug builds carry the narration in the packs too, for simulator
    /// runs; `-narrationFromAssetPacksOnly` ignores it to exercise downloads.
    private let assetPacksOnly: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-narrationFromAssetPacksOnly")
        #else
        false  // release builds have no narration in the packs anyway
        #endif
    }()

    // MARK: Where narration is

    /// The file a story's narration plays from: its language's asset pack,
    /// else the pack itself (debug builds, or a language without one).
    func url(forAudio path: String, in pack: LoadedPack, language: String?) -> URL? {
        // `url(for:)` answers with a path even while the asset pack isn't
        // here, so the pack is checked first and the file after.
        if let language, let id = pack.manifest.narrationPacks[language],
            AssetPackManager.shared.assetPackIsAvailableLocally(withID: id),
            let url = try? AssetPackManager.shared.url(for: FilePath(PackManifest.narrationPath(assetPackID: id, audio: path))),
            FileManager.default.fileExists(atPath: url.path)
        {
            return url
        }
        let bundled = pack.url(forAssetPath: path)
        if let language, pack.manifest.narrationPacks[language] != nil, assetPacksOnly { return nil }
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    /// Whether a pack's narration in `language` is on the device.
    func isOnDevice(_ pack: LoadedPack, _ language: String) -> Bool {
        guard let id = pack.manifest.narrationPacks[language] else { return true }  // in the pack itself
        if AssetPackManager.shared.assetPackIsAvailableLocally(withID: id) { return true }
        guard !assetPacksOnly, let audio = pack.manifest.stories.first?.localizations[language]?.audio else { return false }
        return FileManager.default.fileExists(atPath: pack.url(forAssetPath: audio).path)
    }

    // MARK: Playing

    /// Recently played languages, newest first: the fallback order.
    private var recent: [String] { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] }

    /// The language to play a pack's stories in (docs/asset-delivery.md,
    /// "Playing while a language downloads"); nil while none has arrived.
    func choice(for pack: LoadedPack, preferred: String) -> NarrationPlanner.Choice? {
        NarrationPlanner.choose(preferred: preferred, languages: pack.manifest.languages, recent: recent) {
            isOnDevice(pack, $0)
        }
    }

    /// A story is playing in `language`.
    func played(_ language: String) {
        UserDefaults.standard.set(NarrationPlanner.used(language, recent: recent), forKey: Self.recentKey)
    }

    // MARK: Fetching

    /// At launch: the family's packs and language. Fetches the language's
    /// narration if it is missing (the device language may have changed
    /// since the app was installed, or an update re-recorded it), follows
    /// any download under way and removes narration no manifest names any
    /// more.
    func start(packs: [LoadedPack], preferredLanguages: [String]) {
        self.packs = packs
        languages = packs.first?.manifest.languages ?? []
        remember()
        languageChanged(preferredLanguages: preferredLanguages)
        Task { await removeStale() }
    }

    /// The family chose a language (first in `preferredLanguages`, ahead of
    /// the device's): its narration is fetched for every pack, in one
    /// batch. The system isn't told: `resolvedLanguage` would set the app's
    /// own preferred language, hiding the device's from "System language".
    func languageChanged(preferredLanguages: [String]) {
        let resolver = LanguageResolver(preferredLanguages: preferredLanguages)
        current = packs.first.map { resolver.resolve(from: $0.manifest.languages) }
        let wanted = packs.compactMap { pack in pack.manifest.narrationPacks[resolver.resolve(from: pack.manifest.languages)] }
        wanted.forEach(watch)
        refresh()
        Task { await fetch(wanted) }
    }

    private func fetch(_ ids: [String]) async {
        let missing = ids.filter { !AssetPackManager.shared.assetPackIsAvailableLocally(withID: $0) }
        if !missing.isEmpty {
            do {
                let manifest = try await AssetPackManager.shared.manifest
                let assetPacks = Set(missing.compactMap { manifest.assetPack(withID: $0) })
                for assetPack in assetPacks { sizes[assetPack.id] = assetPack.downloadSize }
                refresh()
                try await AssetPackManager.shared.ensureLocalAvailability(of: assetPacks)
            } catch {
                log.error("narration \(missing, privacy: .public) not fetched: \(error, privacy: .public)")
                failed.formUnion(missing)
            }
        }
        refresh()
        await tidy()
    }

    /// Follows an asset pack's downloads for the whole session.
    private func watch(_ id: String) {
        guard watching.insert(id).inserted else { return }
        Task { [weak self] in
            for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: id) {
                guard let self else { return }
                switch update {
                case .began:
                    progress[id] = 0
                    failed.remove(id)
                case .downloading(_, let fraction):
                    progress[id] = fraction.fractionCompleted
                case .paused:
                    break
                case .finished:
                    progress[id] = nil
                    failed.remove(id)
                case .failed:
                    progress[id] = nil
                    failed.insert(id)
                @unknown default:
                    break
                }
                refresh()
                if case .finished = update { await tidy() }
            }
        }
    }

    // MARK: Keeping

    /// Removes the languages the family no longer needs
    /// (`NarrationPlanner.removable`): none until the chosen one is all
    /// here, then the others — the previous one stays with room to spare.
    private func tidy() async {
        guard let current else { return }
        let languages = Set(packs.flatMap(\.manifest.languages))
        let downloaded = languages.filter { language in
            packs.contains { pack in
                pack.manifest.narrationPacks[language].map(AssetPackManager.shared.assetPackIsAvailableLocally(withID:)) ?? false
            }
        }
        let complete = packs.allSatisfy { isOnDevice($0, current) }
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let remove = NarrationPlanner.removable(
            current: current, local: downloaded, currentComplete: complete, recent: recent,
            roomToSpare: free >= NarrationPlanner.roomToSpareBytes)
        for language in remove {
            for id in packs.compactMap({ $0.manifest.narrationPacks[language] })
            where AssetPackManager.shared.assetPackIsAvailableLocally(withID: id) {
                do {
                    try await AssetPackManager.shared.remove(assetPackWithID: id)
                } catch {
                    log.error("narration \(id, privacy: .public) not removed: \(error, privacy: .public)")
                }
            }
        }
        refresh()
    }

    /// Remembers every narration pack the packs name, so one an update
    /// replaces can be found and removed later.
    private func remember() {
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [])
        let named = packs.flatMap { $0.manifest.narrationPacks.values }
        UserDefaults.standard.set(Array(known.union(named)).sorted(), forKey: Self.knownKey)
    }

    /// Removes the narration packs no manifest names any more (a recording
    /// an app update replaced).
    private func removeStale() async {
        let named = Set(packs.flatMap { $0.manifest.narrationPacks.values })
        var known = Set(UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [])
        for id in known.subtracting(named) {
            if AssetPackManager.shared.assetPackIsAvailableLocally(withID: id) {
                do {
                    try await AssetPackManager.shared.remove(assetPackWithID: id)
                } catch {
                    log.error("stale narration \(id, privacy: .public) not removed: \(error, privacy: .public)")
                    continue
                }
            }
            known.remove(id)
        }
        UserDefaults.standard.set(Array(known).sorted(), forKey: Self.knownKey)
    }

    // MARK: State

    private func refresh() {
        var states: [String: LanguageState] = [:]
        for language in Set(packs.flatMap(\.manifest.languages)) {
            let ids = packs.compactMap { $0.manifest.narrationPacks[language] }
            if packs.allSatisfy({ isOnDevice($0, language) }) {
                states[language] = .onDevice
            } else if ids.contains(where: { progress[$0] != nil }) {
                let done = ids.map { AssetPackManager.shared.assetPackIsAvailableLocally(withID: $0) ? 1 : progress[$0] ?? 0 }
                states[language] = .downloading(done.reduce(0, +) / Double(max(done.count, 1)))
            } else if ids.contains(where: failed.contains) {
                states[language] = .waiting
            } else {
                let known = ids.compactMap { sizes[$0] }
                states[language] = .notDownloaded(bytes: known.count == ids.count ? known.reduce(0, +) : nil)
            }
        }
        self.states = states
    }
}
