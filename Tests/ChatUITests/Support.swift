import Foundation

// Same split as ChatCoreTests: Foundation-using helpers stay out of the Testing-importing file.
func makeTempFileURL(_ name: String) -> (url: URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
}

func makeDefaults() -> (defaults: UserDefaults, cleanup: @Sendable () -> Void) {
    let suite = "ChatUITests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) })
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func imageInfo(_ data: Data) -> (type: String, width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source) as String?,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (type, width, height)
}

func garbage() -> Data { Data("not an image".utf8) }
