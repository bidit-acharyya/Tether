// SQLValue is one value SQLite can store; Row is one query result with typed getters.

import Foundation

public enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public struct Row: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLValue]

    public func value(_ column: String) throws -> SQLValue {
        guard let index = columns.firstIndex(of: column) else {
            throw StorageError.noSuchColumn(column)
        }
        return values[index]
    }

    public func int(_ column: String) throws -> Int64 {
        guard case .int(let value) = try value(column) else {
            throw StorageError.typeMismatch(column: column)
        }
        return value
    }

    /// An INTEGER column holding a UInt64. A negative value means the row is corrupt.
    public func uint64(_ column: String) throws -> UInt64 {
        guard let value = UInt64(exactly: try int(column)) else {
            throw StorageError.corrupt("negative \(column)")
        }
        return value
    }

    public func double(_ column: String) throws -> Double {
        guard case .double(let value) = try value(column) else {
            throw StorageError.typeMismatch(column: column)
        }
        return value
    }

    public func text(_ column: String) throws -> String {
        guard case .text(let value) = try value(column) else {
            throw StorageError.typeMismatch(column: column)
        }
        return value
    }

    public func blob(_ column: String) throws -> Data {
        guard case .blob(let value) = try value(column) else {
            throw StorageError.typeMismatch(column: column)
        }
        return value
    }
}
