import UIKit
import XCTest

/// Answers a fixed transcript on the main queue, as the CloudKit source
/// does, so the screen can be exercised with no account and no network.
private final class StubSource: TranscriptSource {
    let result: Result<Transcript, TranscriptError>
    init(_ result: Result<Transcript, TranscriptError>) { self.result = result }

    func read(completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        completion(result)
    }
}

private func turn(_ sequence: Int64, _ role: String, _ text: String) -> Turn {
    let fields: [String: Any] = [
        "device": "phone",
        "sequence": NSNumber(value: sequence),
        "parents": sequence > 1 ? ["phone/\(sequence - 1)"] : [],
        "role": role,
        "text": text,
        "at": Date(timeIntervalSince1970: TimeInterval(sequence * 60)),
    ]
    return Turn(recordName: "turn/phone/\(sequence)", fields: fields)!
}

private let conversation = Transcript(turns: [
    turn(1, "person", "What did I forget this week?"),
    turn(2, "assistant", String(repeating: "A turn long enough to wrap over several lines at every text size. ", count: 6)),
    turn(3, "person", "Call Helen tomorrow morning"),
])

/// Sizes in points: phone portrait and landscape, iPad portrait and
/// landscape. Womble runs on all four and the drawer iPad is the first
/// customer, so every one of them is laid out here.
private let sizes: [(String, CGSize)] = [
    ("phone portrait", CGSize(width: 390, height: 844)),
    ("phone landscape", CGSize(width: 844, height: 390)),
    ("iPad portrait", CGSize(width: 768, height: 1024)),
    ("iPad landscape", CGSize(width: 1024, height: 768)),
]

final class TranscriptViewControllerTests: XCTestCase {
    private func laidOut(_ source: TranscriptSource, size: CGSize) -> (UIViewController, UITableView) {
        let controller = TranscriptViewController(source: source)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        guard let table = firstTableView(in: controller.view) else {
            fatalError("the screen has no table view")
        }
        table.layoutIfNeeded()
        return (controller, table)
    }

    private func firstTableView(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews {
            if let table = firstTableView(in: subview) { return table }
        }
        return nil
    }

    func testEveryTurnGetsARowAtEverySize() {
        for (name, size) in sizes {
            let (_, table) = laidOut(StubSource(.success(conversation)), size: size)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 3, "rows at \(name)")
        }
    }

    func testARowIsAsTallAsItsTurnNeeds() {
        for (name, size) in sizes {
            let (_, table) = laidOut(StubSource(.success(conversation)), size: size)
            let short = table.rectForRow(at: IndexPath(row: 0, section: 0)).height
            let long = table.rectForRow(at: IndexPath(row: 1, section: 0)).height
            XCTAssertGreaterThan(short, 0, "a row has height at \(name)")
            XCTAssertGreaterThan(long, short, "a long turn is taller than a short one at \(name)")
        }
    }

    func testATurnStaysInsideTheReadableWidth() {
        // A turn running the full width of an iPad is unreadable, so the
        // cells follow the readable width rather than the screen's.
        for (name, size) in sizes where size.width > 700 {
            let (_, table) = laidOut(StubSource(.success(conversation)), size: size)
            guard let cell = table.cellForRow(at: IndexPath(row: 1, section: 0)) else {
                return XCTFail("no cell at \(name)")
            }
            cell.layoutIfNeeded()
            let content = cell.contentView.subviews.first?.frame.width ?? size.width
            XCTAssertLessThanOrEqual(content, TurnCell.maximumLineWidth, "a line is capped at \(name)")
            XCTAssertLessThan(content, size.width - 40, "content is narrower than the screen at \(name)")
        }
    }

    func testAFailedReadWithNoTurnsShowsTheReason() {
        let (controller, table) = laidOut(StubSource(.failure(.noAccount)), size: sizes[0].1)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0)
        XCTAssertFalse(table.backgroundView?.isHidden ?? true, "the status view is showing")
        XCTAssertNotNil(controller.view)
    }
}
