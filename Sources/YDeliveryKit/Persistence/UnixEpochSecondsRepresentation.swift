public import Foundation
import SQLiteData

// The substrate's date convention is REAL unix-epoch seconds — every handwritten
// statement in `AppDatabase` binds and decodes `timeIntervalSince1970` doubles,
// and the contract's DDL types the columns REAL (doc:Schema). `Date`'s default
// binding is ISO-8601 text and the package's `UnixTimeRepresentation` binds
// whole-second INTEGERs — neither is the bytes this schema already holds, so
// `Date` columns on every `@Table` here declare this representation instead.
// Without it the engine's record reads decode-fail per row and a shared or
// synced row carrying a date silently never reaches iCloud.
public extension Date {
    nonisolated struct UnixEpochSecondsRepresentation: QueryRepresentable {
        public var queryOutput: Date

        public init(queryOutput: Date) {
            self.queryOutput = queryOutput
        }

        public static func _queryFragment(jsonEncoding queryFragment: QueryFragment) -> QueryFragment {
            "datetime(\(queryFragment), 'unixepoch')"
        }

        public static func _queryFragment(jsonDecoding queryFragment: QueryFragment) -> QueryFragment {
            "unixepoch(\(queryFragment))"
        }
    }
}

public extension Date? {
    /// Optional columns spell their representation through the same name, the
    /// package's own `Date?`-typealias pattern (`Date+UnixTime`).
    typealias UnixEpochSecondsRepresentation = Date.UnixEpochSecondsRepresentation?
}

nonisolated extension Date.UnixEpochSecondsRepresentation: QueryBindable {
    public var queryBinding: QueryBinding {
        .double(queryOutput.timeIntervalSince1970)
    }
}

nonisolated extension Date.UnixEpochSecondsRepresentation: QueryDecodable {
    public init(decoder: inout some QueryDecoder) throws {
        try self.init(queryOutput: Date(timeIntervalSince1970: Double(decoder: &decoder)))
    }
}

nonisolated extension Date.UnixEpochSecondsRepresentation: SQLiteType {
    public static var typeAffinity: SQLiteTypeAffinity {
        Double.typeAffinity
    }
}
