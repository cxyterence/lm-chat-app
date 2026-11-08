import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageAttachment {
    /// The most images one message carries.
    public static let limit = 4

    /// Re-encodes a picked photo (HEIC, PNG, JPEG...) as an upright JPEG no longer than `maxPixels` on its long
    /// edge. Full-size photos would cost megabytes per request and far more image tokens than a model needs.
    public static func jpeg(from data: Data, maxPixels: Int = 1536) -> Data? {
        guard let image = downsample(data, maxPixels: maxPixels) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    public static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
