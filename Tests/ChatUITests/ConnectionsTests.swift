import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ConnectionsTests {
    private func connection(_ name: String, _ url: String, model: String = "", prompt: String = "") -> Connection {
        Connection(name: name, baseURL: URL(string: url)!, model: model, systemPrompt: prompt)
    }

    @Test func theSingleSavedServerBecomesTheFirstConnection() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let secrets = Secrets.memory()
        defaults.set("box.lan:8000", forKey: "baseURL")
        defaults.set("qwen", forKey: "model")
        defaults.set("Be brief.", forKey: "systemPrompt")
        secrets.set("apiKey", "sk-local")

        let store = ChatStore(defaults: defaults, fileURL: file, secrets: secrets)
        #expect(store.connections.map(\.name) == ["box.lan:8000"])
        #expect(store.config == ServerConfig(baseURL: URL(string: "http://box.lan:8000/v1")!, apiKey: "sk-local"))
        #expect(store.model == "qwen")
        #expect(store.systemPrompt == "Be brief.")

        let reopened = ChatStore(defaults: defaults, fileURL: file, secrets: secrets)
        #expect(reopened.connections == store.connections, "migration runs once")
        #expect(reopened.config == store.config)
    }

    @Test func switchingConnectionsSwitchesServerKeyModelAndPrompt() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let secrets = Secrets.memory()
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: secrets)
        let local = connection("Local", "http://box.lan:8000/v1", model: "qwen", prompt: "Local prompt")
        let cloud = connection("Cloud", "https://api.example.com/v1", model: "big-model")
        store.saveConnection(local, apiKey: "")
        store.saveConnection(cloud, apiKey: "sk-cloud")
        #expect(store.activeConnectionID == cloud.id, "a newly added connection becomes active")
        #expect(store.config?.apiKey == "sk-cloud")
        #expect(store.model == "big-model")

        store.activate(local.id)
        #expect(store.config == ServerConfig(baseURL: local.baseURL, apiKey: nil))
        #expect(store.model == "qwen")
        #expect(store.systemPrompt == "Local prompt")

        let reopened = ChatStore(defaults: defaults, fileURL: file, secrets: secrets)
        #expect(reopened.activeConnection?.name == "Local", "active connection persists")
        reopened.activate(cloud.id)
        #expect(reopened.config?.apiKey == "sk-cloud", "each key persists with its connection")
    }

    @Test func pickingAModelOnlyChangesTheActiveConnection() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        let local = connection("Local", "http://box.lan:8000/v1", model: "qwen")
        let cloud = connection("Cloud", "https://api.example.com/v1", model: "big-model")
        store.saveConnection(local, apiKey: "")
        store.saveConnection(cloud, apiKey: "")

        store.selectModel("small-model")
        store.activate(local.id)
        #expect(store.model == "qwen")
        store.activate(cloud.id)
        #expect(store.model == "small-model")
    }

    @Test func deletingTheActiveConnectionFallsBackAndForgetsItsKey() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let secrets = Secrets.memory()
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: secrets)
        let local = connection("Local", "http://box.lan:8000/v1")
        let cloud = connection("Cloud", "https://api.example.com/v1")
        store.saveConnection(local, apiKey: "")
        store.saveConnection(cloud, apiKey: "sk-cloud")

        store.deleteConnection(cloud.id)
        #expect(store.connections.map(\.name) == ["Local"])
        #expect(store.activeConnectionID == local.id)
        #expect(secrets.get(cloud.secretAccount) == nil)

        store.deleteConnection(local.id)
        #expect(store.activeConnection == nil)
        #expect(!store.isConfigured)
    }
}
