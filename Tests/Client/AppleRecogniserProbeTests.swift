import AVFoundation
import Speech
import XCTest

/// PROBE, not for merge: what Apple's on-device recogniser does in this simulator. Run after the
/// microphone UI test, which answers the speech permission prompt for the app this test is hosted by.
final class AppleRecogniserProbeTests: XCTestCase {
    static func say(_ line: String) { print("[apple-probe] \(line)") }

    @available(iOS 26.0, *)
    func testReportAppleRecogniserState() async throws {
        let say = Self.say
        let locale = Locale(identifier: "en-US")
        say("authorizationStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue) (3 = authorized)")
        let recognizer = try XCTUnwrap(SFSpeechRecognizer(locale: locale))
        say("isAvailable=\(recognizer.isAvailable) supportsOnDeviceRecognition=\(recognizer.supportsOnDeviceRecognition) locale=\(recognizer.locale.identifier)")

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        say("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
        say("SpeechTranscriber.supportedLocales has en-US: \(supported.contains { $0.hasPrefix("en") && $0.contains("US") })")
        say("SpeechTranscriber.installedLocales=\(await SpeechTranscriber.installedLocales.map(\.identifier))")
        say("AssetInventory.status before=\(await AssetInventory.status(forModules: [transcriber]))")

        await Self.recognise(recognizer, label: "before asset request")

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                say("asset request: total units \(request.progress.totalUnitCount)")
                try await request.downloadAndInstall()
                say("asset progress after: \(request.progress.completedUnitCount)/\(request.progress.totalUnitCount)")
                say("asset downloadAndInstall finished")
            } else {
                say("assetInstallationRequest: nil (nothing to install)")
            }
        } catch {
            say("assetInstallationRequest/downloadAndInstall error: \(error)")
        }
        say("AssetInventory.status after=\(await AssetInventory.status(forModules: [transcriber]))")
        say("SpeechTranscriber.installedLocales after=\(await SpeechTranscriber.installedLocales.map(\.identifier))")
        say("isAvailable=\(recognizer.isAvailable) supportsOnDeviceRecognition=\(recognizer.supportsOnDeviceRecognition) after")

        await Self.recognise(recognizer, label: "after asset request")
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        init(_ c: CheckedContinuation<String, Never>) { continuation = c }
        func finish(_ s: String) { lock.withLock { continuation?.resume(returning: s); continuation = nil } }
    }

    private static func recognise(_ recognizer: SFSpeechRecognizer, label: String) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            say("\(label): not authorised, recognition not attempted"); return
        }
        guard let url = Bundle(for: AppleRecogniserProbeTests.self).url(forResource: "purple-elephants", withExtension: "wav") else {
            say("\(label): fixture missing"); return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let outcome: String = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            nonisolated(unsafe) let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let error { let e = error as NSError; once.finish("error domain=\(e.domain) code=\(e.code) \(e)") }
                else if let result, result.isFinal { once.finish("final: \"\(result.bestTranscription.formattedString)\"") }
            }
            Task.detached { try? await Task.sleep(for: .seconds(90)); task.cancel(); once.finish("timeout after 90 s") }
        }
        say("\(label): SFSpeechRecognizer on-device on the fixture -> \(outcome)")
    }
}
