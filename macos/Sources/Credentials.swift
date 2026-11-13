import Foundation
import Security
import Darwin

/// The local development app uses a user-only credential file so rebuilding its
/// ad-hoc signature cannot trigger keychain approval dialogs on every update.
/// Credentials are outside the app bundle, SQLite database and data exports.
enum Credentials {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.jexceed.tinytales", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("connection.key") }
    private static let legacyServices = ["com.jexceed.tinytales.openai.saved", "com.jexceed.tinytales.openai.persistent", "com.jexceed.tinytales.openai"]
    static func load() -> String? {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return key }
        return readSavedKey()
    }
    static func hasPersistentKey() -> Bool { readSavedKey() != nil }
    private static func valid(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count > 30 && key.count <= 1024 && key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    private static func readSavedKey() -> String? {
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { return nil }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1025, info.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return valid(key) ? key : nil
    }
    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(trimmed) else { throw PartnerError.message("密钥格式不完整，请重新检查。") }
        let manager = FileManager.default
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw PartnerError.message("连接配置目录不可用。") }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".connection-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PartnerError.message("未能保存本机连接。") }
        defer { close(descriptor); unlink(temporary.path) }
        let data = Data((trimmed + "\n").utf8)
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let start = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, start.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
        guard written, fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw PartnerError.message("未能保存本机连接。") }
    }
    /// Legacy keychain recovery is an explicit settings action, never a launch step.
    static func authorizeSavedKey() -> String? {
        if let key = load() { return key }
        for service in legacyServices {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var value: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8), valid(key) { try? save(key); return key }
        }
        return nil
    }
    static func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        for service in legacyServices {
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PartnerError.message("本机连接已清除，但旧版钥匙串副本未能删除。") }
        }
    }
}
