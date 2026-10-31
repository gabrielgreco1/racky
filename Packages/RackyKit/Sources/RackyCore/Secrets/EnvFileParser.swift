import Foundation

public struct EnvEntry: Equatable, Sendable {
    public let name: String
    public let value: String
    public let line: Int
}

public struct EnvParseResult: Equatable, Sendable {
    public let entries: [EnvEntry]
    public let duplicateNames: [String]
}

public enum EnvParseError: Error, LocalizedError, Equatable {
    case tooLarge
    case invalidUTF8
    case invalidLine(Int)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The .env file exceeds 1 MB."
        case .invalidUTF8: return "The .env file must be UTF-8."
        case .invalidLine(let line): return "Unsupported .env syntax on line \(line). Nothing was imported."
        }
    }
}

/// A deliberately strict data parser. It never invokes a shell, expands variables or evaluates commands.
public enum EnvFileParser {
    public static func read(_ url: URL) throws -> EnvParseResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw EnvParseError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw EnvParseError.tooLarge }
        guard let content = String(data: data, encoding: .utf8) else { throw EnvParseError.invalidUTF8 }
        return try parse(content)
    }

    public static func parse(_ content: String) throws -> EnvParseResult {
        var entries: [EnvEntry] = []
        var seen: Set<String> = [], duplicates: Set<String> = []
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (offset, rawLine) in lines.enumerated() {
            let number = offset + 1
            guard !rawLine.contains("\0") else { throw EnvParseError.invalidLine(number) }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var input = line
            if input.hasPrefix("export ") { input = String(input.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = input.firstIndex(of: "=") else { throw EnvParseError.invalidLine(number) }
            let name = String(input[..<equals]).trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw EnvParseError.invalidLine(number)
            }
            let rawValue = String(input[input.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let value: String
            if rawValue.hasPrefix("'") {
                guard rawValue.count >= 2, rawValue.hasSuffix("'") else { throw EnvParseError.invalidLine(number) }
                value = String(rawValue.dropFirst().dropLast())
                if value.contains("'") { throw EnvParseError.invalidLine(number) }
            } else if rawValue.hasPrefix("\"") {
                guard rawValue.count >= 2, rawValue.hasSuffix("\"") else { throw EnvParseError.invalidLine(number) }
                value = try decodeDoubleQuoted(String(rawValue.dropFirst().dropLast()), line: number)
            } else {
                guard !rawValue.contains("\0"), !rawValue.contains("\"") && !rawValue.contains("'") else {
                    throw EnvParseError.invalidLine(number)
                }
                value = rawValue
            }
            entries.append(EnvEntry(name: name, value: value, line: number))
            if !seen.insert(name).inserted { duplicates.insert(name) }
        }
        return EnvParseResult(entries: entries, duplicateNames: duplicates.sorted())
    }

    private static func decodeDoubleQuoted(_ value: String, line: Int) throws -> String {
        var result = ""
        var escaping = false
        for char in value {
            if escaping {
                switch char {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: throw EnvParseError.invalidLine(line)
                }
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "\"" || char == "\0" {
                throw EnvParseError.invalidLine(line)
            } else {
                result.append(char)
            }
        }
        if escaping { throw EnvParseError.invalidLine(line) }
        return result
    }
}
