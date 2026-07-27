import Foundation

public indirect enum BSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int32(Int32)
    case int64(Int64)
    case double(Double)
    case decimal128(String)
    case string(String)
    case objectId(String)
    case date(Date)
    case timestamp(time: UInt32, increment: UInt32)
    case binary(base64: String, subtype: String)
    case regex(pattern: String, options: String)
    case minKey
    case maxKey
    case array([BSONValue])
    case document([(String, BSONValue)])

    public static func == (lhs: BSONValue, rhs: BSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null), (.minKey, .minKey), (.maxKey, .maxKey):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.int32(a), .int32(b)):
            return a == b
        case let (.int64(a), .int64(b)):
            return a == b
        case let (.double(a), .double(b)):
            return a == b
        case let (.decimal128(a), .decimal128(b)):
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.objectId(a), .objectId(b)):
            return a == b
        case let (.date(a), .date(b)):
            return a == b
        case let (.timestamp(at, ai), .timestamp(bt, bi)):
            return at == bt && ai == bi
        case let (.binary(ad, asub), .binary(bd, bsub)):
            return ad == bd && asub == bsub
        case let (.regex(ap, ao), .regex(bp, bo)):
            return ap == bp && ao == bo
        case let (.array(a), .array(b)):
            return a == b
        case let (.document(a), .document(b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default:
            return false
        }
    }

    public init(extendedJSON value: JSONValue) {
        switch value {
        case .null:
            self = .null
        case let .bool(value):
            self = .bool(value)
        case let .number(value):
            self = .double(value)
        case let .string(value):
            self = .string(value)
        case let .array(values):
            self = .array(values.map(BSONValue.init(extendedJSON:)))
        case let .object(object):
            if case let .string(value)? = object["$oid"] {
                self = .objectId(value)
            } else if case let .string(value)? = object["$numberInt"], let number = Int32(value) {
                self = .int32(number)
            } else if case let .string(value)? = object["$numberLong"], let number = Int64(value) {
                self = .int64(number)
            } else if case let .string(value)? = object["$numberDouble"], let number = Double(value) {
                self = .double(number)
            } else if case let .string(value)? = object["$numberDecimal"] {
                self = .decimal128(value)
            } else if let dateValue = object["$date"] {
                self = Self.decodeDate(dateValue)
            } else if let timestamp = object["$timestamp"],
                      case let .object(parts) = timestamp,
                      let time = parts["t"]?.uint32Value,
                      let increment = parts["i"]?.uint32Value {
                self = .timestamp(time: time, increment: increment)
            } else if let regularExpression = object["$regularExpression"],
                      case let .object(parts) = regularExpression,
                      case let .string(pattern)? = parts["pattern"],
                      case let .string(options)? = parts["options"] {
                self = .regex(pattern: pattern, options: options)
            } else if let binary = object["$binary"],
                      case let .object(parts) = binary,
                      case let .string(base64)? = parts["base64"],
                      case let .string(subtype)? = parts["subType"] {
                self = .binary(base64: base64, subtype: subtype)
            } else if object["$minKey"] != nil {
                self = .minKey
            } else if object["$maxKey"] != nil {
                self = .maxKey
            } else {
                self = .document(object.keys.sorted().map {
                    ($0, BSONValue(extendedJSON: object[$0] ?? .null))
                })
            }
        }
    }

    public var displayString: String {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .int32(value): return String(value)
        case let .int64(value): return String(value)
        case let .double(value): return String(value)
        case let .decimal128(value): return "Decimal128(\(value))"
        case let .string(value): return value
        case let .objectId(value): return "ObjectId(\(value))"
        case let .date(value): return value.formatted(.iso8601)
        case let .timestamp(time, increment): return "Timestamp(\(time), \(increment))"
        case let .binary(_, subtype): return "Binary(\(subtype))"
        case let .regex(pattern, options): return "/\(pattern)/\(options)"
        case .minKey: return "MinKey"
        case .maxKey: return "MaxKey"
        case let .array(values): return "[\(values.count) values]"
        case let .document(fields): return "{\(fields.count) fields}"
        }
    }

    public var extendedJSON: JSONValue {
        switch self {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .int32(value):
            return .object(["$numberInt": .string(String(value))])
        case let .int64(value):
            return .object(["$numberLong": .string(String(value))])
        case let .double(value):
            return .object(["$numberDouble": .string(String(value))])
        case let .decimal128(value):
            return .object(["$numberDecimal": .string(value)])
        case let .string(value):
            return .string(value)
        case let .objectId(value):
            return .object(["$oid": .string(value)])
        case let .date(value):
            let milliseconds = Int64(value.timeIntervalSince1970 * 1_000)
            return .object([
                "$date": .object(["$numberLong": .string(String(milliseconds))])
            ])
        case let .timestamp(time, increment):
            return .object([
                "$timestamp": .object([
                    "t": .number(Double(time)),
                    "i": .number(Double(increment))
                ])
            ])
        case let .binary(base64, subtype):
            return .object([
                "$binary": .object([
                    "base64": .string(base64),
                    "subType": .string(subtype)
                ])
            ])
        case let .regex(pattern, options):
            return .object([
                "$regularExpression": .object([
                    "pattern": .string(pattern),
                    "options": .string(options)
                ])
            ])
        case .minKey:
            return .object(["$minKey": .number(1)])
        case .maxKey:
            return .object(["$maxKey": .number(1)])
        case let .array(values):
            return .array(values.map(\.extendedJSON))
        case let .document(fields):
            return .object(
                Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.extendedJSON) })
            )
        }
    }

    public var shellFormatted: String {
        shellFormatted(indentation: 0)
    }

    private func shellFormatted(indentation: Int) -> String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int32(value):
            return String(value)
        case let .int64(value):
            return "NumberLong(\(Self.quoted(String(value))))"
        case let .double(value):
            return String(value)
        case let .decimal128(value):
            return "NumberDecimal(\(Self.quoted(value)))"
        case let .string(value):
            return Self.quoted(value)
        case let .objectId(value):
            return "ObjectId(\(Self.quoted(value)))"
        case let .date(value):
            return "ISODate(\(Self.quoted(Self.iso8601String(from: value))))"
        case let .timestamp(time, increment):
            return "Timestamp(\(time), \(increment))"
        case let .binary(base64, subtype):
            return "BinData(\(Int(subtype, radix: 16) ?? 0), \(Self.quoted(base64)))"
        case let .regex(pattern, options):
            return "RegExp(\(Self.quoted(pattern)), \(Self.quoted(options)))"
        case .minKey:
            return "MinKey()"
        case .maxKey:
            return "MaxKey()"
        case let .array(values):
            guard !values.isEmpty else { return "[]" }
            let childIndentation = indentation + 2
            let prefix = String(repeating: " ", count: childIndentation)
            let suffix = String(repeating: " ", count: indentation)
            return "[\n"
                + values.map { prefix + $0.shellFormatted(indentation: childIndentation) }
                    .joined(separator: ",\n")
                + "\n\(suffix)]"
        case let .document(fields):
            guard !fields.isEmpty else { return "{}" }
            let childIndentation = indentation + 2
            let prefix = String(repeating: " ", count: childIndentation)
            let suffix = String(repeating: " ", count: indentation)
            return "{\n"
                + fields.map {
                    "\(prefix)\(Self.quoted($0.0)): \($0.1.shellFormatted(indentation: childIndentation))"
                }
                .joined(separator: ",\n")
                + "\n\(suffix)}"
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeDate(_ value: JSONValue) -> BSONValue {
        switch value {
        case let .string(value):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value)
                ?? ISO8601DateFormatter().date(from: value) {
                return .date(date)
            }
        case let .object(object):
            if case let .string(milliseconds)? = object["$numberLong"],
               let value = Double(milliseconds) {
                return .date(Date(timeIntervalSince1970: value / 1_000))
            }
        default:
            break
        }
        return .string(value.prettyPrinted)
    }
}

private extension JSONValue {
    var uint32Value: UInt32? {
        switch self {
        case let .number(value):
            return UInt32(exactly: value)
        case let .object(object):
            if case let .string(value)? = object["$numberLong"] ?? object["$numberInt"] {
                return UInt32(value)
            }
            return nil
        default:
            return nil
        }
    }
}
