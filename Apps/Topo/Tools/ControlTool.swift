import Foundation
import TopoTools

/// `topo control`: the mind's hand on the person's controls — the Topo Button and Topo Toggle
/// they placed in Control Center, on the lock screen or on the Action button. It writes a slot's
/// document into the app group, judged by `ControlDocument.read` and, for a `run`, by
/// `WidgetRunJudge`; sets a toggle's drawn state; puts slots back to their defaults; keeps the
/// secrets a `request` names; and shows what was tapped. Every write asks `SurfaceReloader` for one
/// reload of its kind's controls.
struct ControlTool: Tool {
    let judge: WidgetRunJudge
    var store: @Sendable () -> SurfaceStore? = { SurfaceStore.shared() }
    var reloader: @MainActor @Sendable () -> SurfaceReloader = { .shared }
    var secrets = ControlSecrets()
    /// A clear of the control secrets the keychain refused at a sign-out, which refuses a new one
    /// until the app has cleared them (it tries again at each launch).
    var leftBehind = ConnectionsLeftBehind()
    /// A toggle's state set by the mind, told to the runs in flight (`WidgetActions.confirm`).
    var confirm: @MainActor @Sendable (_ on: Bool, _ slot: String, _ revision: Int) -> Void = { on, slot, revision in
        (WidgetIntents.handler as? WidgetTaps)?.actions.confirm(on, slot: ControlSlot.stored(slot), control: ControlSlot.control,
                                                                revision: revision)
    }
    /// A request's URL on the home network, set: local network access asked for its host while the
    /// app is in front (`LocalNetworkAccess`).
    var askLocal: @MainActor @Sendable (URL) -> Void = { LocalNetworkAccess.shared.ask(for: $0) }
    var localState: @MainActor @Sendable () -> LocalNetworkAccess.State = { LocalNetworkAccess.shared.state }

    let name = "control"
    let summary = "the person's Control Center, lock-screen and Action-button controls: what each does, its state, what was tapped"
    var usage: String {
        """
        topo control                             every slot: written or the default, its title, state and action, and
                                                 what the reader said of it; the secrets' names; local network access
        topo control set SLOT JSON               write a slot's document (status 6 with the notes when part of it was
                                                 refused and the rest kept, 2 when none of it could be read)
        topo control state TOGGLE on|off         set a toggle's drawn state to match the world, and nothing else
        topo control clear [SLOT]                a slot, or all twelve, back to its default
        topo control secret set NAME VALUE       keep a credential a request names as ${secret:NAME}, in this phone's
                                                 keychain; the value is never shown again
        topo control secret clear NAME           remove one
        topo control taps [SLOT]                 the controls' last taps: time, slot, revision, kind, status, HTTP code
        topo control example [button|toggle]     a document of that kind; both without one

        Slots: \(ControlSlot.names(.button).joined(separator: ", ")) (a Topo Button) and
        \(ControlSlot.names(.toggle).joined(separator: ", ")) (a Topo Toggle). The person places a Topo Button
        or Topo Toggle from the controls gallery and picks its slot there ("Button 1" is button-1); which
        slots are placed, and where, is not known here. A slot never written taps as "control SLOT: tapped, not set".
        Fields: title (\(ControlDocument.titleLimit)), symbol (an SF Symbol), tint (a colour name, a #hex, or [light, dark]),
        hint (\(ControlDocument.hintLimit), what the Action button says); a button's subtitle (\(ControlDocument.subtitleLimit)); a toggle's
        on, onText and offText (\(ControlDocument.stateTextLimit)), onSymbol and offSymbol. \(ControlDocument.byteLimit / 1024) KB a document.
        Actions: {"kind": "turn", "say": "…"} sends you "control SLOT: …" and opens Topo; {"kind": "open"};
        {"kind": "run", "topo": [...]} runs one topo call with no turn and nothing opened, one of:
        \(WidgetAction.allowed.map { "topo " + $0.joined(separator: " ") }.joined(separator: ", ")); a toggle's gets on or off appended;
        {"kind": "request", "method": "POST", "url": "…", "headers": {…}, "body": "…"} makes one HTTP request to
        any URL, with no turn and nothing opened: GET without a body, POST with one; a toggle's is
        {"kind": "request", "on": {…}, "off": {…}}. A request is answered within \(Int(ControlRequest.deadline.components.seconds)) s, follows no redirect and
        is never retried by Topo, but a GET may reach the server up to three times when the connection
        drops, so an effect that must not happen twice is a POST. The whole value of Authorization,
        Cookie, Proxy-Authorization, X-Api-Key, X-Auth-Token and Api-Key is one ${secret:NAME} and nothing
        else, the secret holding all of it (topo control secret set ha 'Bearer <token>'); any other
        header or the body may name one among other text. A URL carries no user or password.
        A request to the home network needs local network access, asked for when Topo is in front.
        Limits: a control shows what the system last read of it, and the system decides when it reads again.
        A press on the lock screen or the Action button needs no Face ID. On iOS 18 to 25 a turn or open
        control cannot bring Topo forward; its turn is still sent.
        """
    }

    func run(_ arguments: [String]) async -> ToolReply {
        switch (arguments.first, arguments.count) {
        case ("example", 1): return .ok(Self.example(nil) + "\n")
        case ("example", 2):
            guard let kind = ControlSlot.Kind(rawValue: arguments[1]) else { return .usage("topo: example takes button or toggle\n") }
            return .ok(Self.example(kind) + "\n")
        case ("secret", 4) where arguments[1] == "set": return setSecret(arguments[2], arguments[3])
        case ("secret", 3) where arguments[1] == "clear": return clearSecret(arguments[2])
        default: break
        }
        guard let store = store() else {
            return .failed("topo: this build has no app group, so it has no controls\n")
        }
        switch (arguments.first, arguments.count) {
        case (nil, _): return .ok(await list(store))
        case ("set", 3): return await set(arguments[1], arguments[2], store)
        case ("state", 3): return await state(arguments[1], arguments[2], store)
        case ("clear", 1), ("clear", 2): return await clear(arguments.count == 2 ? arguments[1] : nil, store)
        case ("taps", 1), ("taps", 2): return taps(arguments.count == 2 ? arguments[1] : nil, store)
        default:
            return .usage("topo: control takes nothing, set, state, clear, secret, taps or example\n\n\(usage)\n")
        }
    }

    static func refusal(slot: String) -> String? {
        ControlSlot.kind(of: slot) == nil ? "\(slot) is not a control slot: button-1 to button-6, toggle-1 to toggle-6" : nil
    }

    // MARK: Reading

    private func list(_ store: SurfaceStore) async -> String {
        var lines: [String] = []
        for slot in ControlSlot.all {
            guard let reading = store.readControl(slot: slot), reading.readable else {
                lines.append("\(slot): nothing kept; it draws Sign in")
                continue
            }
            let document = reading.document
            var head = [slot + ":", document.isDefault ? "default" : "written", "revision \(document.revision)", "\"\(document.title)\""]
            if document.kind == .toggle { head.append(document.on ? "on" : "off") }
            lines.append(head.joined(separator: " ") + ", " + Self.describe(document.action, kind: document.kind))
            for note in store.notes(slot: ControlSlot.stored(slot)) { lines.append("  " + note) }
        }
        if let words = leftBehind.controlSecrets {
            lines.append("secrets: not used: at an earlier sign-out \(words); the app tries again at each launch")
        } else {
            let names = (try? secrets.names()).map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "the keychain could not be read"
            lines.append("secrets: " + names)
        }
        lines.append("local network: " + (await MainActor.run { localState() }).rawValue)
        return lines.joined(separator: "\n") + "\n"
    }

    /// An action as the listing shows it: a request's method, scheme, host and path and its
    /// headers' names, never a value, the query or the body.
    static func describe(_ action: ControlAction, kind: ControlSlot.Kind) -> String {
        switch action {
        case .turn(let say): say.map { "turn \"\($0)\"" } ?? "turn"
        case .open: "open"
        case .run(let argv): "run topo " + argv.joined(separator: " ") + (kind == .toggle ? " on|off" : "")
        case .request(.one(let form)): "request " + describe(form)
        case .request(.toggle(let on, let off)): "request on: " + describe(on) + "; off: " + describe(off)
        }
    }

    static func describe(_ form: ControlRequest.Form) -> String {
        var where_ = form.url
        if let url = URL(string: form.url), let scheme = url.scheme, let host = url.host() {
            where_ = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "") + url.path()
        }
        var text = "\(form.method) \(where_)"
        if !form.headers.isEmpty { text += " headers " + form.headers.map(\.name).joined(separator: ", ") }
        if form.body != nil { text += " with a body" }
        return text
    }

    private func taps(_ slot: String?, _ store: SurfaceStore) -> ToolReply {
        if let slot, let refusal = Self.refusal(slot: slot) { return ToolReply(status: ToolReply.refused, text: "topo: \(refusal)\n") }
        let taps = store.taps().filter { tap in
            guard let control = ControlSlot.slot(stored: tap.slot) else { return false }
            return slot == nil || control == slot
        }
        let lines = taps.map { tap in
            PhoneTool.line([ToolDates.write(tap.time), ControlSlot.slot(stored: tap.slot) ?? tap.slot, "revision \(tap.revision)",
                            tap.kind, tap.status] + (tap.code.map { ["HTTP \($0)"] } ?? []))
        }
        return .ok(PhoneTool.lines(lines, none: "no taps"))
    }

    // MARK: Writing

    private func set(_ slot: String, _ text: String, _ store: SurfaceStore) async -> ToolReply {
        if let refusal = Self.refusal(slot: slot) { return ToolReply(status: ToolReply.refused, text: "topo: \(refusal)\n") }
        let reading = ControlDocument.read(text, slot: slot)
        if case .unreadable(let why) = reading.state { return .usage("topo: the document \(why); nothing was written\n") }
        var document = reading.document
        var notes = reading.notes
        var unchecked: [String] = []
        if case .run(let argv) = document.action {
            // A toggle's in both of the forms a tap can give it: a refusal of either refuses the run.
            var verdict = WidgetRunJudge.Verdict.ok
            for form in document.kind == .toggle ? [argv + ["on"], argv + ["off"]] : [argv] {
                let next = await judge.judge(form)
                if case .refused = next { verdict = next; break }
                if verdict == .ok { verdict = next }
            }
            switch verdict {
            case .ok: break
            case .unchecked(let why): unchecked.append("unchecked: \(why)")
            case .refused(let why):
                notes.append("action.topo " + why + ControlReader.refused)
                document.action = ControlDocument.standard(slot: slot).action
            }
        }
        let revision: Int
        do {
            revision = try store.writeControl(document, slot: slot)
            try store.writeNotes(notes + unchecked, slot: ControlSlot.stored(slot))
        } catch {
            return .failed("topo: the slot could not be written: \(error.localizedDescription)\n")
        }
        let urls: [URL]
        switch document.action {
        case .request(.one(let form)): urls = [form.url].compactMap(URL.init(string:))
        case .request(.toggle(let on, let off)): urls = [on.url, off.url].compactMap(URL.init(string:))
        default: urls = []
        }
        await MainActor.run {
            reloader().reloadControls(kind: document.kind.controlKind)
            urls.filter(LocalNetworkAccess.mayBeLocal).forEach(askLocal)
        }
        var lines = ["set: \(slot), revision \(revision)"]
        lines += notes.map { "refused: \($0)" }
        lines += unchecked
        return ToolReply(status: notes.isEmpty ? ToolReply.ok : ToolReply.refused, text: lines.joined(separator: "\n") + "\n")
    }

    private func state(_ slot: String, _ word: String, _ store: SurfaceStore) async -> ToolReply {
        guard ControlSlot.kind(of: slot) == .toggle else {
            return ToolReply(status: ToolReply.refused, text: "topo: \(slot) is not a toggle slot: toggle-1 to toggle-6\n")
        }
        guard ["on", "off"].contains(word) else { return .usage("topo: state takes on or off\n") }
        guard let reading = store.readControl(slot: slot), reading.readable else {
            return .failed("topo: \(slot) holds nothing to set; sign in first\n")
        }
        let on = word == "on"
        let revision = reading.document.revision
        do {
            guard try store.setControl(on, slot: slot, revision: revision) != nil else {
                return .failed("topo: \(slot) was written again meanwhile; nothing was set\n")
            }
        } catch {
            return .failed("topo: \(error.localizedDescription)\n")
        }
        await MainActor.run {
            confirm(on, slot, revision)
            reloader().reloadControls(kind: ControlSlot.Kind.toggle.controlKind)
        }
        return .ok("state: \(slot) \(word)\n")
    }

    private func clear(_ slot: String?, _ store: SurfaceStore) async -> ToolReply {
        if let slot, let refusal = Self.refusal(slot: slot) { return ToolReply(status: ToolReply.refused, text: "topo: \(refusal)\n") }
        let slots = slot.map { [$0] } ?? ControlSlot.all
        do {
            for slot in slots { try ControlDefaults.write(slot: slot, store: store) }
        } catch {
            return .failed("topo: \(error.localizedDescription)\n")
        }
        let kinds = Set(slots.compactMap(ControlSlot.kind(of:)))
        await MainActor.run { kinds.forEach { reloader().reloadControls(kind: $0.controlKind) } }
        return .ok("cleared: " + slots.joined(separator: ", ") + "\n")
    }

    // MARK: Secrets

    private func setSecret(_ name: String, _ value: String) -> ToolReply {
        guard ControlSecrets.isName(name) else {
            return ToolReply(status: ToolReply.refused, text: "topo: \(name) is not a secret's name: [A-Za-z0-9_.-], at most 64\n")
        }
        guard !value.isEmpty else { return .usage("topo: a secret's value is not empty\n") }
        if let words = leftBehind.controlSecrets {
            return .failed("topo: no secret is kept: at an earlier sign-out \(words). The app tries again at each launch.\n")
        }
        do {
            try secrets.set(value, name: name)
        } catch {
            return .failed("topo: the keychain did not keep it\n")
        }
        return .ok("secret set: \(name)\n")
    }

    private func clearSecret(_ name: String) -> ToolReply {
        guard ControlSecrets.isName(name) else {
            return ToolReply(status: ToolReply.refused, text: "topo: \(name) is not a secret's name: [A-Za-z0-9_.-], at most 64\n")
        }
        do {
            try secrets.clear(name)
        } catch {
            return .failed("topo: the keychain did not remove it\n")
        }
        return .ok("secret cleared: \(name)\n")
    }

    // MARK: Example

    static func example(_ kind: ControlSlot.Kind?) -> String {
        switch kind {
        case .button: button
        case .toggle: toggle
        case nil: "button-1:\n" + button + "\ntoggle-1:\n" + toggle
        }
    }

    static let button = #"""
    {"title": "Feed Daphne", "subtitle": "one treat", "symbol": "pawprint.fill", "tint": "primary", "hint": "Treat",
     "action": {"kind": "run", "topo": ["home", "scene", "SCENE-ID"]}}
    """#

    static let toggle = #"""
    {"title": "Kitchen", "onText": "Playing", "offText": "Quiet", "onSymbol": "speaker.wave.2.fill", "offSymbol": "speaker.slash",
     "on": false, "hint": "Music",
     "action": {"kind": "request",
                "on": {"url": "http://192.168.1.214/api/services/media_player/media_play",
                       "headers": {"Authorization": "${secret:ha}", "Content-Type": "application/json"},
                       "body": "{\"entity_id\": \"media_player.kitchen\"}"},
                "off": {"url": "http://192.168.1.214/api/services/media_player/media_pause",
                        "headers": {"Authorization": "${secret:ha}", "Content-Type": "application/json"},
                        "body": "{\"entity_id\": \"media_player.kitchen\"}"}}}
    """#
}
