import Foundation
import Testing
@testable import ShardCore

@Test
func canonicalExtendedJSONPreservesBSONTypes() {
    let value = JSONValue.object([
        "_id": .object(["$oid": .string("507f1f77bcf86cd799439011")]),
        "count": .object(["$numberLong": .string("9_007_199_254_740_993")]),
        "price": .object(["$numberDecimal": .string("19.99")]),
        "createdAt": .object(["$date": .string("2026-07-23T00:00:00.000Z")])
    ])

    guard case let .document(fields) = BSONValue(extendedJSON: value) else {
        Issue.record("Expected a BSON document")
        return
    }

    #expect(fields.contains { $0.0 == "_id" && $0.1 == .objectId("507f1f77bcf86cd799439011") })
    #expect(fields.contains { $0.0 == "price" && $0.1 == .decimal128("19.99") })
    #expect(fields.contains {
        guard $0.0 == "createdAt", case .date = $0.1 else { return false }
        return true
    })
}

@Test
func responseErrorsRemainStructured() throws {
    let id = UUID()
    let response = SidecarResponse(
        id: id,
        error: SidecarError(
            code: "not_connected",
            message: "Connect first.",
            retryable: true
        )
    )

    let decoded = try JSONDecoder().decode(
        SidecarResponse.self,
        from: JSONEncoder().encode(response)
    )
    #expect(decoded.id == id)
    #expect(decoded.error?.code == "not_connected")
    #expect(decoded.error?.retryable == true)
}

@Test
func bsonValuesRoundTripThroughCanonicalExtendedJSON() {
    let original = BSONValue.document([
        ("_id", .objectId("507f1f77bcf86cd799439011")),
        ("count", .int64(9_007_199_254_740_993)),
        ("price", .decimal128("19.99")),
        ("tags", .array([.string("native"), .bool(true)]))
    ])

    #expect(BSONValue(extendedJSON: original.extendedJSON) == original)
}

@Test
func bsonValuesUseMongoShellFormatting() {
    let value = BSONValue.document([
        ("_id", .objectId("507f1f77bcf86cd799439011")),
        ("count", .int64(9_007_199_254_740_993)),
        ("active", .bool(true))
    ])

    #expect(value.shellFormatted.contains(#""_id": ObjectId("507f1f77bcf86cd799439011")"#))
    #expect(value.shellFormatted.contains(#""count": NumberLong("9007199254740993")"#))
    #expect(value.shellFormatted.contains(#""active": true"#))
}
