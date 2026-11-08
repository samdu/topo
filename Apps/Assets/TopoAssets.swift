import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The voice's downloader: Background Assets' managed extension for Apple-hosted packs, as the
/// system provides it. It downloads what the pack's manifest says (`phonon-40m-en`, essential,
/// at install) and the updates App Store Connect publishes; the app copies the pack's files into
/// its own store (`PhononStore`).
@main
struct TopoAssets: StoreDownloaderExtension {}
