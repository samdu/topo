import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The voice's and the ear's downloader: Background Assets' managed extension for Apple-hosted
/// packs, as the system provides it. It downloads what each pack's manifest says
/// (`phonon-40m-en` and `parakeet-ultra`, each essential at first installation) and the updates App Store Connect publishes; the app copies the pack's files into
/// its own stores (`BundleStore`).
@main
struct TopoAssets: StoreDownloaderExtension {}
