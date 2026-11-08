import ChatCore
import SwiftUI

/// Reads and decodes once, off the main thread, so a redraw while a reply streams doesn't decode the photo again.
struct AttachmentImage: View {
    let url: URL
    var maxPixels = 720
    @State private var image: CGImage?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Rectangle().fill(palette.fill)
            }
        }
        .task(id: url) {
            let url = url, maxPixels = maxPixels
            image = await Task.detached { ImageAttachment.downsample(contentsOf: url, maxPixels: maxPixels) }.value
        }
    }
}
