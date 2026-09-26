import Foundation
import XCTest

@testable import Topo

/// The rule the guest's mount of the memory follows (`VaultMount`), over a recording seam: the
/// home's folder by its identity on disk, the grant started on the URL it is on and never on the
/// vault under it, a folder made again mounted again, a busy mount refused rather than stepped
/// around, a lost home mounting nothing, and a sign-out taking the mount and then the grant away.
@MainActor
final class VaultMountTests: XCTestCase {
    /// Everything the mount did, in order, and what the disk answers.
    @MainActor
    private final class Recorder {
        var calls: [String] = []
        var identities: [URL: VaultMount.Identity] = [:]
        var unmountFails = false
        var accessRefused = false

        var seam: VaultMount.Seam {
            VaultMount.Seam(
                mount: { self.calls.append("mount \($0.lastPathComponent)") },
                unmount: {
                    if self.unmountFails { throw NSError(domain: "guest", code: -16) }
                    self.calls.append("unmount")
                },
                link: { self.calls.append("link") },
                startAccess: { self.calls.append("start \($0.lastPathComponent)"); return !self.accessRefused },
                stopAccess: { self.calls.append("stop \($0.lastPathComponent)") },
                identity: { self.identities[$0] },
                makeFolder: { url in
                    if self.identities[url] == nil { self.identities[url] = .init(device: 1, inode: 100) }
                })
        }
    }

    private let local = URL(fileURLWithPath: "/app/Documents/Vault")
    private let root = URL(fileURLWithPath: "/icloud/com~apple~CloudDocs")
    private var vault: URL { root.appendingPathComponent("Obsidian/Topo") }

    func testTheLocalHomeIsMadeAndMountedOnceWhileItIsTheSameFolder() throws {
        let recorder = Recorder()
        let mount = VaultMount(seam: recorder.seam)
        XCTAssertTrue(try mount.reconcile(home: .local, local: local))
        XCTAssertTrue(try mount.reconcile(home: .local, local: local))
        XCTAssertEqual(recorder.calls, ["mount Vault", "link", "link"])
    }

    func testAFolderRemadeUnderTheSamePathIsMountedAgain() throws {
        let recorder = Recorder()
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .local, local: local)
        // A sign-out took the folder away and a sign-in made it again: same path, another folder.
        recorder.identities[local] = .init(device: 1, inode: 200)
        recorder.calls = []
        XCTAssertTrue(try mount.reconcile(home: .local, local: local))
        XCTAssertEqual(recorder.calls, ["unmount", "mount Vault", "link"])
        XCTAssertEqual(mount.standing?.identity, .init(device: 1, inode: 200))
    }

    func testTheMountedFolderIsTheVaultNotTheGrant() throws {
        let recorder = Recorder()
        recorder.identities[vault] = .init(device: 2, inode: 7)
        let mount = VaultMount(seam: recorder.seam)
        XCTAssertTrue(try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local))
        XCTAssertEqual(recorder.calls, ["start com~apple~CloudDocs", "mount Topo", "link"])
        XCTAssertEqual(mount.standing?.folder, vault)
        XCTAssertEqual(mount.standing?.scope, root)
    }

    func testAMoveTakesTheOldMountAndItsGrantAwayBeforeMountingTheNew() throws {
        let recorder = Recorder()
        recorder.identities[vault] = .init(device: 2, inode: 7)
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local)
        recorder.calls = []
        XCTAssertTrue(try mount.reconcile(home: .local, local: local))
        XCTAssertEqual(recorder.calls, ["unmount", "stop com~apple~CloudDocs", "mount Vault", "link"])
    }

    func testABusyRemountRefusesAndLeavesTheMountAsItWas() throws {
        let recorder = Recorder()
        recorder.identities[vault] = .init(device: 2, inode: 7)
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .local, local: local)
        let before = mount.standing
        recorder.unmountFails = true
        recorder.calls = []
        XCTAssertThrowsError(try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local)) { error in
            guard case .busy = error as? VaultMount.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(recorder.calls, [], "something was mounted or granted over a mount that would not go")
        XCTAssertEqual(mount.standing, before)
    }

    func testALostHomeMountsNothingAndSaysSo() throws {
        let recorder = Recorder()
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .local, local: local)
        recorder.calls = []
        XCTAssertFalse(try mount.reconcile(home: .lost("the folder is gone"), local: local))
        XCTAssertEqual(recorder.calls, ["unmount"])
        XCTAssertNil(mount.standing)
    }

    func testAGrantRefusedOrAFolderNotThereMountsNothing() throws {
        let recorder = Recorder()
        let mount = VaultMount(seam: recorder.seam)
        // The vault folder under the grant is not there.
        XCTAssertFalse(try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local))
        XCTAssertEqual(recorder.calls, ["start com~apple~CloudDocs", "stop com~apple~CloudDocs"])
        recorder.identities[vault] = .init(device: 2, inode: 7)
        recorder.accessRefused = true
        recorder.calls = []
        XCTAssertFalse(try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local))
        XCTAssertEqual(recorder.calls, ["start com~apple~CloudDocs"])
        XCTAssertNil(mount.standing)
    }

    func testForgetUnmountsAndStopsAccess() throws {
        let recorder = Recorder()
        recorder.identities[vault] = .init(device: 2, inode: 7)
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local)
        recorder.calls = []
        mount.forget()
        XCTAssertEqual(recorder.calls, ["unmount", "stop com~apple~CloudDocs"])
        XCTAssertNil(mount.standing)
    }

    /// A mount a teardown that did not confirm still holds: the grant goes anyway, and the next
    /// reconcile takes the mount away before anything else, even for the same folder.
    func testAForgetThatCannotUnmountStopsTheGrantAndLeavesTheMountStale() throws {
        let recorder = Recorder()
        recorder.identities[vault] = .init(device: 2, inode: 7)
        let mount = VaultMount(seam: recorder.seam)
        _ = try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local)
        recorder.unmountFails = true
        recorder.calls = []
        mount.forget()
        XCTAssertEqual(recorder.calls, ["stop com~apple~CloudDocs"])
        recorder.unmountFails = false
        recorder.calls = []
        XCTAssertTrue(try mount.reconcile(home: .iCloudDrive(picked: root, folder: vault), local: local))
        XCTAssertEqual(recorder.calls, ["unmount", "start com~apple~CloudDocs", "mount Topo", "link"])
    }

    /// The identity is read off the disk: a folder removed and made again is another folder.
    func testTheIdentityOfAFolderMadeAgainIsAnother() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let first = try XCTUnwrap(VaultMount.Identity.of(folder))
        // Held open, so the inode cannot be handed straight back to the folder made next.
        let hold = open(folder.path, O_RDONLY)
        defer { close(hold) }
        try fm.removeItem(at: folder)
        XCTAssertNil(VaultMount.Identity.of(folder))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNotEqual(VaultMount.Identity.of(folder), first)
        try Data().write(to: folder.appendingPathComponent("file"))
        XCTAssertNil(VaultMount.Identity.of(folder.appendingPathComponent("file")), "a file is not a folder to mount")
    }
}
