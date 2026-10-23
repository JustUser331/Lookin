import Foundation

/// Неизменяемое описание задачи: здесь нет ссылок на live UI или closures.
@objc(LKResourceJobInput)
@objcMembers
public final class ResourceJobInput: NSObject {

    // MARK: - Properties

    public let key: String
    public let oid: UInt
    public let revision: UInt
    public let currentRevision: UInt
    public let kind: String
    public let order: UInt
    public let isActive: Bool
    public let width: Double
    public let height: Double
    public let appropriateKind: String
    public let isOverview: Bool
    public let isSelected: Bool
    public let isDisplayed: Bool

    @objc(initWithKey:oid:revision:currentRevision:kind:order:active:width:height:appropriateKind:overview:selected:displayed:)
    public init(key: String, oid: UInt, revision: UInt, currentRevision: UInt,
                kind: String, order: UInt, active: Bool, width: Double, height: Double,
                appropriateKind: String, overview: Bool, selected: Bool, displayed: Bool) {
        self.key = key
        self.oid = oid
        self.revision = revision
        self.currentRevision = currentRevision
        self.kind = kind
        self.order = order
        isActive = active
        self.width = width
        self.height = height
        self.appropriateKind = appropriateKind
        isOverview = overview
        isSelected = selected
        isDisplayed = displayed
    }
}

@objc(LKPlannedResourceTask)
@objcMembers
public final class PlannedResourceTask: NSObject {

    // MARK: - Properties

    public let jobKey: String
    public let companionKey: String?
    public let wireJobKey: String
    public let needsAttributes: Bool

    init(job: ResourceJobInput, companion: ResourceJobInput?) {
        jobKey = job.key
        companionKey = companion?.key
        wireJobKey = job.kind == ResourceKind.attributes.rawValue ? (companion?.key ?? job.key) : job.key
        needsAttributes = companion != nil || job.kind == ResourceKind.attributes.rawValue
    }
}

@objc(LKResourceBatchPlan)
@objcMembers
public final class ResourceBatchPlan: NSObject {

    // MARK: - Properties

    public let tasks: [PlannedResourceTask]
    public let isMetadata: Bool

    init(tasks: [PlannedResourceTask], isMetadata: Bool) {
        self.tasks = tasks
        self.isMetadata = isMetadata
    }
}

/// Чистое планирование: стабильный FIFO, приоритеты, dedup oid и бюджет пакета.
@objc(LKResourceBatchPlanner)
public final class ResourceBatchPlanner: NSObject {

    // MARK: - Public Methods

    @objc(planWithJobs:priorities:full:screenScale:)
    public static func plan(jobs: [ResourceJobInput], priorities: [String: NSNumber],
                            full: Bool, screenScale: Double) -> ResourceBatchPlan {
        let validJobs = jobs.filter { ResourceKind(rawValue: $0.kind) != nil }
        let byKey = Dictionary(validJobs.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        // Приоритет хранится рядом с задачей: сортировка не хеширует ключи повторно.
        let scored: [(job: ResourceJobInput, priority: Int)] = validJobs.map { job in
            (job: job, priority: priorities[job.key]?.intValue ?? backgroundPriority(job, jobs: byKey, full: full))
        }
        let sorted = scored.sorted { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.job.order < second.job.order
        }
        guard let first = sorted.first else { return ResourceBatchPlan(tasks: [], isMetadata: false) }
        let isMetadata = first.job.kind == ResourceKind.metadata.rawValue
        let firstPriority = first.priority
        let scale = screenScale > 0 ? max(screenScale, 1) : 3
        let maximumArea = 60.0 * 1024 * 1024 / (4 * scale * scale)
        var area = 0.0
        var usedOids = Set<UInt>()
        var activeKeys = Set(jobs.filter(\.isActive).map(\.key))
        var result: [PlannedResourceTask] = []

        for (job, priority) in sorted {
            guard !activeKeys.contains(job.key), job.revision == job.currentRevision,
                  (job.kind == ResourceKind.metadata.rawValue) == isMetadata,
                  !usedOids.contains(job.oid) else { continue }
            let companion = companion(for: job, jobs: byKey, activeKeys: activeKeys,
                                      isMetadata: isMetadata, full: full, priority: firstPriority)
            let imageJob = job.kind == ResourceKind.attributes.rawValue ? companion : job
            let isImage = imageJob.flatMap { ResourceKind(rawValue: $0.kind) }?.isImage ?? false
            let rawArea = job.width * job.height
            // Повторяем MAX(0, area), включая поведение для нечисловой геометрии.
            let cost = isImage ? (0 > rawArea ? 0 : rawArea) : 0
            if !result.isEmpty && (result.count >= 64 || area + cost > maximumArea || priority > firstPriority) {
                break
            }
            result.append(PlannedResourceTask(job: job, companion: companion))
            activeKeys.insert(job.key)
            if let companion { activeKeys.insert(companion.key) }
            usedOids.insert(job.oid)
            area += cost
        }
        return ResourceBatchPlan(tasks: result, isMetadata: isMetadata)
    }
}

private extension ResourceBatchPlanner {

    // MARK: - Private Methods

    static func backgroundPriority(_ job: ResourceJobInput, jobs: [String: ResourceJobInput], full: Bool) -> Int {
        if full { return 20 }
        if job.isOverview && job.kind == ResourceKind.group.rawValue { return 1 }
        if job.isSelected { return 5 }
        if job.isDisplayed && job.kind == job.appropriateKind { return 10 }
        if job.kind == ResourceKind.attributes.rawValue {
            let key = ResourceIdentity.key(oid: job.oid, revision: job.currentRevision, kind: ResourceKind.metadata.rawValue)
            return jobs[key] == nil ? 20 : 31
        }
        return job.kind == ResourceKind.metadata.rawValue ? 30 : 40
    }

    static func companion(for job: ResourceJobInput, jobs: [String: ResourceJobInput], activeKeys: Set<String>,
                          isMetadata: Bool, full: Bool, priority: Int) -> ResourceJobInput? {
        let kinds: [String]
        if isMetadata {
            kinds = [ResourceKind.attributes.rawValue]
        } else if full && priority >= 20 {
            kinds = job.kind == ResourceKind.attributes.rawValue
                ? [job.appropriateKind, ResourceKind.group.rawValue, ResourceKind.solo.rawValue]
                : [ResourceKind.attributes.rawValue]
        } else {
            return nil
        }
        for kind in kinds {
            let key = ResourceIdentity.key(oid: job.oid, revision: job.currentRevision, kind: kind)
            if let candidate = jobs[key], candidate.key != job.key,
               !activeKeys.contains(candidate.key), candidate.revision == job.revision {
                return candidate
            }
        }
        return nil
    }
}
