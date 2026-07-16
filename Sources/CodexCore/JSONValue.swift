import Foundation

/// A small Codable/Sendable representation for arbitrary JSON.
public enum JSONValue: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .number(Double(value))
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      if let integer = Int64(exactly: value) {
        try container.encode(integer)
      } else {
        try container.encode(value)
      }
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public var description: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return String(value)
    case .number(let value):
      if let integer = Int64(exactly: value) { return String(integer) }
      return String(value)
    case .string(let value): return value
    case .array, .object:
      guard let data = try? JSONEncoder.codexCompact.encode(self),
        let string = String(data: data, encoding: .utf8)
      else { return "<json>" }
      return string
    }
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    get {
      guard case .object(let object) = self else { return nil }
      return object[key]
    }
    set {
      guard case .object(var object) = self else { return }
      object[key] = newValue
      self = .object(object)
    }
  }

  public static func object(_ pairs: (String, JSONValue?)...) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for (key, value) in pairs {
      if let value { object[key] = value }
    }
    return .object(object)
  }

  public static func stringOrNull(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  public static func from(_ any: Any?) throws -> JSONValue {
    guard let any else { return .null }
    switch any {
    case let value as JSONValue: return value
    case let value as String: return .string(value)
    case let value as Bool: return .bool(value)
    case let value as Int: return .number(Double(value))
    case let value as Int64: return .number(Double(value))
    case let value as Double: return .number(value)
    case let value as Float: return .number(Double(value))
    case let value as [Any]: return .array(try value.map { try JSONValue.from($0) })
    case let value as [String: Any]:
      var object: [String: JSONValue] = [:]
      for (key, child) in value { object[key] = try JSONValue.from(child) }
      return .object(object)
    default:
      throw CodexCoreError.invalidJSON("Unsupported JSON value: \(type(of: any))")
    }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  public subscript(string key: String) -> String? { self[key]?.stringValue }
  public subscript(object key: String) -> [String: JSONValue]? { self[key]?.objectValue }
  public subscript(array key: String) -> [JSONValue]? { self[key]?.arrayValue }
}

extension JSONEncoder {
  static var codexPretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static var codexCompact: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  static var codex: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
