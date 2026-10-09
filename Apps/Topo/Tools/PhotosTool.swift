import Foundation
import ImageIO
import os
import Photos
import TopoTools
import TopoUserland
import UIKit
import UniformTypeIdentifiers

struct PhotoAlbum: Sendable, Equatable {
    var id: String
    var title: String
    var count: Int
}

struct PhotoRecord: Sendable, Equatable {
    var id: String
    var taken: Date?
    /// photo, video, screenshot or live.
    var kind: String
    var width: Int
    var height: Int
    var favorite = false
    var latitude: Double?
    var longitude: Double?
}

struct PhotoQuery: Sendable, Equatable {
    enum Kind: String, Sendable {
        case photo, video
    }

    var album: String?
    var from: Date?
    /// Exclusive.
    var to: Date?
    var kind: Kind?
    var favorites = false
    var limit = PhotosTool.shown
}

/// The person's photo library: PhotoKit on the phone, a fake in the suites. It is read, and one
/// thing is added to it (`add`); nothing in it is changed or removed.
protocol PhotoLibrary: Sendable {
    /// Whether the person let Topo see only the photos they chose.
    func limited() async -> Bool
    /// At most `limit + 1`, so one more than asked says there are more.
    func albums(limit: Int) async throws -> [PhotoAlbum]
    /// Newest first, at most `query.limit + 1`, so one more than asked says there are more.
    func search(_ query: PhotoQuery) async throws -> [PhotoRecord]
    /// One asset as a JPEG at most `longSide` pixels on its long side (a video's first frame), and
    /// what it is; nil when the library has no asset with that id.
    func still(id: String, longSide: Int) async throws -> (record: PhotoRecord, jpeg: Data)?
    /// Adds `image`, a PNG, JPEG or HEIC as its file holds it, as a new photo, and answers its id.
    func add(image: Data) async throws -> String
}

/// `topo photos`: the albums, a search by album, date and kind, one photo copied into the guest's
/// home as a still for the mind to look at, and a picture from the guest added to the library.
struct PhotosTool: Tool {
    let library: any PhotoLibrary
    let authorizer: any Authorizer
    let broker: PermissionBroker
    /// The guest's home on the host, which `guestHome` names in the guest.
    var home: @Sendable () -> URL = { GuestResident.homeDirectory }
    /// The bytes of a file as the guest reads it, at most `saveBytes` of them, or nil.
    var read: @Sendable (String) async -> Data? = { path in
        guard Guest.shared.kernels > 0 else { return nil }
        return (try? await Guest.shared.contents(ofFile: path, from: ClaudeLauncher.home, limit: PhotosTool.saveBytes)) ?? nil
    }

    static let guestHome = ClaudeLauncher.home
    /// The folder under the home an export lands in.
    static let folder = "photos"
    /// What a search shows unless it is asked for another count, and the most it can be asked for.
    static let shown = 20
    static let most = 50
    /// At most this many albums are listed.
    static let albumsShown = 100
    /// An exported still's long side, in pixels.
    static let longSide = 2048
    /// The most bytes a picture saved to the library may be.
    static let saveBytes = 20 * 1024 * 1024
    static let saveTypes: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]

    let name = "photos"
    let summary = "the person's photo library: albums, photos by date and kind, one exported to look at, a picture saved"
    var usage: String { """
    topo photos albums                  the albums, one a line, id first; Screenshots, Favorites and the like are albums
    topo photos search [--album ID] [--from DATE] [--to DATE] [--kind photo|video] [--favorites] [--limit N]
                                        newest first, one a line: id | taken | kind | size | favourite | lat,lon;
                                        \(Self.shown) unless --limit says otherwise, at most \(Self.most). The library is searched by
                                        album, date and kind and not by what a photo shows: export one to see it
    topo photos export ID               copy one into \(Self.guestHome)/\(Self.folder) as a JPEG, at most \(Self.longSide) px on its long
                                        side (a video's first frame), and print its path, to read as an image
    topo photos save PATH               add a PNG, JPEG or HEIC from the guest (at most \(Self.saveBytes / 1024 / 1024) MB) to the library as
                                        a new photo. Nothing in the library is changed or deleted
    """ }

    enum Call: Equatable {
        case albums
        case search(PhotoQuery)
        case export(id: String)
        case save(path: String)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case .albums:
                let albums = try await library.albums(limit: Self.albumsShown)
                var lines = albums.prefix(Self.albumsShown).map { album in
                    PhoneTool.line([album.id, album.title, "\(album.count) item\(album.count == 1 ? "" : "s")"])
                }
                if albums.count > Self.albumsShown { lines.append("… and more albums") }
                return .ok(await limitedNote() + PhoneTool.lines(lines, none: "no albums"))
            case let .search(query):
                let found = try await library.search(query)
                var lines = found.prefix(query.limit).map(Self.line)
                if found.count > query.limit {
                    lines.append("… and more; narrow the dates\(query.limit < Self.most ? " or raise --limit (at most \(Self.most))" : "")")
                }
                return .ok(await limitedNote() + PhoneTool.lines(lines, none: "no photos found"))
            case let .export(id):
                return try await export(id)
            case let .save(path):
                return try await save(path)
            }
        }
    }

    /// The line a limited library opens its answers with, so a short list is not read as the whole
    /// of the person's photos.
    private func limitedNote() async -> String {
        await library.limited()
            ? "limited access: only the photos the person chose for Topo are here; they can choose more in the Settings app, under Apps › Topo › Photos\n"
            : ""
    }

    static func line(_ record: PhotoRecord) -> String {
        var place: String?
        if let latitude = record.latitude, let longitude = record.longitude {
            place = String(format: "%.5f,%.5f", latitude, longitude)
        }
        return PhoneTool.line([record.id, record.taken.map { ToolDates.write($0) }, record.kind,
                               "\(record.width)×\(record.height)", record.favorite ? "favourite" : nil, place])
    }

    private func export(_ id: String) async throws -> ToolReply {
        let file = try Self.fileName(for: id)
        guard let found = try await library.still(id: id, longSide: Self.longSide) else {
            let limited = await library.limited() ? " among the photos the person chose for Topo; access is limited to those" : ""
            throw ToolFailure("no photo with the id \(id)\(limited)")
        }
        try Task.checkCancellation()
        let path = "\(Self.guestHome)/\(Self.folder)/\(file)"
        let still = found.record.kind == "video" ? " (a video: this is a still of it)" : ""
        switch try HomeFile.create(found.jpeg, named: file, in: [Self.folder], under: home()) {
        case .created:
            return .ok("exported: \(path)\(still)\n")
        case .exists:
            return .ok("already exported: \(path)\(still)\nRemove that file first to export it afresh.\n")
        }
    }

    private func save(_ path: String) async throws -> ToolReply {
        guard let data = await read(path) else {
            throw ToolFailure("\(path) cannot be read: no such file in the guest, not a regular file, or over \(Self.saveBytes / 1024 / 1024) MB")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, Self.saveTypes.contains(type),
              CGImageSourceGetCount(source) > 0 else {
            throw ToolFailure("\(path) is not a PNG, JPEG or HEIC", status: ToolReply.refused)
        }
        try Task.checkCancellation()
        let id = try await library.add(image: data)
        return .ok("saved: \(id)\n")
    }

    /// The name an asset's export is written under: its identifier up to the first slash, which is
    /// a UUID on a phone, kept only where it is letters, digits and dashes, so no id names a path.
    static func fileName(for id: String) throws -> String {
        let stem = id.prefix { $0 != "/" }.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard !stem.isEmpty, stem.count <= 64 else { throw ToolFailure("\(id) is not a photo's id", status: ToolReply.usage) }
        return stem + ".jpg"
    }

    /// The call the arguments make, or why they make none: nothing here needs the permission.
    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments, options: ["album", "from", "to", "kind", "limit"], flags: ["favorites"])
        switch (parsed.words.first, parsed.words.count) {
        case ("albums", 1):
            try parsed.only([], for: "albums")
            return .albums
        case ("search", 1):
            var query = PhotoQuery(album: parsed.options["album"], favorites: parsed.flags.contains("favorites"))
            query.from = try PhoneTool.date(parsed.options["from"], "--from")?.date
            if let to = try PhoneTool.date(parsed.options["to"], "--to") {
                // A day with no time of day is the whole of that day.
                query.to = to.hasTime ? to.date : Calendar.current.date(byAdding: .day, value: 1, to: to.date)
            }
            if let from = query.from, let to = query.to, from >= to { throw Misuse("--from is not before --to") }
            if let kind = parsed.options["kind"] {
                guard let read = PhotoQuery.Kind(rawValue: kind) else { throw Misuse("--kind is photo or video") }
                query.kind = read
            }
            if let limit = parsed.options["limit"] {
                guard let count = Int(limit), (1...Self.most).contains(count) else {
                    throw Misuse("--limit is a number from 1 to \(Self.most)")
                }
                query.limit = count
            }
            return .search(query)
        case ("search", _):
            throw Misuse("photos search takes no words: the library is searched by album, date and kind, not by what a photo shows")
        case ("export", 2):
            try parsed.only([], for: "export")
            return .export(id: parsed.words[1])
        case ("save", 2):
            try parsed.only([], for: "save")
            return .save(path: parsed.words[1])
        default:
            throw Misuse("photos takes albums, search, export ID or save PATH")
        }
    }
}

/// Read and write access to the library, which the four calls share: the phone has one switch for
/// Topo under Photos, and a library the person limited to the photos they chose is one Topo may use.
struct PhotosAuthorizer: Authorizer {
    let name = "Photos"

    func access() async -> Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .granted
        }
    }

    func request() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}

/// PhotoKit. Its fetches are synchronous, so they run on a queue of their own (`Confined`) and
/// never on the cooperative pool; an image request is bounded and cancelled with its call.
final class PhotoKitLibrary: PhotoLibrary, Sendable {
    private let confined = Confined((), label: "zone.hexagon.topo.photos")

    /// The longest one photo's still is waited for: one kept only in iCloud is downloaded first.
    static let stillBound: Duration = .seconds(30)

    func limited() async -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    /// The most collections of one type that are looked at for a list of albums.
    static let collectionsRead = 300

    func albums(limit: Int) async throws -> [PhotoAlbum] {
        try await confined.run { _, cancellation in
            var albums: [PhotoAlbum] = []
            for type in [PHAssetCollectionType.smartAlbum, .album] {
                let options = PHFetchOptions()
                options.fetchLimit = Self.collectionsRead
                let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: options)
                for index in 0..<collections.count where albums.count <= limit {
                    try cancellation.check()
                    let collection = collections.object(at: index)
                    // A count of the album's photos, which reads none of them.
                    let count = PHAsset.fetchAssets(in: collection, options: nil).count
                    // The system's own albums are all listed by PhotoKit, most of them empty.
                    if type == .smartAlbum, count == 0 { continue }
                    albums.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count))
                }
            }
            return albums
        }
    }

    func search(_ query: PhotoQuery) async throws -> [PhotoRecord] {
        try await confined.run { _, _ in
            let options = PHFetchOptions()
            var predicates: [NSPredicate] = []
            if let from = query.from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
            if let to = query.to { predicates.append(NSPredicate(format: "creationDate < %@", to as NSDate)) }
            switch query.kind {
            case .photo: predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
            case .video: predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
            case nil: break
            }
            if query.favorites { predicates.append(NSPredicate(format: "isFavorite == YES")) }
            if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = query.limit + 1
            let assets: PHFetchResult<PHAsset>
            if let album = query.album {
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
                    throw ToolFailure("no album with the id \(album)")
                }
                assets = PHAsset.fetchAssets(in: collection, options: options)
            } else {
                assets = PHAsset.fetchAssets(with: options)
            }
            return (0..<assets.count).map { Self.record(assets.object(at: $0)) }
        }
    }

    func still(id: String, longSide: Int) async throws -> (record: PhotoRecord, jpeg: Data)? {
        let request = StillRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation, bound: Self.stillBound)
                confined.async { _ in
                    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                        return request.finish(.success(nil))
                    }
                    let record = Self.record(asset)
                    let options = PHImageRequestOptions()
                    // One answer, the full one, and a photo kept only in iCloud brought down for it.
                    options.deliveryMode = .highQualityFormat
                    options.resizeMode = .exact
                    options.isNetworkAccessAllowed = true
                    let side = CGFloat(longSide)
                    let started = PHImageManager.default().requestImage(
                        for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options
                    ) { image, _ in
                        // PhotoKit answers on the main thread; the picture is encoded off it.
                        self.confined.async { _ in
                            guard let image, let jpeg = Self.jpeg(image, longSide: longSide) else {
                                return request.finish(.failure(ToolFailure("the photo could not be read from the library")))
                            }
                            request.finish(.success((record, jpeg)))
                        }
                    }
                    request.started(started)
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    func add(image: Data) async throws -> String {
        let made = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: image, options: nil)
            let id = request.placeholderForCreatedAsset?.localIdentifier
            made.withLock { $0 = id }
        }
        guard let id = made.withLock({ $0 }) else { throw ToolFailure("the library took the picture and named no photo for it") }
        return id
    }

    /// `image` as a JPEG no longer than `longSide` on its long side: PhotoKit answers a size near
    /// the one asked for, so one over it is drawn down.
    static func jpeg(_ image: UIImage, longSide: Int) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let long = max(pixels.width, pixels.height)
        guard long > 0 else { return nil }
        guard long > CGFloat(longSide) else { return image.jpegData(compressionQuality: 0.85) }
        let ratio = CGFloat(longSide) / long
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixels.width * ratio).rounded(.down), height: (pixels.height * ratio).rounded(.down))
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func record(_ asset: PHAsset) -> PhotoRecord {
        let kind = asset.mediaType == .video ? "video"
            : asset.mediaSubtypes.contains(.photoScreenshot) ? "screenshot"
            : asset.mediaSubtypes.contains(.photoLive) ? "live" : "photo"
        return PhotoRecord(id: asset.localIdentifier, taken: asset.creationDate, kind: kind,
                           width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite,
                           latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude)
    }
}

/// One image request: answered once, by the image, by its bound or by its call's cancellation,
/// and the request itself cancelled when it is the bound or the cancellation that answers.
private final class StillRequest: Sendable {
    typealias Answer = Result<(record: PhotoRecord, jpeg: Data)?, any Error>

    private struct State {
        var continuation: CheckedContinuation<(record: PhotoRecord, jpeg: Data)?, any Error>?
        var request: PHImageRequestID?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(_ continuation: CheckedContinuation<(record: PhotoRecord, jpeg: Data)?, any Error>, bound: Duration) {
        let late = state.withLock { state -> Bool in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        if late { return continuation.resume(throwing: CancellationError()) }
        Task {
            try? await Task.sleep(for: bound)
            self.finish(.failure(ToolFailure("the photo did not arrive within \(Int(bound / .seconds(1))) s; it may be on its way down from iCloud, so try again")))
        }
    }

    /// PhotoKit's id for the request, to cancel it by; one that arrives after the answer is
    /// cancelled at once.
    func started(_ request: PHImageRequestID) {
        let finished = state.withLock { state -> Bool in
            state.request = request
            return state.finished
        }
        if finished { PHImageManager.default().cancelImageRequest(request) }
    }

    func finish(_ answer: Answer) {
        let (continuation, request) = state.withLock { state -> (CheckedContinuation<(record: PhotoRecord, jpeg: Data)?, any Error>?, PHImageRequestID?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            defer { state.continuation = nil }
            return (state.continuation, state.request)
        }
        if case .failure = answer, let request { PHImageManager.default().cancelImageRequest(request) }
        continuation?.resume(with: answer)
    }
}
