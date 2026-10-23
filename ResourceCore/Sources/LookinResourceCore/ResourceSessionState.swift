import Foundation

/// Состояние одной очереди принадлежит главному потоку. UIKit/AppKit объекты
/// и callback transport остаются в Objective-C адаптере.
@MainActor
@objc(LKResourceSessionState)
@objcMembers
public final class ResourceSessionState: NSObject {

    // MARK: - Properties

    public var snapshotID: String?
    public private(set) var generation: UInt = 0
    public private(set) var nextOrder: UInt = 0
    public var completedTasks: UInt = 0
    public var isRequestActive = false
    public var isScheduled = false
    public var isBackgroundStopped = false
    public var isPreparing = false
    public var isCancelling = false
    public var hasReportedComplete = false

    // MARK: - Public Methods

    public func advanceGeneration() {
        generation &+= 1
    }

    public func takeNextOrder() -> UInt {
        let order = nextOrder
        nextOrder &+= 1
        return order
    }
}
