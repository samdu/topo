import XCTest

@testable import Topo

/// What the app makes of a picked folder. The picker offers On My iPhone and every installed file
/// provider beside iCloud Drive, so the judgement is the part that has to be right before a
/// bookmark is kept and before anything is copied, and it is the part a simulator cannot show:
/// there is no iCloud Drive there and a URL's own `isUbiquitousItemKey` is always no, so the
/// ubiquity answer and the ubiquity root are both injected and the paths are the ones the phone
/// hands over.
@MainActor
final class VaultHomeTests: XCTestCase {
    private let mobileDocuments = "/private/var/mobile/Library/Mobile Documents"
    private var root: URL { URL(fileURLWithPath: mobileDocuments, isDirectory: true) }

    private func folder(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func judge(_ path: String, ubiquitous: Bool = true) -> Result<VaultHome.Pick, VaultHome.Refusal> {
        VaultHome.judge(folder(path), ubiquityRoot: root, isUbiquitous: { _ in ubiquitous })
    }

    func testAVaultFolderInObsidiansContainerIsAccepted() {
        let result = judge("\(mobileDocuments)/iCloud~md~obsidian/Documents/Memory")
        XCTAssertEqual(try? result.get(), .obsidianVault("Memory"))
    }

    func testICloudDrivesRootIsAccepted() {
        XCTAssertEqual(try? judge("\(mobileDocuments)/com~apple~CloudDocs").get(), .iCloudDriveRoot)
    }

    func testAFolderOnThisPhoneIsRefused() {
        // On My iPhone › Topo, which is where the vault is until the person moves it: a real
        // folder, and one nothing off this device would ever see.
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
        let result = judge("\(mobileDocuments)/com~apple~CloudDocs/Notes")
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testAFolderInsideAVaultIsRefused() {
        // One level under Obsidian's Documents is a vault; anything deeper is a folder in one.
        let result = judge("\(mobileDocuments)/iCloud~md~obsidian/Documents/Memory/notes")
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testObsidiansOwnDocumentsFolderIsRefused() {
        XCTAssertEqual(judge("\(mobileDocuments)/iCloud~md~obsidian/Documents").failure, .notAVaultFolder)
    }

    /// The judgement is against the one ubiquity root this device has, not against a path
    /// component of that name. A person can make a folder called `Mobile Documents` in iCloud
    /// Drive and put anything under it, and what is under it is theirs, not a container.
    func testAFolderNamedMobileDocumentsInsideICloudDriveIsNotAContainer() {
        let result = judge("\(mobileDocuments)/com~apple~CloudDocs/Mobile Documents/"
                           + "iCloud~md~obsidian/Documents/Memory")
        XCTAssertEqual(result.failure, .notAVaultFolder)
    }

    func testAPathOutsideTheUbiquityRootIsRefused() {
        XCTAssertEqual(judge("/private/var/mobile/Library/Somewhere/Else").failure, .notAVaultFolder)
    }

    func testAPhoneWhoseLayoutCannotBeReadJudgesNothing() {
        let result = VaultHome.judge(folder("\(mobileDocuments)/com~apple~CloudDocs"),
                                     ubiquityRoot: nil, isUbiquitous: { _ in true })
        XCTAssertEqual(result.failure, .unknownLayout)
    }

    // MARK: Where the vault goes

    func testAVaultPickIsTheVaultFolder() {
        let picked = folder("\(mobileDocuments)/iCloud~md~obsidian/Documents/Memory")
        XCTAssertEqual(VaultHome.folder(for: .obsidianVault("Memory"), picked: picked), picked)
    }

    func testARootPickMakesTheVaultUnderObsidian() {
        let picked = folder("\(mobileDocuments)/com~apple~CloudDocs")
        XCTAssertEqual(VaultHome.folder(for: .iCloudDriveRoot, picked: picked).path,
                       "\(mobileDocuments)/com~apple~CloudDocs/Obsidian/\(VaultHome.vaultName)")
    }

    // MARK: The root, and the picker's hint

    func testTheUbiquityRootIsReadOffThisAppsHome() {
        let home = "/private/var/mobile/Containers/Data/Application/"
            + "6C0F1F0A-0000-4000-8000-000000000000"
        XCTAssertEqual(VaultHome.ubiquityRoot(home: home)?.path, mobileDocuments)
    }

    func testThePickerOpensAtObsidiansVaultsFolder() {
        let home = "/private/var/mobile/Containers/Data/Application/"
            + "6C0F1F0A-0000-4000-8000-000000000000"
        XCTAssertEqual(VaultHome.obsidianDirectory(home: home)?.path,
                       "\(mobileDocuments)/iCloud~md~obsidian/Documents")
    }

    func testAHomeWithNoContainerGivesThePickerNoHint() {
        XCTAssertNil(VaultHome.obsidianDirectory(home: "/Users/sam"))
        XCTAssertNil(VaultHome.ubiquityRoot(home: "/Users/sam"))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
