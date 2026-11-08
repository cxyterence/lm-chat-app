import Testing
import ChatCore

struct ImageAttachmentTests {
    @Test func aLargePhotoShrinksToTheLimitAsJPEG() throws {
        let jpeg = try #require(ImageAttachment.jpeg(from: makePNG(width: 4032, height: 3024)))
        let info = try #require(imageInfo(jpeg))
        #expect(info.type == "public.jpeg")
        #expect(info.width == 1536)
        #expect(info.height == 1152)
    }

    @Test func aSmallImageKeepsItsSize() throws {
        let info = try #require(imageInfo(ImageAttachment.jpeg(from: makePNG(width: 300, height: 200))!))
        #expect((info.width, info.height) == (300, 200))
    }

    @Test func dataThatIsNotAnImageGivesNothing() {
        #expect(ImageAttachment.jpeg(from: garbage()) == nil)
    }
}
