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

    /// What the review found the converter getting wrong, each on a page of its own shape:
    /// availability that says unavailable or deprecated with no version, the source URL when the
    /// page has no `variants`, Relationships (Apple's key is `relationshipsSections`), a code
    /// listing's own blank lines kept, and an ordered list that starts past 1.
    func testTheConverterKeepsWhatThePageSays() throws {
        let page = #"""
        {"schemaVersion":{"major":0,"minor":3,"patch":0},
         "identifier":{"url":"doc://com.apple.uikit/documentation/UIKit/UIView","interfaceLanguage":"swift"},
         "metadata":{"title":"UIView","roleHeading":"Class","platforms":[
           {"name":"iOS","introducedAt":"2.0"},
           {"name":"visionOS","unavailable":true},
           {"name":"tvOS","deprecated":true}]},
         "abstract":[{"type":"text","text":"An object that manages the content for a rectangular area."}],
         "primaryContentSections":[{"kind":"content","content":[
           {"type":"codeListing","syntax":"swift","code":["let s = \"\"\"","a","","","b","\"\"\""]},
           {"type":"orderedList","start":4,"items":[
             {"content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"Continue from step 3."}]}]},
             {"content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"Then this."}]}]}]}
         ]}],
         "relationshipsSections":[{"title":"Inherits From","identifiers":["doc://com.apple.uikit/documentation/UIKit/UIResponder"]}],
         "references":{
           "doc://com.apple.uikit/documentation/UIKit/UIResponder":{"title":"UIResponder","url":"/documentation/uikit/uiresponder","kind":"symbol","role":"symbol","type":"topic"}
         }}
        """#
        let markdown = try convert(page)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(4)), [
            "# UIView",
            "*Class*",
            "Availability: iOS 2.0 · visionOS, unavailable · tvOS, deprecated",
            "Source: https://developer.apple.com/documentation/uikit/uiview",
        ], markdown)
        XCTAssertTrue(markdown.contains("\nAn object that manages the content for a rectangular area.\n"), "the abstract: " + markdown)
        XCTAssertTrue(markdown.contains("```swift\nlet s = \"\"\"\na\n\n\nb\n\"\"\"\n```"), "a listing's two blank lines stay two: " + markdown)
        XCTAssertFalse(markdown.contains("\n\n\n\n"), "between blocks, one blank line: " + markdown)
        XCTAssertTrue(markdown.contains("4. Continue from step 3.\n\n5. Then this."), markdown)
        XCTAssertTrue(markdown.contains("## Relationships\n\n### Inherits From\n\n- [`UIResponder`](https://developer.apple.com/documentation/uikit/uiresponder)"), markdown)
        XCTAssertFalse(markdown.contains("\u{1}"), "the listing's mark is taken off")
    }

    /// What the converter has no rendering for is one line naming it, never nothing: a block
    /// (the made-up page's), a section (the REST page's parameters and responses), an inline run.
    func testWhatItCannotRenderIsMarked() throws {
        let shapes = try convert(page("shapes"))
        XCTAssertTrue(shapes.contains("\n[apple-doc: unrendered mysteryBlock block]"), shapes)
        let rest = try convert(page("get-v1-apps"))
        XCTAssertTrue(rest.contains("\n[apple-doc: unrendered restParameters section]\n"), rest)
        XCTAssertTrue(rest.contains("\n[apple-doc: unrendered restResponses section]\n"), rest)
        let inline = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"content","content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"a "},{"type":"sparkle"}]}]}]}"#)
        XCTAssertTrue(inline.contains("\na [apple-doc: unrendered sparkle inline]\n"), inline)
        let holding = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"content","content":[{"type":"mysteryBox","content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"inside"}]}]},{"type":"mysteryLine","inlineContent":[{"type":"text","text":"said"}]},{"type":"paragraph","inlineContent":[{"type":"glitter","inlineContent":[{"type":"text","text":"shone"}]}]},{"type":"emptyBox","content":[]}]}]}"#)
        XCTAssertTrue(holding.contains("\n[apple-doc: unrendered mysteryBox block]\ninside\n"), "an unknown block's children stay, under its mark: " + holding)
        XCTAssertTrue(holding.contains("\n[apple-doc: unrendered mysteryLine block]\nsaid\n"), holding)
        XCTAssertTrue(holding.contains("\n[apple-doc: unrendered glitter inline] shone\n"), holding)
        XCTAssertTrue(holding.contains("\n[apple-doc: unrendered emptyBox block]\n"), "an empty one is marked too: " + holding)
    }

    /// The pages that mention this one, linked with their abstracts, as the page lists them.
    func testTheMentionsAreKept() throws {
        let markdown = try convert(page("get-v1-apps"))
        XCTAssertTrue(markdown.contains("""
        ## Mentioned in

        - [Creating alternative distribution packages](https://developer.apple.com/documentation/appstoreconnectapi/creating-alternative-distribution-packages): Create distribution packages for your apps that you distribute on alternative marketplaces or on the web.
        - [App Store Connect API 3.6 release notes](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-3-6-release-notes)
        """), markdown)
    }

    /// A deprecated symbol's summary of what to use instead, under the abstract.
    func testTheDeprecationSummaryIsKept() throws {
        let markdown = try convert(page("requestrecordpermission"))
        XCTAssertTrue(markdown.contains("""
        Requests the user’s permission to record audio.

        > **Deprecated**
        > Use [`requestRecordPermission(completionHandler:)`](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)) on [`AVAudioApplication`](https://developer.apple.com/documentation/avfaudio/avaudioapplication) instead.

        """), markdown)
    }

    /// A REST page's method and URL.
    func testTheRESTEndpointIsKept() throws {
        let markdown = try convert(page("get-v1-apps"))
        XCTAssertTrue(markdown.contains("## URL\n\n```\nGET https://api.appstoreconnect.apple.com/v1/apps\n```\n"), markdown)
    }

    /// The sections come in the page's own order: this one's Parameters before its Discussion.
    func testTheSectionsKeepThePagesOrder() throws {
        let markdown = try convert(page("requestrecordpermission"))
        let parameters = try XCTUnwrap(markdown.range(of: "\n## Parameters\n"), markdown)
        let discussion = try XCTUnwrap(markdown.range(of: "\n## Discussion\n"), markdown)
        XCTAssertLessThan(parameters.lowerBound, discussion.lowerBound, markdown)
    }

    /// A parameter, an aside or a term's definition of more than one block keeps them as blocks,
    /// hung under the item: a second paragraph stays a paragraph and a code listing stays fenced.
    func testBlocksInsideAnItemStayBlocks() throws {
        let shapes = try convert(page("shapes"))
        XCTAssertTrue(shapes.contains("- **p**: First para.\n\n  ```swift\n  let a = 1\n  let b = 2\n  ```\n"), shapes)
        XCTAssertTrue(shapes.contains("> **Warning**\n> Para one.\n>\n> Para two.\n"), shapes)
        XCTAssertTrue(shapes.contains("- **Key**: Def one.\n\n  Def two.\n"), shapes)
        let led = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"parameters","parameters":[{"name":"p","content":[{"type":"heading","level":2,"text":"Heading"},{"type":"paragraph","inlineContent":[{"type":"text","text":"Body"}]}]}]},{"kind":"possibleValues","title":"Accepted Modes","values":[{"name":"audio","content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"Plays."}]},{"type":"codeListing","syntax":"xml","code":["<string>audio</string>"]}]},{"name":"fetch","content":[]}]}]}"#)
        XCTAssertTrue(led.contains("- **p**:\n  ## Heading\n\n  Body\n"), "a lead that is not a paragraph keeps its own line: " + led)
        XCTAssertTrue(led.contains("## Accepted Modes\n\n- `audio`: Plays.\n\n  ```xml\n  <string>audio</string>\n  ```\n- `fetch`\n"), "the section's own title, and a value's blocks: " + led)
        let real = try convert(page("requestrecordpermission"))
        XCTAssertTrue(real.contains("indicating whether the user granted or denied permission to record.\n\n  When you call this method,"), real)
    }

    /// A table's first row is its header only when DocC says the table has a header row.
    func testATableWithoutAHeaderRowKeepsItsFirstRowAsData() throws {
        let shapes = try convert(page("shapes"))
        XCTAssertTrue(shapes.contains("|  |  |\n|---|---|\n| r1c1 | r1c2 |\n| r2c1 | r2c2 |\n"), shapes)
        let headed = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"content","content":[{"type":"table","header":"row","rows":[[[{"type":"paragraph","inlineContent":[{"type":"text","text":"h"}]}]],[[{"type":"paragraph","inlineContent":[{"type":"text","text":"d"}]}]]]}]}]}"#)
        XCTAssertTrue(headed.contains("| h |\n|---|\n| d |"), headed)
        let both = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"content","content":[{"type":"table","header":"both","rows":[[[{"type":"paragraph","inlineContent":[{"type":"text","text":"h"}]}]],[[{"type":"paragraph","inlineContent":[{"type":"text","text":"d"}]}]]]}]}]}"#)
        XCTAssertTrue(both.contains("| h |\n|---|\n| d |"), "a header row and column: the row is the header: " + both)
    }

    /// A thematic break is a rule.
    func testAThematicBreakIsARule() throws {
        let markdown = try convert(#"{"metadata":{"title":"T"},"primaryContentSections":[{"kind":"content","content":[{"type":"paragraph","inlineContent":[{"type":"text","text":"above"}]},{"type":"thematicBreak"},{"type":"paragraph","inlineContent":[{"type":"text","text":"below"}]}]}]}"#)
        XCTAssertTrue(markdown.contains("above\n\n---\n\nbelow"), markdown)
    }

    /// The command itself, through the link it is run by, over a `wget` that records what it was
    /// asked for: a URL with a fragment or a query asks for the page's JSON, a page that is not
    /// there is Apple's 404 and status 1, and what is printed is the converter's Markdown.
    func testTheCommandAsksForThePagesJSONHoweverItIsNamed() throws {
        let home = try scratch()
        let script = home.appendingPathComponent(GuestTools.appleDocPath)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(GuestTools.appleDoc.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data(GuestTools.doccToMarkdown.utf8).write(to: home.appendingPathComponent(GuestTools.doccToMarkdownPath))
        let bin = home.appendingPathComponent("usr-local-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("apple-doc"), withDestinationURL: script)
        let fixture = home.appendingPathComponent("fixture.json")
        try Data(#"{"schemaVersion":{"major":0},"metadata":{"title":"Background Tasks"},"variants":[{"paths":["/documentation/backgroundtasks"]}]}"#.utf8).write(to: fixture)
        let asked = home.appendingPathComponent("asked")
        let fake = home.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let wget = fake.appendingPathComponent("wget")
        try Data("""
        #!/bin/bash
        out=; url=
        while [ $# -gt 0 ]; do case "$1" in -O) out=$2; shift 2;; -q) shift;; -T) shift 2;; *) url=$1; shift;; esac; done
        echo "$url" >> "\(asked.path)"
        case "$url" in *nonsense*) echo "wget: server returned error: HTTP/1.1 404 Not Found" >&2; exit 1;; esac
        cp "\(fixture.path)" "$out"
        """.utf8).write(to: wget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wget.path)
        let path = [fake.path, URL(fileURLWithPath: try jq()).deletingLastPathComponent().path, "/usr/bin", "/bin"].joined(separator: ":")
        func run(_ argument: String) throws -> (status: Int32, out: String, err: String) {
            try self.run(bin.appendingPathComponent("apple-doc").path, [argument], environment: ["PATH": path])
        }

        for name in ["https://developer.apple.com/documentation/backgroundtasks#overview",
                     "https://developer.apple.com/documentation/backgroundtasks?language=objc",
                     "backgroundtasks/"] {
            let result = try run(name)
            XCTAssertEqual(result.status, 0, name + ": " + result.err)
            XCTAssertTrue(result.out.hasPrefix("# Background Tasks\n"), name + ": " + result.out)
        }
        let urls = try String(contentsOf: asked, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(urls, Array(repeating: "https://developer.apple.com/tutorials/data/documentation/backgroundtasks.json", count: 3))

        let missing = try run("nonsense/page")
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.err, "apple-doc: server returned error: HTTP/1.1 404 Not Found: https://developer.apple.com/tutorials/data/documentation/nonsense/page.json\n")
    }

    private func jq() throws -> String {
        let jq = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let jq else { throw XCTSkip("no jq on this Mac") }
        return jq
    }

    private func scratch() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("docc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".topo", isDirectory: true), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// One of the pages under `Pages`, as its JSON.
    private func page(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Pages"), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func convert(_ page: String) throws -> String {
        let home = try scratch()
        let program = home.appendingPathComponent("docc2md.jq")
        try Data(GuestTools.doccToMarkdown.utf8).write(to: program)
        let file = home.appendingPathComponent("page.json")
        try Data(page.utf8).write(to: file)
        let result = try run(try jq(), ["-r", "-f", program.path, file.path])
        XCTAssertEqual(result.status, 0, result.err)
        return result.out
    }

    private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }
}
