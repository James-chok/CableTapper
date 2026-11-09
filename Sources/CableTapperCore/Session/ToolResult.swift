import Foundation

public struct ToolResult: Sendable {
    public var text: String
    public var jpegData: Data?
    public var isError: Bool

    public init(text: String, jpegData: Data? = nil, isError: Bool = false) {
        self.text = text
        self.jpegData = jpegData
        self.isError = isError
    }

    public static func ok(_ text: String, jpeg: Data? = nil) -> ToolResult {
        ToolResult(text: text, jpegData: jpeg, isError: false)
    }

    public static func fail(_ text: String, jpeg: Data? = nil) -> ToolResult {
        ToolResult(text: text, jpegData: jpeg, isError: true)
    }
}

public struct ToolCall: Sendable {
    public var name: String
    public var arguments: [String: ToolValue]

    public init(name: String, arguments: [String: ToolValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

public enum ToolValue: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)

    public var stringValue: String? {
        switch self {
        case .string(let v): v
        case .int(let v): String(v)
        case .bool(let v): String(v)
        case .double(let v): String(v)
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): v
        case .string(let v): Int(v)
        case .double(let v): Int(v)
        case .bool: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): v
        case .string(let v): ["true", "1", "yes"].contains(v.lowercased())
        default: nil
        }
    }
}
