import Foundation

public protocol ThreadStore: Sendable {
    func listThreads() async throws -> [AgentThread]
    func loadThread(id: String) async throws -> AgentThread?
    func saveThread(_ thread: AgentThread) async throws
    func deleteThread(id: String) async throws
}

public actor InMemoryThreadStore: ThreadStore {
    private var threads: [String: AgentThread]

    public init(threads: [AgentThread] = []) {
        self.threads = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
    }

    public func listThreads() async throws -> [AgentThread] {
        threads.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadThread(id: String) async throws -> AgentThread? {
        threads[id]
    }

    public func saveThread(_ thread: AgentThread) async throws {
        threads[thread.id] = thread
    }

    public func deleteThread(id: String) async throws {
        threads.removeValue(forKey: id)
    }
}

public actor JSONFileThreadStore: ThreadStore {
    public let directoryURL: URL

    public init(directoryURL: URL = CodexDefaultLocations.coreDirectory.appendingPathComponent("threads", isDirectory: true)) {
        self.directoryURL = directoryURL
    }

    public func listThreads() async throws -> [AgentThread] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var threads: [AgentThread] = []
        for url in urls {
            if let thread = try? loadThreadFile(url) { threads.append(thread) }
        }
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadThread(id: String) async throws -> AgentThread? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadThreadFile(url)
    }

    public func saveThread(_ thread: AgentThread) async throws {
        try ensureDirectory()
        let data = try JSONEncoder.codexPretty.encode(thread)
        try data.write(to: fileURL(for: thread.id), options: [.atomic])
    }

    public func deleteThread(id: String) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: String) -> URL {
        directoryURL.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func loadThreadFile(_ url: URL) throws -> AgentThread {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.codex.decode(AgentThread.self, from: data)
    }
}

public actor ThreadManager {
    private let store: any ThreadStore

    public init(store: any ThreadStore = InMemoryThreadStore()) {
        self.store = store
    }

    public func createThread(title: String? = nil, parentThreadID: String? = nil, metadata: [String: JSONValue] = [:]) async throws -> AgentThread {
        let thread = AgentThread(title: title, parentThreadID: parentThreadID, metadata: metadata)
        try await store.saveThread(thread)
        return thread
    }

    public func listThreads(includeArchived: Bool = false) async throws -> [AgentThread] {
        let threads = try await store.listThreads()
        return includeArchived ? threads : threads.filter { $0.status == .active }
    }

    public func getThread(id: String) async throws -> AgentThread {
        guard let thread = try await store.loadThread(id: id) else { throw CodexCoreError.missingThread(id) }
        return thread
    }

    @discardableResult
    public func appendItem(_ item: ThreadItem, to threadID: String) async throws -> AgentThread {
        var thread = try await getThread(id: threadID)
        thread.items.append(item)
        thread.updatedAt = Date()
        try await store.saveThread(thread)
        return thread
    }

    @discardableResult
    public func appendItems(_ items: [ThreadItem], to threadID: String) async throws -> AgentThread {
        var thread = try await getThread(id: threadID)
        thread.items.append(contentsOf: items)
        thread.updatedAt = Date()
        try await store.saveThread(thread)
        return thread
    }

    public func replaceThread(_ thread: AgentThread) async throws {
        var newThread = thread
        newThread.updatedAt = Date()
        try await store.saveThread(newThread)
    }

    public func archiveThread(id: String) async throws {
        var thread = try await getThread(id: id)
        thread.status = .archived
        thread.updatedAt = Date()
        try await store.saveThread(thread)
    }

    public func unarchiveThread(id: String) async throws {
        var thread = try await getThread(id: id)
        thread.status = .active
        thread.updatedAt = Date()
        try await store.saveThread(thread)
    }

    public func forkThread(id: String, title: String? = nil) async throws -> AgentThread {
        let source = try await getThread(id: id)
        var fork = AgentThread(title: title ?? source.title, parentThreadID: source.id, items: source.items, metadata: source.metadata)
        fork.metadata["forked_from"] = .string(source.id)
        try await store.saveThread(fork)
        return fork
    }

    public func rollbackThread(id: String, toItemID itemID: String) async throws -> AgentThread {
        var thread = try await getThread(id: id)
        guard let index = thread.items.firstIndex(where: { $0.id == itemID }) else {
            throw CodexCoreError.invalidState("Item \(itemID) not found in thread \(id)")
        }
        thread.items = Array(thread.items.prefix(through: index))
        thread.updatedAt = Date()
        try await store.saveThread(thread)
        return thread
    }

    public func deleteThread(id: String) async throws {
        try await store.deleteThread(id: id)
    }
}
