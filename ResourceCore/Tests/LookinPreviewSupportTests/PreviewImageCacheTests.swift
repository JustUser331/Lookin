import AppKit
import XCTest
@testable import LookinPreviewSupport

final class PreviewImageCacheTests: XCTestCase {

    // MARK: - Public Methods

    @MainActor
    func testEqualPNGBytesShareImageWithoutChangingDimensionsOrAlpha() throws {
        let cache = PreviewImageCache()
        let data = png(red: 80, alpha: 47)
        let image = try XCTUnwrap(cache.image(forPNGData: data))
        let copy = Data([UInt8](data))
        XCTAssertTrue(cache.image(forPNGData: copy) === image)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 4)
        XCTAssertEqual(bitmap.pixelsHigh, 2)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 47.0 / 255, accuracy: 0.001)
        XCTAssertEqual(cache.entryCount, 1)
    }

    @MainActor
    func testChangedPNGDoesNotReuseStaleImage() throws {
        let cache = PreviewImageCache()
        let old = try XCTUnwrap(cache.image(forPNGData: png(red: 50)))
        let updated = try XCTUnwrap(cache.image(forPNGData: png(red: 51)))
        XCTAssertFalse(old === updated)
        XCTAssertEqual(cache.entryCount, 2)
    }

    @MainActor
    func testNewSnapshotAndAnotherPreviewDoNotShareCache() throws {
        let cache = PreviewImageCache()
        let data = png(red: 80)
        let old = try XCTUnwrap(cache.image(forPNGData: data))
        cache.removeAllImages()
        XCTAssertEqual(cache.retainedCost, 0)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertFalse(cache.image(forPNGData: data) === old)
        XCTAssertFalse(PreviewImageCache().image(forPNGData: data) === old)
    }

    @MainActor
    func testLeastRecentlyUsedImageIsEvictedButVisibleImageRemainsValid() throws {
        let cache = PreviewImageCache(byteBudget: 1_000_000, entryLimit: 2)
        let firstData = png(red: 10), secondData = png(red: 20)
        let first = try XCTUnwrap(cache.image(forPNGData: firstData))
        let second = try XCTUnwrap(cache.image(forPNGData: secondData))
        XCTAssertTrue(cache.image(forPNGData: firstData) === first)
        XCTAssertNotNil(cache.image(forPNGData: png(red: 30)))
        XCTAssertTrue(cache.image(forPNGData: firstData) === first)
        XCTAssertFalse(cache.image(forPNGData: secondData) === second)
        XCTAssertEqual(second.representations.first?.pixelsWide, 4)
        XCTAssertEqual(cache.entryCount, 2)
    }

    @MainActor
    func testByteBudgetAndInvalidDataDoNotDropAValidOversizedImage() {
        let cache = PreviewImageCache(byteBudget: 1)
        XCTAssertNotNil(cache.image(forPNGData: png(red: 80)))
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.retainedCost, 0)
        XCTAssertNil(cache.image(forPNGData: Data([1, 2, 3])))
    }

    @MainActor
    func testCombinedImageCostCannotExceedByteBudget() throws {
        let data = [png(red: 10), png(red: 20), png(red: 30)]
        let budget = data[0].count + data[1].count + 2 * 4 * 2 * 4
        let cache = PreviewImageCache(byteBudget: budget)
        let first = try XCTUnwrap(cache.image(forPNGData: data[0]))
        XCTAssertNotNil(cache.image(forPNGData: data[1]))
        XCTAssertNotNil(cache.image(forPNGData: data[2]))
        XCTAssertLessThanOrEqual(cache.retainedCost, budget)
        XCTAssertLessThan(cache.entryCount, 3)
        XCTAssertFalse(cache.image(forPNGData: data[0]) === first)
    }
}

private extension PreviewImageCacheTests {

    // MARK: - Private Methods

    func png(red: UInt8, alpha: UInt8 = 255) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 16, bitsPerPixel: 32)!
        for index in 0..<8 {
            bitmap.bitmapData![index * 4] = red
            bitmap.bitmapData![index * 4 + 1] = 100
            bitmap.bitmapData![index * 4 + 2] = 150
            bitmap.bitmapData![index * 4 + 3] = alpha
        }
        return bitmap.representation(using: .png, properties: [:])!
    }
}
