import Foundation
import SQLite3

final class LocalStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var revision = 0
    // A targeted deletion must not invalidate unrelated active conversations.
    // In-flight tools still cannot write a deleted story back in this process.
    private var deletedStoryIDs: Set<String> = []
    let url: URL
    init(url: URL? = nil) throws {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.jexceed.tinytales/tinytales.sqlite")
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(self.url.path, &database) == SQLITE_OK else { throw PartnerError.message("小屋的数据暂时打不开。") }
        try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS stories (id TEXT PRIMARY KEY, json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS settings (id TEXT PRIMARY KEY, json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS usage (id TEXT PRIMARY KEY, json TEXT NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw PartnerError.message("本机数据没有保存成功，请再试一次。") }
    }
    private func write<T: Encodable>(_ table: String, id: String, value: T) throws {
        guard ["memories", "stories", "settings", "usage"].contains(table) else { throw PartnerError.message("无法保存这类数据。") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO \(table) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", -1, &statement, nil) == SQLITE_OK else { throw PartnerError.message("本机数据暂时无法写入。") }
        defer { sqlite3_finalize(statement) }
        let json = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        sqlite3_bind_text(statement, 1, id, -1, transient); sqlite3_bind_text(statement, 2, json, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw PartnerError.message("本机数据没有保存成功。") }
    }
    private func read<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        guard ["memories", "stories", "settings", "usage"].contains(table) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT json FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw PartnerError.message("本机数据暂时无法读取。") }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0), let data = String(cString: c).data(using: .utf8) { result.append(try JSONDecoder().decode(T.self, from: data)) }
        }
        return result
    }
    func memories() throws -> [Memory] { try read("memories", as: Memory.self).sorted { $0.createdAt > $1.createdAt } }
    func stories() throws -> [Story] { try read("stories", as: Story.self).sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt } }
    func settings() throws -> PartnerSettings { try read("settings", as: PartnerSettings.self).first ?? PartnerSettings() }
    func setSettings(_ settings: PartnerSettings) throws {
        let old = try self.settings()
        try write("settings", id: "main", value: settings)
        if old.memoryEnabled != settings.memoryEnabled || old.english != settings.english || old.sessionMinutes != settings.sessionMinutes { revision += 1 }
    }
    func remember(_ memory: Memory) throws {
        guard Safety.mayRemember(memory.text), Safety.mayRemember(memory.evidence), ["interest", "word", "english"].contains(memory.kind), ["pending", "approved"].contains(memory.status) else { throw PartnerError.message("请只保存非隐私的兴趣与词汇，不保存身份信息或能力判断。") }
        let existing = try memories()
        if existing.contains(where: { $0.text == memory.text && $0.id != memory.id }) { return }
        guard existing.count < 60 || existing.contains(where: { $0.id == memory.id }) else { throw PartnerError.message("记忆小花园已经满了，请先整理一下。") }
        try write("memories", id: memory.id, value: memory)
    }
    func editMemory(_ memory: Memory) throws { try remember(memory); revision += 1 }
    func saveStory(_ story: Story) throws {
        guard !deletedStoryIDs.contains(story.id) else { throw PartnerError.message("这个故事已删除，请开始新的对话。") }
        guard !story.title.isEmpty, story.title.count <= 35, !story.summary.isEmpty, story.summary.count <= 5000, !Safety.isPrivate(story.title + story.summary), !Safety.isRisk(story.title + story.summary) else { throw PartnerError.message("故事摘要中有不适合保存的内容。") }
        try write("stories", id: story.id, value: story)
        for s in try stories().dropFirst(20) { try delete("stories", id: s.id, invalidate: false) }
    }
    func delete(_ table: String, id: String, invalidate: Bool = true) throws {
        guard ["memories", "stories"].contains(table) else { return }
        var statement: OpaquePointer?; sqlite3_prepare_v2(database, "DELETE FROM \(table) WHERE id=?", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw PartnerError.message("删除没有完成，请再试一次。") }
        if table == "stories" { ArtworkArchive.clear(storyID:id) }
        if invalidate { revision += 1 }
    }
    func deleteConversationStories(_ ids: Set<String>, preservingArtworkIDs: Set<String> = []) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids.sorted() {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database,"DELETE FROM stories WHERE id=?",-1,&statement,nil) == SQLITE_OK else { throw PartnerError.message("删除没有完成，请再试一次。") }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement,1,id,-1,transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw PartnerError.message("删除没有完成，请再试一次。") }
            }
        }
        deletedStoryIDs.formUnion(ids)
        for id in ids { ArtworkArchive.clear(storyID:id,keepingIDs:preservingArtworkIDs) }
    }
    func clear() throws { try execute("DELETE FROM memories; DELETE FROM stories; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"); ArtworkArchive.clear(); revision += 1 }
    func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try block(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    struct Usage: Codable { var day: String; var operations = 0; var inputTokens = 0; var outputTokens = 0 }
    func usage() throws -> Usage {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Singapore"); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        return try read("usage", as: Usage.self).first(where: { $0.day == day }) ?? Usage(day: day)
    }
    func recordCloudOperation() throws {
        var u = try usage()
        u.operations += 1; try write("usage", id: "current", value: u)
    }
    func account(input: Int, output: Int) throws { var u = try usage(); u.inputTokens += input; u.outputTokens += output; try write("usage", id: "current", value: u) }
    func export() throws -> Data {
        struct Export: Encodable { var memories: [Memory]; var stories: [Story]; var settings: PartnerSettings }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(memories: memories(), stories: stories(), settings: settings()))
    }
}
