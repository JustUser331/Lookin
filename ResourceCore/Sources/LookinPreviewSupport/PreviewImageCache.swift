import AppKit

/// Кеш одного preview. Совпадение всех байтов PNG сохраняет цвет, alpha и metadata.
/// Выданные изображения используются только для чтения на главном потоке.
@MainActor
@objc(LKPreviewImageCache)
public final class PreviewImageCache: NSObject {

    // MARK: - Properties

    private struct Entry {

        // MARK: - Properties

        let image: NSImage
        let cost: Int
        var access: UInt64
    }

    private let byteBudget: Int
    private let entryLimit: Int
    private var entries: [Data: Entry] = [:]
    private var access: UInt64 = 0
    private(set) var retainedCost = 0
    var entryCount: Int { entries.count }

    public override init() {
        byteBudget = 64 * 1024 * 1024
        entryLimit = 128
        super.init()
    }

    init(byteBudget: Int, entryLimit: Int = 128) {
        self.byteBudget = max(0, byteBudget)
        self.entryLimit = max(0, entryLimit)
        super.init()
    }
}

public extension PreviewImageCache {

    // MARK: - Public Methods

    @objc(imageForPNGData:)
    func image(forPNGData data: Data) -> NSImage? {
        access &+= 1
        if var entry = entries[data] {
            entry.access = access
            entries[data] = entry
            return entry.image
        }
        guard let image = NSImage(data: data) else { return nil }
        guard entryLimit > 0, let cost = storageCost(image: image, data: data), cost <= byteBudget else { return image }
        while entries.count >= entryLimit || retainedCost > byteBudget - cost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            retainedCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        entries[data] = Entry(image: image, cost: cost, access: access)
        retainedCost += cost
        return image
    }

    @objc func removeAllImages() {
        entries.removeAll(keepingCapacity: false)
        retainedCost = 0
        access = 0
    }
}

private extension PreviewImageCache {

    // MARK: - Private Methods

    func storageCost(image: NSImage, data: Data) -> Int? {
        guard let representation = image.representations.first,
              representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return nil }
        let bytesPerPixel = max(4, ((representation as? NSBitmapImageRep)?.bitsPerPixel ?? 32) / 8)
        let (pixels, pixelsOverflow) = representation.pixelsWide.multipliedReportingOverflow(by: representation.pixelsHigh)
        let (bitmap, bitmapOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        let (total, totalOverflow) = bitmap.addingReportingOverflow(data.count)
        return pixelsOverflow || bitmapOverflow || totalOverflow ? nil : total
    }
}
