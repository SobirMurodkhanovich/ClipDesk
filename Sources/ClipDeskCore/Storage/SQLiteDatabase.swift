import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String

    public var description: String { "SQLite error \(code): \(message)" }

    /// The file is damaged or is not a database.
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    static func optionalText(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
}

/// Read access to the current result row of a statement.
struct SQLRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func bool(_ column: Int32) -> Bool { int(column) != 0 }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func string(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

/// A minimal SQLite connection. Not thread-safe: owned and used by a single actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (or creates) a database file. Pass `nil` for an in-memory database.
    init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = DatabaseError(code: result, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_extended_result_codes(handle, 0)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw DatabaseError(code: result, message: message)
        }
    }

    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result != SQLITE_ROW { throw error(result) }
        }
    }

    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error(result) }
            rows.append(try map(SQLRow(statement: statement)))
        }
    }

    func queryFirst<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> T? {
        try query(sql, bindings, map: map).first
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            try queryFirst("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        }
    }

    func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept bound parameters; `version` is an integer we control.
        try execute("PRAGMA user_version = \(version)")
    }

    /// Number of rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func error(_ code: Int32) -> DatabaseError {
        DatabaseError(code: code, message: lastErrorMessage)
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error(result) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .integer(let integer):
                bindResult = sqlite3_bind_int64(statement, index, integer)
            case .real(let real):
                bindResult = sqlite3_bind_double(statement, index, real)
            case .text(let text):
                bindResult = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                bindResult = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error(bindResult)
            }
        }
        return statement
    }
}
