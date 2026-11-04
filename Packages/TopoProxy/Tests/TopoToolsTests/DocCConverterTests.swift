import Foundation
import TopoTools
import XCTest

/// `apple-doc`'s converter, run on the Mac with its own jq: `Process` exists only here, not in
/// the simulator the guest's script tests run in.
final class DocCConverterTests: XCTestCase {
    /// The converter, run with the host's own jq over a page in DocC's render shape: the title,
    /// role and availability lead, the declaration is a code block, a heading keeps DocC's own
    /// level, an inline reference resolves through the page's reference table to an absolute
    /// link, and a topic entry carries its abstract. Nothing is fetched.
    func testTheConverterRendersADocCPageAsMarkdown() throws {
        let jq = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let jq else { throw XCTSkip("no jq on this Mac") }
        let page = """
        {"schemaVersion":{"major":0,"minor":3,"patch":0},
         "identifier":{"url":"doc://com.apple.backgroundtasks/documentation/BackgroundTasks/BGAppRefreshTaskRequest","interfaceLanguage":"swift"},
         "variants":[{"paths":["/documentation/backgroundtasks/bgapprefreshtaskrequest"],"traits":[{"interfaceLanguage":"swift"}]}],
         "metadata":{"title":"BGAppRefreshTaskRequest","roleHeading":"Class","platforms":[{"name":"iOS","introducedAt":"13.0"},{"name":"watchOS","introducedAt":"9.0","deprecatedAt":"27.0"}]},
         "abstract":[{"type":"text","text":"A request to launch your app in the background to execute a short refresh task."}],
         "hierarchy":{"paths":[["doc://com.apple.backgroundtasks/documentation/BackgroundTasks"]]},
         "primaryContentSections":[
           {"kind":"declarations","declarations":[{"languages":["swift"],"tokens":[{"text":"class ","kind":"keyword"},{"text":"BGAppRefreshTaskRequest","kind":"identifier"}]}]},
           {"kind":"content","content":[
             {"type":"heading","level":2,"text":"Overview","anchor":"overview"},
             {"type":"paragraph","inlineContent":[{"type":"text","text":"Submit it with "},{"type":"reference","identifier":"doc://com.apple.backgroundtasks/documentation/BackgroundTasks/BGTaskScheduler/submit(_:)","isActive":true},{"type":"text","text":"."}]},
             {"type":"aside","style":"note","name":"Note","content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"Thirty seconds, when iOS chooses."}]}]},
             {"type":"unorderedList","items":[{"content":[{"type":"paragraph","inlineContent":[{"type":"codeVoice","code":"earliestBeginDate"},{"type":"text","text":" is a floor, not a time."}]}]}]}
           ]}],
         "topicSections":[{"title":"Initializing a refresh task request","identifiers":["doc://com.apple.backgroundtasks/documentation/BackgroundTasks/BGAppRefreshTaskRequest/init(identifier:)"]}],
         "references":{
           "doc://com.apple.backgroundtasks/documentation/BackgroundTasks":{"title":"Background Tasks","url":"/documentation/backgroundtasks","kind":"symbol","role":"collection","type":"topic"},
           "doc://com.apple.backgroundtasks/documentation/BackgroundTasks/BGTaskScheduler/submit(_:)":{"title":"submit(_:)","url":"/documentation/backgroundtasks/bgtaskscheduler/submit(_:)","kind":"symbol","role":"symbol","type":"topic"},
           "doc://com.apple.backgroundtasks/documentation/BackgroundTasks/BGAppRefreshTaskRequest/init(identifier:)":{"title":"init(identifier:)","url":"/documentation/backgroundtasks/bgapprefreshtaskrequest/init(identifier:)","kind":"symbol","role":"symbol","type":"topic","abstract":[{"type":"text","text":"Return a new refresh task request for the specified identifier."}]}
         }}
        """
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("docc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let program = home.appendingPathComponent("docc2md.jq")
        try Data(GuestTools.doccToMarkdown.utf8).write(to: program)
        let file = home.appendingPathComponent("page.json")
        try Data(page.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: jq)
        process.arguments = ["-r", "-f", program.path, file.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let markdown = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, errors)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(5)), [
            "# BGAppRefreshTaskRequest",
            "*Class*",
            "Background Tasks",
            "Availability: iOS 13.0 · watchOS 9.0, deprecated 27.0",
            "Source: https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtaskrequest",
        ], markdown)
        XCTAssertTrue(markdown.contains("```swift\nclass BGAppRefreshTaskRequest\n```"), markdown)
        XCTAssertTrue(markdown.contains("\n## Overview\n"), "DocC's level 2 stays level 2: " + markdown)
        XCTAssertTrue(markdown.contains("Submit it with [`submit(_:)`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:))."), markdown)
        XCTAssertTrue(markdown.contains("> **Note**\n> Thirty seconds, when iOS chooses."), markdown)
        XCTAssertTrue(markdown.contains("- `earliestBeginDate` is a floor, not a time."), markdown)
        XCTAssertTrue(markdown.contains("## Topics\n\n### Initializing a refresh task request\n\n- [`init(identifier:)`](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtaskrequest/init(identifier:)): Return a new refresh task request for the specified identifier."), markdown)
    }
}
