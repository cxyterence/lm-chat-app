import Foundation
import Testing
@testable import ChatCore

struct CapabilityTests {
    private static let key = "sk-stub-secret-123"
    private static let ok: StubServer.Reply = (200, #"{"choices":[{"message":{"content":"H"}}]}"#)
    private static let lunaRefusal: StubServer.Reply = (400, #"""
        {"error":{"message":"Function tools with reasoning_effort are not supported for gpt-6-luna in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'.","type":"invalid_request_error","param":"reasoning_effort"}}
        """#)

    private static func isVision(_ body: [String: Any]) -> Bool {
        let messages = body["messages"] as? [[String: Any]]
        return messages?.contains { $0["content"] is [Any] } == true
    }

    /// A server that takes tools and pictures, and reasoning levels none, low and medium.
    private static func plain(_ body: [String: Any]) -> StubServer.Reply {
        if body["tools"] != nil || isVision(body) { return ok }
        let effort = body["reasoning_effort"] as? String
        return effort == nil || ["none", "low", "medium"].contains(effort) ? ok : (400, #"{"error":{"message":"Unexpected reasoning effort"}}"#)
    }

    @Test func aServerThatTakesEverythingSaysSoAndReportsWhatTheModelListHolds() async throws {
        let server = StubServer(route: { path, body in
            if path.hasSuffix("/models") {
                return (200, #"{"data":[{"id":"other"},{"id":"m","max_model_len":32768,"owned_by":"vllm","meta":{"n_vocab":1000,"api_key":"x"}}]}"#)
            }
            if path.hasSuffix("/server_info") { return (404, #"{"detail":"Not Found"}"#) }
            return Self.plain(body)
        })
        let report = try await server.client.capabilities(model: "m")

        #expect(report == CapabilityReport(tools: .yes, vision: .yes, efforts: [.none, .low, .medium], contextLength: 32768, server: [
            Fact(name: "max_model_len", value: "32768"), Fact(name: "meta.n_vocab", value: "1000"), Fact(name: "owned_by", value: "vllm"),
        ]))

        let tools = try #require(server.bodies.first { $0["tools"] != nil })
        #expect(tools["max_completion_tokens"] as? Int == 1 && tools["stream"] as? Bool == false)
        #expect((tools["tools"] as? [[String: Any]])?.first?["type"] as? String == "function")
        let picture = try #require(server.bodies.first { Self.isVision($0) })
        #expect(picture["max_completion_tokens"] as? Int == 1 && picture["stream"] as? Bool == false)
        let message = try #require((picture["messages"] as? [[String: Any]])?.first)
        let url = try #require(((message["content"] as? [[String: Any]])?.first?["image_url"] as? [String: Any])?["url"] as? String)
        let jpeg = try #require(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        #expect(url.hasPrefix("data:image/jpeg;base64,") && ImageAttachment.dimensions(of: jpeg)?.width == 64)
    }

    @Test func aModelThatRefusesToolsUnlessReasoningIsOffIsToldApartFromOneWithoutTools() async throws {
        let server = StubServer { body in
            body["tools"] != nil && body["reasoning_effort"] as? String != "none" ? Self.lunaRefusal : Self.plain(body)
        }
        let report = try await server.client.capabilities(model: "gpt-6-luna")
        #expect(report.tools == .onlyWithReasoningOff)
        #expect(server.bodies.contains { $0["tools"] != nil && $0["reasoning_effort"] as? String == "none" },
                "the refusal is confirmed by asking again with reasoning off")
    }

    @Test func aModelThatTakesToolsUntilALevelIsSentIsCaughtToo() async throws {
        let server = StubServer { body in
            body["tools"] != nil && ["low", "medium"].contains(body["reasoning_effort"] as? String) ? Self.lunaRefusal : Self.plain(body)
        }
        #expect(try await server.client.capabilities(model: "m").tools == .onlyWithReasoningOff)
    }

    @Test func aModelThatRefusesToolsWhateverTheReasoningIsHasNone() async throws {
        let server = StubServer { body in
            guard body["tools"] != nil else { return Self.plain(body) }
            return body["reasoning_effort"] as? String == "none"
                ? (400, #"{"error":{"message":"this model does not support tools"}}"#) : Self.lunaRefusal
        }
        #expect(try await server.client.capabilities(model: "m").tools == .no(reason: "this model does not support tools"))
    }

    @Test func aPlainRefusalNamingToolsIsNo() async throws {
        let server = StubServer { body in
            body["tools"] != nil ? (400, #"{"error":{"message":"\"auto\" tool choice requires --enable-auto-tool-choice"}}"#) : Self.plain(body)
        }
        let report = try await server.client.capabilities(model: "m")
        #expect(report.tools == .no(reason: #""auto" tool choice requires --enable-auto-tool-choice"#))
        #expect(report.vision == .yes, "one refusal doesn't spill onto the other probes")
    }

    @Test func aTokenLimitErrorIsNotARefusal() async throws {
        let cutOff: StubServer.Reply = (400, #"{"error":{"message":"Could not finish the message because max_tokens or model output limit was reached."}}"#)
        let server = StubServer { body in body["tools"] != nil || Self.isVision(body) ? cutOff : Self.plain(body) }
        let report = try await server.client.capabilities(model: "m")
        #expect(report.tools == .yes && report.vision == .yes)
    }

    @Test func aModelWithoutVisionSaysWhatTheServerSaid() async throws {
        let refusal = "Invalid content type. image_url is only supported by certain models."
        let server = StubServer { body in
            Self.isVision(body) ? (400, #"{"error":{"message":"\#(refusal)"}}"#) : Self.plain(body)
        }
        let report = try await server.client.capabilities(model: "m")
        #expect(report.vision == .no(reason: refusal))
        #expect(report.tools == .yes)
    }

    @Test func aProbeThatFailsAloneIsUnknownNotNo() async throws {
        let server = StubServer { body in
            body["tools"] != nil ? (500, #"{"error":{"message":"boom"}}"#) : Self.plain(body)
        }
        let report = try await server.client.capabilities(model: "m")
        #expect(report.tools == .unknown(reason: "HTTP 500: boom"))
        #expect(report.efforts == [.none, .low, .medium])
    }

    @Test func aServerThatCantBeUsedAtAllThrows() async {
        let server = StubServer { _ in (401, #"{"error":{"message":"bad key"}}"#) }
        await #expect(throws: ChatClientError.http(status: 401, message: "bad key")) {
            try await server.client.capabilities(model: "m")
        }
    }

    @Test func serverInfoSitsBesideV1AndLeavesOutKeys() async throws {
        let info = """
            {"version":"0.5.1","model_path":"/models/x","tp_size":2,"max_total_num_tokens":123456,"disable_radix_cache":false,
             "api_key":"\(Self.key)","admin_api_key":"sk-admin","hf_token":"hf_abc","ssl_keyfile":"/k.pem","note":"\(Self.key)",
             "internal_states":[{"a":1}],"deep":{"a":{"b":{"c":1}}},"gone":null}
            """
        let server = StubServer(route: { path, body in
            path.hasSuffix("/server_info") ? (200, info) : path.hasSuffix("/models") ? (404, "{}") : Self.plain(body)
        })
        let report = try await server.makeClient(apiKey: Self.key).capabilities(model: "m")

        #expect(server.requests.contains { $0.path == "/server_info" })
        #expect(report.server == [
            Fact(name: "disable_radix_cache", value: "false"), Fact(name: "max_total_num_tokens", value: "123456"),
            Fact(name: "model_path", value: "/models/x"), Fact(name: "tp_size", value: "2"), Fact(name: "version", value: "0.5.1"),
        ])
        #expect(report.server.allSatisfy { !$0.name.contains(Self.key) && !$0.value.contains(Self.key) })
        #expect(report.contextLength == nil)
    }

    @Test func contextLengthIsReadFromTheKeysServersUse() async throws {
        let entries = [
            (#"{"id":"m","max_model_len":8192}"#, 8192),
            (#"{"id":"m","context_length":16000}"#, 16000),
            (#"{"id":"m","meta":{"n_ctx_train":131072}}"#, 131072),
        ]
        for (entry, length) in entries {
            let server = StubServer { _ in (200, #"{"data":[\#(entry)]}"#) }
            #expect(try await server.client.capabilities(model: "m").contextLength == length)
        }
    }

    @Test func theProbesAreReportedWithTheirOwnPurposeAndNeverTheKey() async throws {
        let server = StubServer { Self.plain($0) }
        let recorder = Recorder()
        _ = try await server.makeClient(apiKey: Self.key, record: recorder.sink).capabilities(model: "m")
        let exchanges = recorder.exchanges
        #expect(Set(exchanges.map(\.purpose)) == [.probe, .models])
        #expect(exchanges.allSatisfy { !"\($0)".contains(Self.key) })
    }
}
