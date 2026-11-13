import CloudKit
import TopoCore
import XCTest

@testable import Topo

/// The app's names for the log's container and zone are the values `CloudKitRecordDatabase`
/// holds, as the compiled app has them, whatever the source looks like.
final class TopoCloudKitTests: XCTestCase {
    func testTheAppsContainerAndZoneAreTheConstant() {
        XCTAssertEqual(TopoCloudKit.containerIdentifier, CloudKitRecordDatabase.containerIdentifier)
        XCTAssertEqual(TopoCloudKit.zoneName, CloudKitRecordDatabase.zoneName)
        XCTAssertEqual(TopoCloudKit.zoneID.zoneName, CloudKitRecordDatabase.zoneName)
        XCTAssertEqual(TopoCloudKit.zoneID.ownerName, CKCurrentUserDefaultName)
    }
}
