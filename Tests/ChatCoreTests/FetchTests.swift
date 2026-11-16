import Foundation
import Testing
@testable import ChatCore

struct FetchTests {
    private func refusal(_ address: String) -> String? {
        do { _ = try FetchRequest(address: address); return nil } catch let error as FetchRequest.Invalid { return error.message } catch { return "\(error)" }
    }

    // MARK: The tool call

    @Test func theArgumentsAreAJSONObjectWithAnAddress() throws {
        #expect(try FetchRequest.parse(arguments: #"{"url":"https://example.com/a?b=1"}"#).url.absoluteString == "https://example.com/a?b=1")
        #expect(try FetchRequest.parse(arguments: #"{"url":"  https://example.com  "}"#).url.host() == "example.com")
        for bad in ["{}", "[]", "not json", #"{"url":5}"#, #"{"url":"example.com"}"#, #"{"url":"not a url"}"#] {
            #expect(throws: FetchRequest.Invalid.self) { try FetchRequest.parse(arguments: bad) }
        }
    }

    @Test func theToolHasOneRequiredStringParameterAndSaysWhenToCallIt() throws {
        let spec = FetchRequest.toolSpec
        #expect(spec.name == "fetch_url")
        #expect(spec.description.contains("link") && spec.description.contains("text"))
        #expect(spec.parameters["required"] == .array([.string("url")]))
        #expect(spec.parameters["properties"]?["url"]?["type"] == .string("string"))
    }

    // MARK: Which addresses are refused

    @Test(arguments: [
        "file:///etc/passwd", "ftp://example.com/x", "javascript:alert(1)", "data:text/html,hi", "ws://example.com",
    ]) func onlyHttpAndHttpsAreFetched(address: String) {
        #expect(refusal(address) == "Only http and https addresses can be fetched.")
    }

    @Test(arguments: ["http://user:pass@example.com/", "https://user@example.com/", "https://:secret@example.com/"])
    func aUserNameOrPasswordInTheAddressIsRefused(address: String) {
        #expect(refusal(address)?.contains("user name or password") == true)
    }

    @Test(arguments: [
        "http://localhost/", "http://LOCALHOST:8080/x", "http://localhost./", "http://app.localhost/", "http://printer.local/",
        "https://db.internal/", "https://Build.Internal./",
        "http://127.0.0.1/", "http://127.255.255.254/", "http://10.0.0.1/", "http://10.255.0.9:3000/",
        "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/", "http://169.254.169.254/latest/meta-data/",
        "http://0.0.0.0/", "http://0.0.0.0:11434/",
        "http://[::1]/", "http://[::]/", "http://[fe80::1]/", "http://[febf::1]/", "http://[fc00::1]/", "http://[fd12:3456::1]/",
        "http://[::ffff:127.0.0.1]/", "http://[::ffff:10.0.0.1]/", "http://[64:ff9b::a00:1]/",
        "http://2130706433/", "http://0x7f000001/", "http://0x7f.0.0.1/", "http://017700000001/", "http://127.1/",
        "http://167772161/", "http://3232235777/", "http://2852039166/",
        "http://100.64.0.1/", "http://100.100.100.100/", "http://100.127.255.255/", "http://1681915905/",
        "http://[::ffff:0:a00:1]/", "http://[::ffff:0:7f00:1]/", "http://[::ffff:0:6440:1]/",
        "http://[2002:a00:1::1]/", "http://[2002:7f00:1::]/", "http://[2002:c0a8:101::1]/", "http://[2002:6464:6464::1]/",
        "http://[fec0::1]/", "http://[feff::1]/", "http://[64:ff9b:1::1]/", "http://[64:ff9b:1:ffff::]/",
    ]) func localAndPrivateHostsAreRefused(address: String) {
        #expect(refusal(address)?.contains("private network") == true, "\(address) should be refused")
    }

    @Test(arguments: [
        "https://example.com/", "http://8.8.8.8/", "http://172.15.0.1/", "http://172.32.0.1/", "http://192.169.0.1/",
        "http://11.0.0.1/", "http://169.253.0.1/", "http://[2606:4700::1111]/", "https://localhost.example.com/",
        "https://notlocal.com/", "https://internal.example.com/", "http://134744072/",
        "http://100.63.255.255/", "http://100.128.0.1/", "http://198.18.0.1/",
        "http://[2002:808:808::1]/", "http://[::ffff:0:808:808]/", "http://[64:ff9b::808:808]/", "http://[64:ff9a::1]/",
    ]) func publicAddressesAreAllowed(address: String) {
        #expect(refusal(address) == nil, "\(address) should be allowed, got \(refusal(address) ?? "")")
    }

    @Test func aRefusalNamesTheHostSoTheModelCanTellTheUser() {
        #expect(refusal("http://192.168.1.1/admin")?.hasPrefix("192.168.1.1 is on this device or a private network") == true)
    }

    // MARK: Whether the user gave the address

    private func named(_ address: String, in texts: String...) -> Bool {
        FetchRequest.isNamed(URL(string: address)!, in: texts)
    }

    @Test func aHostTheUserWroteIsOneTheyGave() {
        #expect(named("https://example.com/a?b=1", in: "What does https://example.com/x say?"))
        #expect(named("https://example.com/", in: "Example.COM is down for me"))
        #expect(named("https://example.com/", in: "see example.com."))
        #expect(named("https://example.com/", in: "(example.com), right?"))
        #expect(named("https://example.com/", in: "http://example.com:8080/x"))
        #expect(named("https://93.184.216.34/", in: "fetch 93.184.216.34/index"))
        #expect(named("https://example.com/", in: "nothing here", "and then example.com"))
    }

    @Test func aHostThatOnlyLooksLikeOneTheUserWroteIsNot() {
        #expect(!named("https://example.com/", in: "notexample.com"))
        #expect(!named("https://example.com/", in: "example.com.evil.net"))
        #expect(!named("https://example.com/", in: "evil-example.com"))
        #expect(!named("https://example.com/", in: "example.community"))
        #expect(!named("https://example.com/", in: "www.example.com"))
        #expect(!named("https://www.example.com/", in: "example.com"))
        #expect(!named("https://evil.example/?q=example.com", in: "example.com is fine"))
        #expect(!named("https://example.com/", in: "nothing to see"))
        #expect(!FetchRequest.isNamed(URL(string: "https://example.com/")!, in: []))
    }

    // MARK: HTML to a page

    @Test func aPageComesBackAsItsTitleAddressAndText() async throws {
        let stub = PageStub(.html("<html><head><title>Example Domain</title><script>x()</script></head><body><h1>Example Domain</h1><p>This domain is for use in examples.</p></body></html>"))
        let page = try await stub.fetcher().fetch(stub.url("/a"))

        #expect(page.title == "Example Domain" && page.url == stub.url("/a") && !page.truncated)
        #expect(page.text == "Example Domain\n\nThis domain is for use in examples.")
        #expect(page.toolResult == "Title: Example Domain\nURL: \(stub.url("/a").absoluteString)\n\nExample Domain\n\nThis domain is for use in examples.")
    }

    @Test func aRequestIsAPlainGetThatCarriesNoCookiesAndNoCredentials() async throws {
        let stub = PageStub(.html("<p>x</p>"))
        _ = try await stub.fetcher().fetch(stub.url())

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "LMChat/1.0")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        let session = PageFetcher.privateSession().configuration
        #expect(session.httpCookieStorage == nil && session.urlCredentialStorage == nil && session.urlCache == nil)
        #expect(session.timeoutIntervalForResource == 30, "a server that drips bytes can't hold a fetch open")
    }

    @Test func textJSONAndXMLPassThroughUntouched() async throws {
        for (type, body) in [("text/plain; charset=utf-8", "line one\n  <b> stays </b>\n"), ("application/json", #"{"a":"<p>x</p>"}"#),
                             ("application/rss+xml", "<rss><title>t</title></rss>"), ("text/markdown", "# Hi")] {
            let stub = PageStub(.page(type: type, body: Data(body.utf8)))
            let page = try await stub.fetcher().fetch(stub.url())
            #expect(page.text == body && page.title == nil, "\(type)")
        }
    }

    @Test func theCharsetInTheHeaderIsRespectedAndUTF8IsTheDefault() async throws {
        let latin = PageStub(.page(type: "text/plain; charset=ISO-8859-1", body: Data([0x63, 0x61, 0x66, 0xE9])))
        #expect(try await latin.fetcher().fetch(latin.url()).text == "café")
        let unlabelled = PageStub(.page(type: "text/plain", body: Data("café".utf8)))
        #expect(try await unlabelled.fetcher().fetch(unlabelled.url()).text == "café")
        let unknown = PageStub(.page(type: "text/plain; charset=made-up", body: Data("café".utf8)))
        #expect(try await unknown.fetcher().fetch(unknown.url()).text == "café")
    }

    @Test func otherContentTypesAreRefusedInPlainWords() async throws {
        for (type, message) in [("application/pdf", "That address is a PDF, not a page of text."),
                                ("image/png", "That address is an image, not a page of text."),
                                ("video/mp4", "That address is a video, not a page of text."),
                                ("application/octet-stream", "That address is a binary file, not a page of text."),
                                ("application/x-shockwave-flash", "That address is not a page of text (application/x-shockwave-flash).")] {
            let stub = PageStub(.page(type: type, body: Data([0, 1, 2])))
            await #expect(throws: FetchRequest.Invalid(message), "\(type)") { try await stub.fetcher().fetch(stub.url()) }
        }
    }

    @Test func aFailureStatusIsAnErrorThatNamesIt() async throws {
        let stub = PageStub(.page(status: 404, body: Data("<p>nope</p>".utf8)))
        let error = await #expect(throws: FetchRequest.Invalid.self) { try await stub.fetcher().fetch(stub.url()) }
        #expect(error?.message.contains("HTTP 404") == true)
    }

    // MARK: Caps

    @Test func theDownloadStopsAtTwoMegabytes() async throws {
        let stub = PageStub(.page(type: "text/plain", body: Data(repeating: UInt8(ascii: "a"), count: 3 * 1024 * 1024)))
        let page = try await stub.fetcher().fetch(stub.url())

        #expect(page.truncated)
        #expect(page.text.utf8.count == PageFetcher.byteLimit && PageFetcher.byteLimit == 2 * 1024 * 1024)
        #expect(page.toolResult.hasSuffix("[The page was cut off here. It has more text than fits.]"))
    }

    @Test func aPageJustUnderTheCapIsNotMarkedCut() async throws {
        let stub = PageStub(.page(type: "text/plain", body: Data(repeating: UInt8(ascii: "a"), count: PageFetcher.byteLimit)))
        #expect(try await stub.fetcher().fetch(stub.url()).truncated == false)
    }

    @Test func theTextTheModelGetsIsCutToTwentyThousandCharactersWithALastLineSayingSo() {
        let long = Page(url: URL(string: "https://example.com/long")!, title: "Long", text: String(repeating: "word ", count: 10_000))
        let result = long.toolResult
        let note = "\n\n[The page was cut off here. It has more text than fits.]"

        #expect(result.hasSuffix(note))
        #expect(result.count - note.count == Page.characterLimit)
        #expect(result.hasPrefix("Title: Long\nURL: https://example.com/long\n\nword word"))

        let short = Page(url: URL(string: "https://example.com/")!, title: nil, text: String(repeating: "x", count: 100))
        #expect(short.toolResult == "URL: https://example.com/\n\n" + String(repeating: "x", count: 100))
    }

    @Test func theLimitCoversTheHeaderToo() async throws {
        let note = "\n\n[The page was cut off here. It has more text than fits.]"
        let huge = Page(url: URL(string: "https://example.com/")!, title: String(repeating: "t", count: 2_000_000), text: "body")
        #expect(huge.toolResult.count == Page.characterLimit + note.count && huge.toolResult.hasSuffix(note))

        let stub = PageStub(.html("<title>" + String(repeating: "a", count: 100_000) + "<p>never reached</p>"))
        let result = try await stub.fetcher().fetch(stub.url()).toolResult
        #expect(result.count < 1_000, "an unclosed title is cut to its own limit, got \(result.count) characters")
    }

    // MARK: Safety on the way

    @Test func aRefusedAddressIsNeverRequested() async throws {
        let stub = PageStub(.html("secret"))
        let recorder = Recorder()
        let fetcher = stub.fetcher(record: recorder.sink)
        for address in ["http://127.0.0.1/", "file:///etc/hosts", "http://u:p@\(stub.host)/", "http://localhost/"] {
            await #expect(throws: FetchRequest.Invalid.self, "\(address)") { try await fetcher.fetch(URL(string: address)!) }
        }
        #expect(stub.requests.isEmpty)
        #expect(recorder.exchanges.isEmpty, "nothing was sent, so there is nothing to inspect")
    }

    @Test func aRedirectToAPrivateHostIsRefusedAndNotFollowed() async throws {
        let router = PageStub(.html("the router's admin page"))
        let stub = PageStub { _ in .redirect(to: "http://10.0.0.5/admin") }
        let recorder = Recorder()

        let error = await #expect(throws: FetchRequest.Invalid.self) { try await stub.fetcher(record: recorder.sink).fetch(stub.url()) }
        #expect(error?.message.contains("redirects to an address that can't be fetched") == true)
        #expect(error?.message.contains("10.0.0.5 is on this device or a private network") == true)
        #expect(router.requests.isEmpty && stub.requests.count == 1)
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.purpose == .fetch && exchange.error == error?.message)
    }

    @Test(arguments: ["http://localhost:8080/", "http://printer.local/", "http://[::1]/", "file:///etc/passwd", "http://2130706433/", "http://user:pw@example.com/"])
    func everyKindOfRefusedAddressIsAlsoRefusedAsARedirectTarget(target: String) async throws {
        let stub = PageStub { _ in .redirect(to: target) }
        await #expect(throws: FetchRequest.Invalid.self) { try await stub.fetcher().fetch(stub.url()) }
    }

    @Test func aRedirectToAPublicPageIsFollowedAndTheFinalAddressReported() async throws {
        let target = PageStub(.html("<title>There</title><p>arrived</p>"))
        let stub = PageStub { _ in .redirect(to: target.url("/final").absoluteString) }
        let recorder = Recorder()
        let page = try await stub.fetcher(record: recorder.sink).fetch(stub.url("/start"))

        #expect(page.url == target.url("/final") && page.text == "arrived")
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.url == stub.url("/start") && exchange.status == 200)
    }

    @Test func aNameThatResolvesToAPrivateAddressIsRefusedBeforeAnythingIsSent() async throws {
        let stub = PageStub(.html("secret"))
        let fetcher = stub.fetcher(resolve: { _ in ["93.184.216.34", "10.1.2.3"] })
        let error = await #expect(throws: FetchRequest.Invalid.self) { try await fetcher.fetch(stub.url()) }
        #expect(error?.message == "\(stub.host) resolves to this device or a private network, so it can't be fetched.")
        #expect(stub.requests.isEmpty)
    }

    @Test func aRedirectTargetThatResolvesToAPrivateAddressIsRefusedToo() async throws {
        let target = PageStub(.html("secret"))
        let stub = PageStub { _ in .redirect(to: target.url().absoluteString) }
        let fetcher = stub.fetcher(resolve: { $0 == target.host ? ["fe80::1%en0"] : ["93.184.216.34"] })
        await #expect(throws: FetchRequest.Invalid.self) { try await fetcher.fetch(stub.url()) }
        #expect(target.requests.isEmpty)
    }

    @Test func aNameThatResolvesToNothingIsRefusedBeforeAnythingIsSent() async throws {
        let stub = PageStub(.html("secret"))
        let error = await #expect(throws: FetchRequest.Invalid.self) { try await stub.fetcher(resolve: { _ in [] }).fetch(stub.url()) }
        #expect(error?.message == "No server was found for \(stub.host).")
        #expect(stub.requests.isEmpty)
    }

    @Test func aRedirectToANameThatResolvesToNothingIsRefusedToo() async throws {
        let target = PageStub(.html("secret"))
        let stub = PageStub { _ in .redirect(to: target.url().absoluteString) }
        let fetcher = stub.fetcher(resolve: { $0 == target.host ? [] : ["93.184.216.34"] })
        await #expect(throws: FetchRequest.Invalid.self) { try await fetcher.fetch(stub.url()) }
        #expect(target.requests.isEmpty)
    }

    @Test func aConnectionToAPrivateAddressMeansTheBodyIsNotReturned() {
        let message = { (address: String) in "The connection went to \(address), which is on this device or a private network, so the page was not read." }
        #expect(PageFetcher.refusal(connectedTo: "127.0.0.1", viaProxy: false) == message("127.0.0.1"))
        #expect(PageFetcher.refusal(connectedTo: "100.100.100.100", viaProxy: false) == message("100.100.100.100"))
        #expect(PageFetcher.refusal(connectedTo: "fe80::1%en0", viaProxy: false) == message("fe80::1%en0"))
        #expect(PageFetcher.refusal(connectedTo: "::ffff:10.0.0.1", viaProxy: false) == message("::ffff:10.0.0.1"))
    }

    @Test func aPublicOrUnknownOrProxiedConnectionIsFine() {
        #expect(PageFetcher.refusal(connectedTo: "93.184.216.34", viaProxy: false) == nil)
        #expect(PageFetcher.refusal(connectedTo: "2606:4700::1111", viaProxy: false) == nil)
        #expect(PageFetcher.refusal(connectedTo: nil, viaProxy: false) == nil, "nothing to judge")
        #expect(PageFetcher.refusal(connectedTo: "127.0.0.1", viaProxy: true) == nil, "that is the proxy's address, not the page's")
    }

    @Test func theSystemResolverFindsLocalhostAndGivesNothingForANameThatDoesNotExist() async {
        let local = await PageFetcher.systemResolve("localhost")
        #expect(!local.isEmpty && local.allSatisfy(FetchRequest.isPrivate(host:)), "\(local)")
        #expect(await PageFetcher.systemResolve("nothing-here-\(UUID().uuidString.lowercased()).invalid").isEmpty)
    }

    // MARK: Inspector

    @Test func everyFetchIsReportedAsAPageRequestWithItsHeadersAndTheStartOfTheBody() async throws {
        let stub = PageStub(.html("<title>T</title><p>hello</p>"))
        let recorder = Recorder()
        _ = try await stub.fetcher(record: recorder.sink).fetch(stub.url("/p"))

        let exchange = try #require(recorder.exchanges.first)
        #expect(recorder.exchanges.count == 1)
        #expect(exchange.purpose == .fetch && exchange.method == "GET" && exchange.url == stub.url("/p"))
        #expect(exchange.status == 200 && exchange.error == nil && exchange.finishedAt != nil)
        #expect(exchange.requestHeader("User-Agent") == "LMChat/1.0" && exchange.requestHeader("Authorization") == nil)
        #expect(exchange.responseHeaders.contains(.init(name: "Content-Type", value: "text/html; charset=utf-8")))
        #expect(exchange.responseHeaders.contains(.init(name: "Set-Cookie", value: "<redacted>")))
        #expect(exchange.responseBody == "<title>T</title><p>hello</p>")
        #expect(!exchange.isEditable, "a GET has no body to edit and resend")
    }

    @Test func aBigPageIsKeptInTheInspectorOnlyToTheUsualLimit() async throws {
        let stub = PageStub(.page(type: "text/plain", body: Data(repeating: UInt8(ascii: "a"), count: 1_000_000)))
        let recorder = Recorder()
        _ = try await stub.fetcher(record: recorder.sink).fetch(stub.url())

        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.responseBody.utf8.count == Exchange.bodyLimit && exchange.responseTruncated)
    }

    @Test func aFailureIsReportedWithItsStatusAndMessage() async throws {
        let stub = PageStub(.page(status: 503, body: Data()))
        let recorder = Recorder()
        _ = try? await stub.fetcher(record: recorder.sink).fetch(stub.url())

        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.status == 503 && exchange.error != nil)
    }
}
