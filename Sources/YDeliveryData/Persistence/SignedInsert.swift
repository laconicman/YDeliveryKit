import Foundation
import GRDB

extension AppDatabase {
    /// One fact row, inserted with its signature computed over exactly the values this
    /// statement binds, in this transaction, from this argument list (rule 3): the
    /// payload is the frozen column list's values as the database will store them, the
    /// signature rides beside them, and no stored byte is ever re-read to sign it.
    /// `INSERT OR IGNORE` stated in the statement — a retry under the same id is a
    /// no-op, never a replace. A `nil` signatory writes the pair NULL: the row reads
    /// *unsigned*, which is the truth. The signatory is resolved by the caller before
    /// the transaction, never inside it.
    ///
    /// Returns whether a row was written.
    @discardableResult
    static func insertSigned(
        table: String, bindings: [(any DatabaseValueConvertible)?], signatory: Signatory?,
        keyIDColumn: String? = "signingKeyID", signatureColumn: String = "signature",
        into db: Database
    ) throws -> Bool {
        guard let columns = CanonicalPayload.signedColumns[table] else {
            preconditionFailure("\(table) has no frozen signed column list")
        }
        precondition(columns.count == bindings.count,
                     "\(table): the bindings must be the frozen signed list's values, in order")
        let values = CanonicalPayload.databaseValues(bindings)
        let payload = CanonicalPayload.payload(table: table, columns: columns, values: values)
        var allColumns = columns
        var allValues = values
        if let keyIDColumn {
            allColumns.append(keyIDColumn)
            allValues.append(signatory?.keyID.databaseValue ?? .null)
        }
        allColumns.append(signatureColumn)
        allValues.append(try signatory?.signatureBase64(for: payload).databaseValue ?? .null)
        let quoted = allColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = allColumns.map { _ in "?" }.joined(separator: ", ")
        try db.execute(sql: """
            INSERT OR IGNORE INTO "\(table)" (\(quoted)) VALUES (\(placeholders))
            """, arguments: StatementArguments(allValues))
        return db.changesCount > 0
    }
}
