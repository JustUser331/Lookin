import XCTest
@testable import LookinResourceCore

final class ResourceCoreTests: XCTestCase {

    // MARK: - Public Methods

    func testFullCombinesAttributesWithAppropriateImageAndKeepsOneTaskPerOid() {
        let result = plan([job(.attributes, order: 0), job(.group, order: 1), job(.solo, order: 2)])
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].jobKey, "1:1:attributes")
        XCTAssertEqual(result.tasks[0].wireJobKey, "1:1:group")
        XCTAssertEqual(result.tasks[0].companionKey, "1:1:group")
        XCTAssertTrue(result.tasks[0].needsAttributes)
    }

    func testHybridOverviewPrecedesMetadataAndOrdinaryImages() {
        let result = plan([job(.metadata, order: 0), job(.group, oid: 2, order: 1),
                           job(.group, order: 2, overview: true)], full: false)
        XCTAssertEqual(result.tasks.map(\.wireJobKey), ["1:1:group"])
        XCTAssertFalse(result.isMetadata)
    }

    func testInteractiveAttributesDoNotWaitForImageOrMetadata() {
        let result = plan([job(.attributes, order: 0), job(.metadata, order: 1),
                           job(.group, order: 2, overview: true)],
                          priorities: ["1:1:attributes": 0], full: false)
        XCTAssertEqual(result.tasks.map(\.wireJobKey), ["1:1:attributes"])
        XCTAssertNil(result.tasks[0].companionKey)
    }

    func testDeferredMetadataFulfilsAttributesInOneRequest() {
        let result = plan([job(.attributes, order: 0), job(.metadata, order: 1)], full: false)
        XCTAssertTrue(result.isMetadata)
        XCTAssertEqual(result.tasks[0].wireJobKey, "1:1:metadata")
        XCTAssertEqual(result.tasks[0].companionKey, "1:1:attributes")
        XCTAssertTrue(result.tasks[0].needsAttributes)
    }

    func testNativeScaleBudgetAndOversizedFirstTask() {
        let images = (1...8).map { job(.group, oid: UInt($0), order: UInt($0), size: 500) }
        XCTAssertEqual(plan(images, scale: 3).tasks.count, 6)
        XCTAssertEqual(plan(images, scale: 1).tasks.count, 8)
        XCTAssertEqual(plan(images, scale: 0).tasks.count, 6)
        XCTAssertEqual(plan([job(.group, order: 0, size: 20_000), job(.group, oid: 2, order: 1)]).tasks.count, 1)
    }

    func testLegacyTaskCountLimitAndStableFIFO() {
        let jobs = (0..<70).reversed().map { job(.attributes, oid: UInt($0 + 1), order: UInt($0)) }
        let tasks = plan(jobs).tasks
        XCTAssertEqual(tasks.count, 64)
        XCTAssertEqual(tasks.first?.jobKey, "1:1:attributes")
        XCTAssertEqual(tasks.last?.jobKey, "64:1:attributes")
    }

    func testStaleAndActiveResourcesAreNotRequestedAgain() {
        let result = plan([job(.group, oid: 1, order: 0, currentRevision: 2),
                           job(.group, oid: 2, order: 1, active: true),
                           job(.group, oid: 3, order: 2)])
        XCTAssertEqual(result.tasks.map(\.wireJobKey), ["3:1:group"])
    }

    func testResourceKeyPreservesFullWidthObjectIdentity() {
        XCTAssertEqual(ResourceIdentity.key(oid: .max, revision: .max, kind: "group"),
                       "18446744073709551615:18446744073709551615:group")
        XCTAssertEqual(ResourceIdentity.allKinds, ["attributes", "metadata", "group", "solo"])
    }

    func testStaleMetadataDoesNotStarveAValidImage() {
        let result = plan([job(.attributes, order: 0, currentRevision: 2),
                           job(.metadata, order: 1, currentRevision: 2),
                           job(.group, oid: 2, order: 2)], full: false)
        XCTAssertEqual(result.tasks.map(\.wireJobKey), ["2:1:group"])
    }

    @MainActor
    func testSessionGenerationAndOrderRemainMonotonicAcrossCancellation() {
        let state = ResourceSessionState()
        XCTAssertNil(state.snapshotID)
        XCTAssertEqual(state.takeNextOrder(), 0)
        state.advanceGeneration()
        state.advanceGeneration()
        XCTAssertEqual(state.generation, 2)
        XCTAssertEqual(state.takeNextOrder(), 1)
        state.isCancelling = true
        state.isPreparing = true
        XCTAssertTrue(state.isCancelling && state.isPreparing)
    }
}

private extension ResourceCoreTests {

    // MARK: - Private Methods

    func job(_ kind: ResourceKind, oid: UInt = 1, order: UInt, currentRevision: UInt = 1,
             active: Bool = false, size: Double = 100, overview: Bool = false) -> ResourceJobInput {
        ResourceJobInput(key: ResourceIdentity.key(oid: oid, revision: 1, kind: kind.rawValue),
                         oid: oid, revision: 1, currentRevision: currentRevision, kind: kind.rawValue,
                         order: order, active: active, width: size, height: size, appropriateKind: "group",
                         overview: overview, selected: false, displayed: false)
    }

    func plan(_ jobs: [ResourceJobInput], priorities: [String: NSNumber] = [:],
              full: Bool = true, scale: Double = 3) -> ResourceBatchPlan {
        ResourceBatchPlanner.plan(jobs: jobs, priorities: priorities, full: full, screenScale: scale)
    }
}
