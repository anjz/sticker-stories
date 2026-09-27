import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The system runs this extension to download the app's Apple-hosted
/// asset packs — each pack's narration, per language
/// (docs/asset-delivery.md). The packs' own language tags and download
/// policies say which to fetch, so it adds nothing of its own.
@main
struct DownloaderExtension: StoreDownloaderExtension {}
