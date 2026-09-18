import XCTest

@testable import Topo

#if DEBUG
/// What the probe makes of a picked folder. The picker offers On My iPhone and every installed
/// file provider beside iCloud Drive, so the judgement is the part that has to be right before a
/// bookmark is kept, and it is the part a simulator cannot show: there is no iCloud Drive there
/// and a URL's own `isUbiquitousItemKey` is always no, so the ubiquity answer is injected and the
/// paths are the ones the phone hands over.
@MainActor
final class VaultProbeTests: XCTestCase {
    private let mobileDocuments = "/private/var/mobile/Library/Mobile Documents"

    private func folder(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func judge(_ path: String, ubiquitous: Bool) -> Result<VaultProbe.Pick, VaultProbe.Refusal> {
        VaultProbe.judge(folder(path), isUbiquitous: { _ in ubiquitous })
    }

    func testAVaultFolderInObsidiansContainerIsAccepted() {
        let result = judge("\(mobileDocuments)/iCloud~md~obsidian/Documents/Memory", ubiquitous: true)
        XCTAssertEqual(try? result.get(), .obsidianVault("Memory"))
    }

    func testICloudDrivesRootIsAccepted() {
        let result = judge("\(mobileDocuments)/com~apple~CloudDocs", ubiquitous: true)
        XCTAssertEqual(try? result.get(), .iCloudDriveRoot)
    }

    func testAFolderOnThisPhoneIsRefused() {
        // On My iPhone › Topo, which is where the vault is today: a real folder, and one nothing
        // off this device would ever see.
        let result = judge("/private/var/mobile/Containers/Data/Application/"
                           + "6C0F1F0A-0000-4000-8000-000000000000/Documents/Vault", ubiquitous: false)
        XCTAssertEqual(result.failure, .notInICloudDrive)
    }

    func testAThirdPartyProvidersFolderIsRefused() {
        // Dropbox and its like are offered by the same picker and are not ubiquitous items.
        let result = judge("/private/var/mobile/Library/CloudStorage/Dropbox/Notes", ubiquitous: false)
        XCTAssertEqual(result.failure, .notInICloudDrive)
    }

    func testAFolderInICloudDriveThatObsidianCannotOpenIsRefused() {
        // In iCloud Drive, and Obsidian opens a vault only inside its own container, so the
        // ubiquity check alone is not the judgement.
        let result = judge("\(mobileDocuments)/com~apple~CloudDocs/Notes", ubiquitous: true)
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testAFolderInsideAVaultIsRefused() {
        // One level under Obsidian's Documents is a vault; anything deeper is a folder in one.
        let result = judge("\(mobileDocuments)/iCloud~md~obsidian/Documents/Memory/notes",
                           ubiquitous: true)
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testObsidiansOwnDocumentsFolderIsRefused() {
        let result = judge("\(mobileDocuments)/iCloud~md~obsidian/Documents", ubiquitous: true)
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testAUbiquitousPathOutsideAnyContainerIsRefused() {
        let result = judge("/private/var/mobile/Library/Somewhere/Else", ubiquitous: true)
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testThePickerOpensAtObsidiansVaultsFolder() {
        let home = "/private/var/mobile/Containers/Data/Application/"
            + "6C0F1F0A-0000-4000-8000-000000000000"
        XCTAssertEqual(VaultProbe.obsidianDirectory(home: home)?.path,
                       "\(mobileDocuments)/iCloud~md~obsidian/Documents")
    }

    func testAHomeWithNoContainerGivesThePickerNoHint() {
        XCTAssertNil(VaultProbe.obsidianDirectory(home: "/Users/sam"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
#endif
