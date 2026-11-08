import ChatCore
import SwiftUI

/// Decodes once, off the main thread, so a redraw while a reply streams doesn't decode the JPEG again.
struct AttachmentImage: View {
    let data: Data
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
        .task(id: data) {
            let data = data, maxPixels = maxPixels
            image = await Task.detached { ImageAttachment.downsample(data, maxPixels: maxPixels) }.value
        }
    }
}
