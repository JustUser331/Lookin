import Foundation

enum ResourceKind: String, CaseIterable, Sendable {
    case attributes
    case metadata
    case group
    case solo

    // MARK: - Properties

    var isImage: Bool { self == .group || self == .solo }
}

@objc(LKResourceIdentity)
public final class ResourceIdentity: NSObject {

    // MARK: - Properties

    @objc public static let allKinds = ResourceKind.allCases.map(\.rawValue)

    // MARK: - Public Methods

    @objc(keyWithOid:revision:kind:)
    public static func key(oid: UInt, revision: UInt, kind: String) -> String {
        "\(oid):\(revision):\(kind)"
    }
}
