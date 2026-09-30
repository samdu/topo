import Foundation
import ImageIO
import TopoTools
import UniformTypeIdentifiers
import WidgetKit

/// `topo widget`: the mind's hand on the person's widgets. It writes a slot's document into the
/// app group, judged by `WidgetDocument.read` and, for each `run` action, by `WidgetRunJudge`;
/// copies an image the mind made in its home into a slot; clears slots; and shows what was tapped.
/// Every write asks `SurfaceReloader` for one reload of the widgets' timelines, and `SurfaceSync`
/// for the slot's record, which is how the watch gets it.
struct WidgetTool: Tool {
    let judge: WidgetRunJudge
    /// The app group's surfaces; nil where the process has no app group, which every call but
    /// `example` answers as a failure.
    var store: @Sendable () -> SurfaceStore? = { SurfaceStore.shared() }
    var reloader: @MainActor @Sendable () -> SurfaceReloader = { .shared }
    var sync: @MainActor @Sendable () -> SurfaceSync = { .shared }
    /// The guest's home on the host, which `/home/topo` names in the guest.
    var home: @Sendable () -> URL = { GuestResident.homeDirectory }
    /// The widgets placed on this phone: each one's family, and the slot it was set to show.
    var placed: @Sendable () async -> [(family: String, slot: String?)] = { await WidgetTool.currentConfigurations() }

    static let guestHome = "/home/topo"
    static let imageBytes = 512 * 1024
    static let imagePixels = 1024
    static let imageTypes: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]

    let name = "widget"
    let summary = "the person's home-screen and lock-screen widgets: design one, wire its controls, see what was tapped"
    var usage: String {
        """
        topo widget                              every slot: its families, until, what the reader said of it, the controls
                                                 judged only at the tap, and which placed widgets show it
        topo widget set SLOT JSON                write a slot's document (status 6 with the notes when part of it was
                                                 refused and the rest kept, 2 when none of it could be read)
        topo widget image SLOT NAME PATH         copy a PNG, JPEG or HEIC from under \(Self.guestHome) into the slot, for an
                                                 image node named NAME: at most \(Self.imageBytes / 1024) KB, \(Self.imagePixels) px on its long side,
                                                 \(WidgetDocument.imageLimit) a slot
        topo widget clear [SLOT]                 remove a slot, or every slot; a placed widget showing it draws the default
        topo widget taps [SLOT]                  the last \(SurfaceStore.tapsKept) controls tapped: time, slot, control, revision, kind, status
        topo widget example                      a document with every node kind: the quickest way to the shape

        A SLOT is [a-z0-9-], at most 32 characters; at most \(WidgetDocument.slotLimit) slots. The person picks
        which slot a placed widget shows; one with none picked shows the default.
        Families: \(WidgetFamilyName.allCases.filter { $0 != .accessoryCorner }.map(\.rawValue).joined(separator: ", ")).
        A family missing falls back to "default" in the same document. accessoryInline takes one text and one glyph.
        Lock-screen families (the accessory ones) show on a locked phone: put nothing private in them.
        Kinds: vstack, hstack, zstack, text, glyph, image, gauge, progress, topo, spacer, divider, button, toggle, link.
        Budgets: \(WidgetDocument.byteLimit / 1024) KB a document, \(WidgetDocument.nodeLimit) nodes, depth \(WidgetDocument.depthLimit), \(WidgetDocument.controlLimit) controls a family,
        text \(WidgetDocument.textLimit) characters (\(WidgetDocument.accessoryTextLimit) on a lock-screen family).
        Actions: {"kind": "turn", "say": "…"} sends you "widget SLOT: …"; {"kind": "open"} opens Topo;
        {"kind": "run", "topo": [...]} runs one topo call with no turn, one of:
        \(WidgetAction.allowed.map { "topo " + $0.joined(separator: " ") }.joined(separator: ", ")).
        A toggle's run gets on or off appended. A home set on a lock's or a door's target is refused.
        When a slot matters: "relevant": up to \(WidgetDocument.relevantLimit) of {"from": ISO 8601, "to": ISO 8601},
        {"place": "home"|"work"|"school"|"commute"}, {"near": {"lat": …, "lon": …, "radius": 50–50000 metres}},
        {"sleep": "bedtime"|"wakeup"}, {"headphones": true}. The watch's Smart Stack decides, and may bring the
        slot up on the watch face then, placed or not, for whoever is looking at the wrist.
        """
    }

    func run(_ arguments: [String]) async -> ToolReply {
        switch (arguments.first, arguments.count) {
        case ("example", 1):
            return .ok(Self.example + "\n")
        default:
            break
        }
        guard let store = store() else {
            return .failed("topo: this build has no app group, so it has no widgets\n")
        }
        switch (arguments.first, arguments.count) {
        case (nil, _):
            return .ok(await list(store))
        case ("set", 3):
            return await set(arguments[1], arguments[2], store)
        case ("image", 4):
            return await image(slot: arguments[1], name: arguments[2], path: arguments[3], store)
        case ("clear", 1), ("clear", 2):
            return await clear(arguments.count == 2 ? arguments[1] : nil, store)
        case ("taps", 1), ("taps", 2):
            return taps(arguments.count == 2 ? arguments[1] : nil, store)
        default:
            return .usage("topo: widget takes nothing, set, image, clear, taps or example\n\n\(usage)\n")
        }
    }

    // MARK: Reading

    private func list(_ store: SurfaceStore) async -> String {
        let slots = store.slots()
        let behind = await MainActor.run { sync().pending }
        // A slot cleared whose record has not gone yet: the watch still draws it.
        let clearing = behind.subtracting(slots).sorted().map { "slot: \($0), cleared; record behind: the watch still has it" }
        guard !slots.isEmpty else {
            return (["no slots; placed widgets draw the default"] + clearing).joined(separator: "\n") + "\n"
        }
        let placed = await placed()
        var lines: [String] = []
        for slot in slots {
            let document = store.read(slot: slot)?.document ?? WidgetDocument()
            let families = WidgetFamilyName.allCases.filter { document.families[$0] != nil }.map(\.rawValue)
            var head = ["slot: \(slot)", "revision \(document.revision)", "families: " + families.joined(separator: ", ")]
            if let until = document.until { head.append("until \(ToolDates.write(until))") }
            let images = store.imageNames(slot: slot)
            if !images.isEmpty { head.append("images: " + images.joined(separator: ", ")) }
            if behind.contains(slot) { head.append("record behind: the watch has not got this yet") }
            lines.append(PhoneTool.line(head))
            for note in store.notes(slot: slot) { lines.append("  " + note) }
            let shown = placed.filter { $0.slot == slot }.map(\.family)
            lines.append("  placed: " + (shown.isEmpty ? "on no widget" : shown.joined(separator: ", ")))
        }
        lines += clearing
        let unpicked = placed.filter { $0.slot == nil || !slots.contains($0.slot!) }.map(\.family)
        if !unpicked.isEmpty { lines.append("drawing the default: " + unpicked.joined(separator: ", ")) }
        return lines.joined(separator: "\n") + "\n"
    }

    private func taps(_ slot: String?, _ store: SurfaceStore) -> ToolReply {
        let taps = store.taps().filter { slot == nil || $0.slot == slot }
        let lines = taps.map { PhoneTool.line([ToolDates.write($0.time), $0.slot, $0.id, "revision \($0.revision)", $0.kind, $0.status]) }
        return .ok(PhoneTool.lines(lines, none: "no taps"))
    }

    // MARK: Writing

    private func set(_ slot: String, _ text: String, _ store: SurfaceStore) async -> ToolReply {
        if let refusal = Self.refusal(slot: slot) { return ToolReply(status: ToolReply.refused, text: "topo: \(refusal)\n") }
        if !store.slots().contains(slot), store.slots().count >= WidgetDocument.slotLimit {
            return ToolReply(status: ToolReply.refused,
                             text: "topo: there are \(WidgetDocument.slotLimit) slots already; clear one first\n")
        }
        let reading = WidgetDocument.read(text, from: .mind)
        guard case .read = reading.state else {
            if case .unreadable(let why) = reading.state { return .usage("topo: the document \(why); nothing was written\n") }
            return .usage("topo: the document could not be read; nothing was written\n")
        }
        var document = reading.document
        var notes = reading.notes
        var unchecked: [String] = []
        for control in document.controls.values.sorted(by: { $0.id < $1.id }) {
            switch await judge.judge(control) {
            case .ok:
                break
            case .unchecked(let why):
                unchecked.append("unchecked: \(control.id): \(why)")
            case .refused(let why):
                notes.append("\(control.id): its run \(why); it opens Topo instead")
                document.setAction(.open, ofControl: control.id)
            }
        }
        let revision: Int
        do {
            revision = try store.write(document, slot: slot)
            try store.writeNotes(notes + unchecked, slot: slot)
        } catch {
            return .failed("topo: the slot could not be written: \(error.localizedDescription)\n")
        }
        await changed([slot])
        var lines = ["set: \(slot), revision \(revision)"]
        lines += notes.map { "refused: \($0)" }
        lines += unchecked
        return ToolReply(status: notes.isEmpty ? ToolReply.ok : ToolReply.refused, text: lines.joined(separator: "\n") + "\n")
    }

    private func clear(_ slot: String?, _ store: SurfaceStore) async -> ToolReply {
        let slots = slot.map { [$0] } ?? store.slots()
        if let slot {
            if let refusal = Self.refusal(slot: slot) { return ToolReply(status: ToolReply.refused, text: "topo: \(refusal)\n") }
            guard store.slots().contains(slot) else { return .failed("topo: there is no slot \(slot)\n") }
        }
        do {
            for slot in slots { try store.remove(slot: slot) }
        } catch {
            return .failed("topo: \(error.localizedDescription)\n")
        }
        await changed(slots, cleared: true)
        return .ok(slots.isEmpty ? "no slots to clear\n" : "cleared: " + slots.joined(separator: ", ") + "\n")
    }

    /// One reload of the timelines, and each slot's record owed: a save, or a delete for a clear.
    private func changed(_ slots: [String], cleared: Bool = false) async {
        await MainActor.run {
            reloader().reload()
            for slot in slots { cleared ? sync().cleared(slot: slot) : sync().changed(slot: slot) }
        }
    }

    /// Why the mind may not write `slot`: `_default` is the app's, and no other name outside the
    /// pattern is one.
    static func refusal(slot: String) -> String? {
        WidgetDocument.isSlot(slot) ? nil : "\(slot) is not a slot: [a-z0-9-], at most 32 characters"
    }

    // MARK: Images

    struct ImageRefusal: Error { let text: String; init(_ text: String) { self.text = text } }

    private func image(slot: String, name: String, path: String, _ store: SurfaceStore) async -> ToolReply {
        func refused(_ why: String) -> ToolReply { ToolReply(status: ToolReply.refused, text: "topo: \(why); nothing was copied\n") }
        if let refusal = Self.refusal(slot: slot) { return refused(refusal) }
        guard WidgetDocument.isName(name) else { return refused("\(name) is not an image name: [a-z0-9-], at most 32 characters") }
        let existing = store.imageNames(slot: slot)
        guard existing.contains(name) || existing.count < WidgetDocument.imageLimit else {
            return refused("\(slot) holds \(WidgetDocument.imageLimit) images already")
        }
        let png: Data
        do {
            png = try Self.png(at: path, under: home())
        } catch let refusal as ImageRefusal {
            return refused(refusal.text)
        } catch {
            return refused(error.localizedDescription)
        }
        do {
            try store.writeImage(png, slot: slot, name: name)
        } catch {
            return .failed("topo: the image could not be written: \(error.localizedDescription)\n")
        }
        await changed([slot])
        return .ok("image: \(slot)/\(name)\n")
    }

    /// The image at the guest's `path`, re-encoded as PNG: read through a descriptor opened
    /// beneath `home` with no link followed anywhere along it, so a link in the guest's home can
    /// reach nothing outside it, and judged by its bytes, its type and its size before it is decoded.
    static func png(at path: String, under home: URL) throws -> Data {
        guard path == guestHome || path.hasPrefix(guestHome + "/") else {
            throw ImageRefusal("\(path) is not under \(guestHome)")
        }
        let parts = path.dropFirst(guestHome.count).split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { throw ImageRefusal("\(path) names no file") }
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { throw ImageRefusal("\(path) climbs with . or ..") }
        let base = open(home.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard base >= 0 else { throw ImageRefusal("the guest's home cannot be opened") }
        defer { close(base) }
        let file = openat(base, parts.joined(separator: "/"), O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard file >= 0 else {
            throw ImageRefusal(errno == ELOOP ? "\(path) goes through a link" : "\(path) cannot be opened: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw ImageRefusal("\(path) is not a file") }
        guard status.st_size <= imageBytes else {
            throw ImageRefusal("\(path) is \(status.st_size / 1024) KB, over the \(imageBytes / 1024) KB an image may be")
        }
        let data = try handle.read(upToCount: imageBytes + 1) ?? Data()
        guard data.count <= imageBytes else { throw ImageRefusal("\(path) is over the \(imageBytes / 1024) KB an image may be") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, imageTypes.contains(type) else {
            throw ImageRefusal("\(path) is not a PNG, JPEG or HEIC")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw ImageRefusal("\(path) holds no picture") }
        guard max(width, height) <= imagePixels else {
            throw ImageRefusal("\(path) is \(width)×\(height), over the \(imagePixels) px an image may be on its long side")
        }
        // Drawn upright: a camera's JPEG or HEIC stores its pixels as the sensor saw them and says
        // how to turn them (EXIF orientation), which a PNG has no field for, so the turn is made
        // here, at the image's own size.
        let upright: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, upright as CFDictionary) else {
            throw ImageRefusal("\(path) holds no picture")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageRefusal("\(path) could not be re-encoded")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageRefusal("\(path) could not be re-encoded") }
        return out as Data
    }

    // MARK: Placed widgets

    static func currentConfigurations() async -> [(family: String, slot: String?)] {
        let infos: [WidgetInfo] = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(returning: (try? $0.get()) ?? []) }
        }
        return infos.filter { $0.kind == SurfaceStore.kind }.map { info in
            (WidgetFamilyName(info.family).rawValue, info.widgetConfigurationIntent(of: SurfaceConfiguration.self)?.slot)
        }
    }

    // MARK: Example

    static let example = #"""
    {
      "version": 1,
      "tint": "surface",
      "families": {
        "systemMedium": {
          "kind": "vstack", "spacing": 6, "alignment": "leading",
          "children": [
            {"kind": "hstack", "spacing": 8, "children": [
              {"kind": "topo", "pose": "writing"},
              {"kind": "vstack", "alignment": "leading", "children": [
                {"kind": "text", "text": "Good morning", "style": "headline", "colour": "primary"},
                {"kind": "text", "text": "Updated", "date": "2030-06-15T12:00:00Z", "dateStyle": "relative", "style": "caption", "colour": "textMuted"}
              ]},
              {"kind": "spacer"},
              {"kind": "image", "name": "photo", "fit": "fill", "corner": 8}
            ]},
            {"kind": "divider"},
            {"kind": "hstack", "spacing": 8, "children": [
              {"kind": "zstack", "children": [
                {"kind": "glyph", "symbol": "circle.fill", "colour": "surface", "size": 24},
                {"kind": "glyph", "symbol": "sun.max.fill", "colour": "highlight", "size": 18}
              ]},
              {"kind": "gauge", "value": 18, "min": 0, "max": 30, "label": "°C", "style": "circularCapacity"},
              {"kind": "progress", "value": 0.4, "colour": "signal"}
            ]},
            {"kind": "hstack", "spacing": 8, "children": [
              {"kind": "button", "id": "hi", "label": [{"kind": "text", "text": "Say hi"}],
               "action": {"kind": "turn", "say": "hi from the widget"}},
              {"kind": "toggle", "id": "lamp", "on": false,
               "label": [{"kind": "glyph", "symbol": "lightbulb"}, {"kind": "text", "text": "Lamp"}],
               "action": {"kind": "run", "topo": ["home", "set", "ACCESSORY-ID", "power"]}},
              {"kind": "link", "id": "open", "label": [{"kind": "text", "text": "Open"}], "action": {"kind": "open"}}
            ]}
          ]
        },
        "accessoryRectangular": {
          "kind": "vstack", "alignment": "leading", "children": [
            {"kind": "text", "text": "Topo", "style": "headline"},
            {"kind": "text", "text": "Nothing private here", "style": "caption"}
          ]
        },
        "accessoryInline": {"kind": "hstack", "children": [
          {"kind": "glyph", "symbol": "sparkles"}, {"kind": "text", "text": "Topo"}
        ]}
      }
    }
    """#
}

extension WidgetDocument {
    /// Sets the action of the control `id` wherever it is drawn.
    mutating func setAction(_ action: WidgetAction, ofControl id: String) {
        for (family, node) in families { families[family] = node.settingAction(action, ofControl: id) }
    }
}

extension WidgetNode {
    func settingAction(_ action: WidgetAction, ofControl id: String) -> WidgetNode {
        switch self {
        case .stack(var stack):
            stack.children = stack.children.map { $0.settingAction(action, ofControl: id) }
            return .stack(stack)
        case .control(var control) where control.id == id:
            control.action = action
            return .control(control)
        default:
            return self
        }
    }
}

/// What a `run` action's call is judged against when it is set, the tap judging it again in full:
/// the allowlist, then the call's own tool's argument reader, and for `home` the homes HomeKit has
/// already loaded — never asking the person and never waiting. What cannot be judged without
/// asking is kept and marked unchecked.
struct WidgetRunJudge: Sendable {
    var home: HomeTool?
    var notify: NotifyTool?
    var reminders: RemindersTool?

    enum Verdict: Equatable, Sendable {
        case ok
        case unchecked(String)
        case refused(String)
    }

    /// A control's run, a toggle's in both of the forms a tap can give it; anything else is ok.
    func judge(_ control: WidgetControl) async -> Verdict {
        guard case .run = control.action else { return .ok }
        let forms = control.kind == .toggle ? [control.argv(turningOn: true), control.argv(turningOn: false)] : [control.argv()]
        var verdict = Verdict.ok
        for argv in forms.compactMap({ $0 }) {
            switch await judge(argv) {
            case .ok: break
            case .unchecked(let why): if verdict == .ok { verdict = .unchecked(why) }
            case .refused(let why): return .refused(why)
            }
        }
        return verdict
    }

    func judge(_ argv: [String]) async -> Verdict {
        if let refusal = WidgetAction.refusal(argv) { return .refused(refusal) }
        let rest = Array(argv.dropFirst())
        do {
            switch argv[0] {
            case "home":
                guard let home else { return .unchecked("home is judged at the tap") }
                let call = try home.parse(rest)
                guard let homes = await MainActor.run(body: { home.home.loadedHomes }) else {
                    return .unchecked("HomeKit has not loaded a home on this launch, so it is judged in full at the tap")
                }
                guard !homes.isEmpty else { return .refused("names a home, and no home is set up on this phone") }
                try HomeTool.judge(call, in: homes, refusing: HomeTool.widgetRefused)
            case "notify":
                guard let notify else { return .unchecked("notify is judged at the tap") }
                _ = try notify.parse(rest)
            case "reminders":
                guard let reminders else { return .unchecked("reminders is judged at the tap") }
                _ = try reminders.parse(rest)
            case "look":
                if let refusal = LookTool.refusal(rest) { return .refused(refusal) }
            default:
                break
            }
        } catch {
            return .refused(Self.describe(error))
        }
        return .ok
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as ToolFailure: failure.text
        case let misuse as Misuse: misuse.text
        case let refusal as Arguments.Refusal: refusal.description
        default: error.localizedDescription
        }
    }
}
