// A prepared SQLite statement: bind parameters, step through rows, reset for reuse.

import Foundation
import SQLite3

final class Statement {
    private let handle: OpaquePointer
    private let connection: OpaquePointer

    init(_ sql: String, connection: OpaquePointer) throws {
        var handle: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &handle, nil), connection)
        guard let handle else { throw StorageError.emptyStatement }
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard values.count == expected else {
            throw StorageError.parameterCount(expected: expected, actual: values.count)
        }
        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v):
                rc = sqlite3_bind_int64(handle, index, v)
            case .double(let v):
                rc = sqlite3_bind_double(handle, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(handle, index, v, Int32(v.utf8.count), transient)
            case .blob(let v) where v.isEmpty:
                // A nil pointer would bind NULL instead of an empty blob.
                rc = sqlite3_bind_zeroblob(handle, index, 0)
            case .blob(let v):
                rc = v.withUnsafeBytes {
                    sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .null:
                rc = sqlite3_bind_null(handle, index)
            }
            try check(rc, connection)
        }
    }

    func rows() throws -> [Row] {
        let count = sqlite3_column_count(handle)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(handle, $0)) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw StorageError(code: rc, connection: connection) }
            rows.append(Row(columns: columns, values: (0..<count).map(column)))
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    private func column(_ index: Int32) -> SQLValue {
        switch sqlite3_column_type(handle, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(handle, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(handle, index))
        case SQLITE_TEXT:
            // Read the pointer before the length, per SQLite's docs.
            let bytes = sqlite3_column_text(handle, index)
            let length = Int(sqlite3_column_bytes(handle, index))
            let buffer = UnsafeBufferPointer(start: bytes, count: length)
            return .text(String(decoding: buffer, as: UTF8.self))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(handle, index))
            guard length > 0, let bytes = sqlite3_column_blob(handle, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: bytes, count: length))
        default:
            return .null
        }
    }
}
