// PROBE: the host's Speech state, and a bounded attempt to install en-US on-device assets.
import Foundation
import Speech

func say(_ s: String) { print("[host-speech] \(s)"); fflush(stdout) }
let locale = Locale(identifier: "en-US")
say("authorizationStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
if let r = SFSpeechRecognizer(locale: locale) {
    say("SFSpeechRecognizer isAvailable=\(r.isAvailable) supportsOnDeviceRecognition=\(r.supportsOnDeviceRecognition)")
} else { say("SFSpeechRecognizer(en-US) is nil") }
let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
say("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
say("installedLocales=\(await SpeechTranscriber.installedLocales.map(\.identifier))")
say("status before=\(await AssetInventory.status(forModules: [transcriber]))")
if CommandLine.arguments.contains("--install") {
    do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let p = request.progress
            let watcher = Task { for _ in 0..<120 { say("progress \(p.completedUnitCount)/\(p.totalUnitCount)"); try? await Task.sleep(for: .seconds(5)) } }
            try await request.downloadAndInstall()
            watcher.cancel()
            say("downloadAndInstall finished")
        } else { say("assetInstallationRequest: nil") }
    } catch { say("install error: \(error)") }
    say("status after=\(await AssetInventory.status(forModules: [transcriber]))")
    say("installedLocales after=\(await SpeechTranscriber.installedLocales.map(\.identifier))")
}
