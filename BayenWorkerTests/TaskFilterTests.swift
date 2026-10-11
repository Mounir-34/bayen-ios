import XCTest
@testable import BayenWorker

/// Status filter of "My tasks" (`TaskFilter`): which tasks the list and the map show for a selection.
final class TaskFilterTests: XCTestCase {
    private func task(_ id: String, _ status: String) throws -> WorkerTask {
        try JSONCoding.decoder.decode(WorkerTask.self, from: Fixtures.json(Fixtures.task(id: id, status: status)))
    }

    private func sample() throws -> [WorkerTask] {
        [try task("a", "ASSIGNED"), try task("b", "IN_PROGRESS"), try task("c", "REJECTED"),
         try task("d", "SUBMITTED"), try task("e", "APPROVED"), try task("f", "CANCELLED")]
    }

    func testNothingSelectedShowsEveryTask() throws {
        let tasks = try sample()
        XCTAssertEqual(TaskFilter.apply(tasks, selected: []), tasks)
    }

    func testOneStateKeepsOnlyItsTasksInOrder() throws {
        let tasks = try sample()
        XCTAssertEqual(TaskFilter.apply(tasks, selected: [.inProgress]).map(\.id), ["b"])
        // "To do" covers both assigned and rejected tasks.
        XCTAssertEqual(TaskFilter.apply(tasks, selected: [.toDo]).map(\.id), ["a", "c"])
    }

    func testSeveralStatesCanBeCombined() throws {
        let tasks = try sample()
        XCTAssertEqual(TaskFilter.apply(tasks, selected: [.inProgress, .done]).map(\.id), ["b", "e"])
        XCTAssertEqual(TaskFilter.apply(tasks, selected: Set(TaskSection.allCases)).map(\.id), ["a", "b", "c", "d", "e"],
                       "a task outside every state (cancelled) is hidden as soon as a filter is on")
    }

    func testSelectionWithoutMatchGivesAnEmptyList() throws {
        let tasks = [try task("a", "ASSIGNED"), try task("b", "IN_PROGRESS")]
        XCTAssertTrue(TaskFilter.apply(tasks, selected: [.waitingReview, .done]).isEmpty)
        XCTAssertTrue(TaskFilter.apply([], selected: [.toDo]).isEmpty)
    }

    func testFilterUsesTheStatusIncludingWorkQueuedOnTheDevice() throws {
        let tasks = [try task("a", "ASSIGNED"), try task("b", "IN_PROGRESS")]
        // "a" has a start queued offline, "b" a queued submission.
        let effective: (WorkerTask) -> TaskStatus = { $0.id == "a" ? .inProgress : .submitted }
        XCTAssertEqual(TaskFilter.apply(tasks, selected: [.inProgress], status: effective).map(\.id), ["a"])
        XCTAssertEqual(TaskFilter.apply(tasks, selected: [.waitingReview], status: effective).map(\.id), ["b"])
        XCTAssertTrue(TaskFilter.apply(tasks, selected: [.toDo], status: effective).isEmpty)
    }

    func testCountsCoverAllTasksWhateverTheFilter() throws {
        let counts = TaskFilter.counts(try sample())
        XCTAssertEqual(counts, [.toDo: 2, .inProgress: 1, .waitingReview: 1, .done: 1])
        XCTAssertTrue(TaskFilter.counts([]).isEmpty)
    }

    func testTogglingAddsThenRemovesAState() {
        let one = TaskFilter.toggling(.toDo, in: [])
        XCTAssertEqual(one, [.toDo])
        let two = TaskFilter.toggling(.done, in: one)
        XCTAssertEqual(two, [.toDo, .done])
        XCTAssertEqual(TaskFilter.toggling(.toDo, in: two), [.done])
        XCTAssertTrue(TaskFilter.toggling(.done, in: [.done]).isEmpty)
    }

    func testFilterStringsExistInEveryLanguage() throws {
        let keys = ["tasks.filter.empty.title", "tasks.filter.empty.message", "tasks.filter.showAll", "tasks.filter.hint",
                    "list.separator"]
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: key, table: "Localizable"), key,
                                  "\(key) is missing in \(language.rawValue)")
            }
        }
    }
}
