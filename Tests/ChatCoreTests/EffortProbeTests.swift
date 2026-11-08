import Testing
@testable import ChatCore

struct EffortProbeTests {
    private static let ok: StubServer.Reply = (200, #"{"choices":[{"message":{"content":"H"}}]}"#)

    @Test func reportsTheLevelsTheServerAccepts() async throws {
        let server = StubServer { body in
            ["none", "low", "medium", "xhigh"].contains(body["reasoning_effort"] as? String ?? "")
                ? Self.ok
                : (400, #"{"error":{"message":"Unexpected reasoning effort"}}"#)
        }
        #expect(try await server.client.reasoningEfforts(model: "m") == [.none, .low, .medium, .xhigh])
        #expect(server.bodies.allSatisfy { $0["max_completion_tokens"] as? Int == 1 && $0["stream"] as? Bool == false },
                "each probe asks for a single token")
    }

    @Test func aLevelCutOffByTheTokenLimitStillCounts() async throws {
        let server = StubServer { body in
            ["low", "medium", "high"].contains(body["reasoning_effort"] as? String ?? "")
                ? (400, #"{"error":{"message":"Could not finish the message because max_tokens or model output limit was reached."}}"#)
                : (400, #"{"error":{"message":"Unsupported value: 'reasoning_effort' does not support this value.","param":"reasoning_effort"}}"#)
        }
        #expect(try await server.client.reasoningEfforts(model: "m") == [.low, .medium, .high])
    }

    @Test func aModelWithoutTheFieldHasNoLevels() async throws {
        let server = StubServer { _ in (400, #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#) }
        #expect(try await server.client.reasoningEfforts(model: "m") == [])
    }

    @Test func aServerThatIgnoresTheFieldHasNoLevels() async throws {
        let server = StubServer { _ in Self.ok }
        #expect(try await server.client.reasoningEfforts(model: "m") == [])
    }

    @Test func aFailureOtherThanRejectionIsAnError() async {
        let server = StubServer { _ in (401, #"{"error":{"message":"bad key"}}"#) }
        await #expect(throws: ChatClientError.self) { try await server.client.reasoningEfforts(model: "m") }
    }

    @Test func sendsTheSavedLevelWhenTheModelAcceptsIt() {
        #expect(ReasoningEffort.choice(preferred: .low, supported: [.none, .low, .medium, .xhigh]) == .low)
    }

    @Test func otherwiseSendsTheMiddleLevel() {
        #expect(ReasoningEffort.choice(preferred: .high, supported: [.none, .low, .medium, .xhigh]) == .medium)
        #expect(ReasoningEffort.choice(preferred: nil, supported: [.low, .medium, .xhigh]) == .medium)
    }

    @Test func sendsNothingWhenTheModelHasNoLevels() {
        #expect(ReasoningEffort.choice(preferred: .low, supported: []) == nil)
    }
}
