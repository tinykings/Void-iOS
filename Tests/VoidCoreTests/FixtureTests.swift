import XCTest
@testable import VoidCore

// The same record web/tests/sync.test.mjs decodes, so iOS and the website agree on the
// wire format (docs/sync-schema.md).
final class FixtureTests: XCTestCase {
    struct WebRecord: Decodable {
        struct Field: Decodable {
            var value: Value
            var type: String
            enum Value: Decodable {
                case string(String), int(Int64)
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let int = try? c.decode(Int64.self) { self = .int(int) } else { self = .string(try c.decode(String.self)) }
                }
            }
        }
        var recordName: String
        var fields: [String: Field]
    }

    func testSharedFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/void-item-record.json")
        let record = try JSONDecoder().decode(WebRecord.self, from: Data(contentsOf: url))
        var fields: [String: SyncCodec.Value] = [:]
        for (name, field) in record.fields {
            switch field.value {
            case .string(let s): fields[name] = .string(s)
            case .int(let i): fields[name] = .int(i)
            }
            XCTAssertEqual(field.type, name == "mediaID" || name.hasPrefix("is") || name == "rating" || name == "schemaVersion" ? "INT64" : "STRING", name)
        }
        let item = try XCTUnwrap(SyncCodec.decode(recordName: record.recordName, fields: fields))
        XCTAssertEqual(item, SyncedItem(key: MediaKey(source: .tmdb, type: .tv, id: 1399), title: "Game of Thrones",
                                        image: "/u3bZgnGQ9T01sWNhyveQz0wH0Hl.jpg", releaseDate: "2011-04-17", list: .history,
                                        addedAt: "2026-11-13T22:04:05.123Z", isFavorite: true, rating: 5,
                                        returnedFor: "2026-11-10", pinnedAt: "2026-11-14T08:00:00.000Z"))
        XCTAssertTrue(item.isPinned)
        // And writing it back gives the same fields.
        XCTAssertEqual(SyncCodec.fields(item), fields)
    }
}
