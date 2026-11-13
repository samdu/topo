import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct ForwardingDatabaseTests {
    /// A wrapper's bounded view asked for a bound again passes that one on too, as CloudKit's does.
    @Test func aBoundedViewAskedAgainPassesTheNewBoundOn() {
        let held = HoldingDatabase(InMemoryRecordDatabase())
        _ = CountingFetchDatabase(inner: held).answering(within: 1).answering(within: 2)
        #expect(held.bounds == [1, 2])
    }
}
