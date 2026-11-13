import Foundation

/// Decode only the reply string from an incomplete structured JSON response.
enum PartialReply {
    static func text(in raw: String) -> String? {
        let characters = Array(raw); var index = 0, depth = 0
        while index < characters.count {
            let c = characters[index]
            if c == "{" || c == "[" { depth += 1; index += 1; continue }
            if c == "}" || c == "]" { depth -= 1; index += 1; continue }
            guard c == "\"" else { index += 1; continue }
            let start = index; index += 1; var escaped = false
            while index < characters.count {
                let value = characters[index]
                if !escaped && value == "\"" { break }
                if !escaped && value == "\\" { escaped = true } else { escaped = false }
                index += 1
            }
            guard index < characters.count else { return nil }
            let token = String(characters[start...index]); index += 1
            if depth != 1 || token != "\"reply\"" { continue }
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            guard index < characters.count && characters[index] == ":" else { continue }; index += 1
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            guard index < characters.count && characters[index] == "\"" else { return nil }
            index += 1; let begin = index; escaped = false
            while index < characters.count {
                let value = characters[index]
                if !escaped && value == "\"" { break }
                if !escaped && value == "\\" { escaped = true } else { escaped = false }
                index += 1
            }
            var encoded = String(characters[begin..<index])
            // A delta may end inside an escape or UTF-16 pair. Keep the last
            // decodable prefix; never show JSON punctuation or half an escape.
            for _ in 0..<13 {
                if let data = ("[\"" + encoded + "\"]").data(using: .utf8), let result = try? JSONDecoder().decode([String].self, from: data) { return result.first }
                guard !encoded.isEmpty else { return "" }; encoded.removeLast()
            }
            return nil
        }
        return nil
    }
    static func completeSentences(in text: String) -> String {
        guard let boundary = text.lastIndex(where: { "。！？!?；;\n".contains($0) }) else { return "" }
        return String(text[...boundary])
    }
}

struct ResponseEvents {
    var rawText = ""
    var completed: [String: Any]?
    mutating func receive(_ event: [String: Any]) throws -> String? {
        switch event["type"] as? String {
        case "response.output_text.delta":
            rawText += event["delta"] as? String ?? ""
            return PartialReply.text(in: rawText)
        case "response.completed": completed = event["response"] as? [String: Any]
        case "response.failed", "response.incomplete", "error": throw PartnerError.message("这句话暂时没有接上，请再试一次。")
        default: break
        }
        return nil
    }
}

/// AsyncBytes.lines can omit empty lines. OpenAI emits one complete JSON object
/// per data line, so decode complete objects immediately rather than waiting for
/// an empty separator that may never arrive.
struct OpenAIEventLines {
    private var pending: [String] = []
    mutating func receive(_ line: String) throws -> [String: Any]? {
        if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5)).trimmingCharacters(in:.whitespaces)
            if value == "[DONE]" { pending.removeAll(); return nil }
            pending.append(value)
            if let object = try? jsonObject(pending.joined(separator:"\n")) { pending.removeAll(); return object }
        } else if line.isEmpty && !pending.isEmpty {
            let value = pending.joined(separator:"\n"); pending.removeAll(); return try jsonObject(value)
        }
        return nil
    }
}
