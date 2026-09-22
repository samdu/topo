import XCTest

@testable import Topo

/// The app links the GPL iSH fork, whose holders' App Store waiver stands only while the app
/// carries the GPL's text and says where its source is.
final class LicenceTests: XCTestCase {
    /// The hosting app's own bundle: what ships, not a copy put into the test bundle.
    func testTheAppCarriesTheGPLText() throws {
        let licence = Licence.bundled(in: .main)
        let text = try XCTUnwrap(licence.text, "LICENSE is not in the app's bundle")
        XCTAssertTrue(text.contains("GNU GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(text.contains("Version 3, 29 June 2007"))
    }

    func testTheSourceLineNamesTheRepositoryAtTheBuildsCommit() {
        let commit = String(repeating: "a", count: 40)
        let source = Licence(text: nil, commit: commit).source
        XCTAssertTrue(source.contains("https://github.com/samdu/topo, at commit \(commit)"), source)
        XCTAssertTrue(source.contains("iSH fork"), source)
    }

    func testABuildWithNoCommitStillSaysWhereTheSourceIs() {
        let source = Licence(text: nil, commit: "").source
        XCTAssertTrue(source.contains("https://github.com/samdu/topo, at the commit this build was made from"), source)
    }
}
