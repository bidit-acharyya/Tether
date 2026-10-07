// SchemaManifest: what one app version knows about its data. Fields are keyed by a
// stable storage id that never changes, so renames are only a display name change.
// validate(upgradingFrom:) refuses changes that would make two versions merge the same
// ops differently.

import Foundation
import TetherStorage

public enum CRDTKind: UInt8, Sendable {
    case lww = 1
    case orSet = 2
    case counter = 3

    /// The op kinds a field of this CRDT kind is written with.
    public var opKinds: Set<UInt8> {
        switch self {
        case .lww: [OpKind.set.rawValue]
        case .orSet: [OpKind.add.rawValue, OpKind.remove.rawValue]
        case .counter: [OpKind.increment.rawValue]
        }
    }
}

public enum ValueType: UInt8, Sendable {
    case string = 1
    case bool = 2
    case int64 = 3
    case docID = 4
}

public struct FieldSpec: Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: CRDTKind
    public let valueType: ValueType
    /// Encoded value read when the field has never been written. Never stored.
    public let defaultValue: Data?
    public let introducedIn: UInt64

    public init(
        id: String, name: String? = nil, kind: CRDTKind, valueType: ValueType,
        defaultValue: Data? = nil, introducedIn: UInt64 = 1
    ) {
        self.id = id
        self.name = name ?? id
        self.kind = kind
        self.valueType = valueType
        self.defaultValue = defaultValue
        self.introducedIn = introducedIn
    }
}

public struct DocumentSpec: Sendable, Equatable {
    public let type: String
    public let fields: [FieldSpec]

    public init(type: String, fields: [FieldSpec]) {
        self.type = type
        self.fields = fields
    }
}

public enum ManifestError: Error, Equatable {
    case versionNotIncreasing(from: UInt64, to: UInt64)
    case conflictingField(String)
    case introducedAfterVersion(String)
    case kindChanged(String)
    case typeChanged(String)
    case unknownEncoding(String)
}

public struct SchemaManifest: Sendable, Equatable {
    public let version: UInt64
    public let documents: [DocumentSpec]

    public init(version: UInt64, documents: [DocumentSpec]) {
        self.version = version
        self.documents = documents
    }

    /// The spec for a storage field id. OR-Set sub-fields (`items/<hex>`) use their base id.
    public func field(_ storageID: String) -> FieldSpec? {
        let base = Self.baseID(of: storageID)
        for document in documents {
            if let spec = document.fields.first(where: { $0.id == base }) { return spec }
        }
        return nil
    }

    /// The spec for the field this version's code calls `name` (the rename lens).
    public func field(named name: String, in documentType: String) -> FieldSpec? {
        documents.first { $0.type == documentType }?.fields.first { $0.name == name }
    }

    public static func baseID(of storageID: String) -> String {
        storageID.split(separator: "/", maxSplits: 1).first.map(String.init) ?? storageID
    }

    /// Every op kind this manifest's fields are written with.
    public var opKinds: Set<UInt8> {
        Set(documents.flatMap(\.fields).flatMap(\.kind.opKinds))
    }

    /// Every op kind this version can merge, on any field: LWW and OR-Set shipped in v1, so
    /// every version has them, plus whatever kinds its own fields add.
    public var mergeableKinds: Set<UInt8> {
        opKinds.union(CRDTKind.lww.opKinds).union(CRDTKind.orSet.opKinds)
    }

    /// Checks this manifest on its own: one meaning per field id, nothing from the future.
    public func validate() throws {
        var seen: [String: FieldSpec] = [:]
        for field in documents.flatMap(\.fields) {
            guard field.introducedIn <= version else {
                throw ManifestError.introducedAfterVersion(field.id)
            }
            // The same id may appear in several document types, but must mean the same thing.
            if let other = seen[field.id],
                other.kind != field.kind || other.valueType != field.valueType
            {
                throw ManifestError.conflictingField(field.id)
            }
            seen[field.id] = field
        }
    }

    /// Checks this manifest as an upgrade of `old`. Adding, renaming, re-defaulting and
    /// hiding fields are fine; changing a field's CRDT kind or value type is refused.
    public func validate(upgradingFrom old: SchemaManifest) throws {
        try validate()
        guard version > old.version else {
            throw ManifestError.versionNotIncreasing(from: old.version, to: version)
        }
        for oldField in old.documents.flatMap(\.fields) {
            guard let newField = field(oldField.id) else { continue }
            guard newField.kind == oldField.kind else {
                throw ManifestError.kindChanged(oldField.id)
            }
            guard newField.valueType == oldField.valueType else {
                throw ManifestError.typeChanged(oldField.id)
            }
        }
    }
}

// Layout: version, document count, then per document its type and fields; per field
// id, name, kind, value type, optional default, introduced-in.
extension SchemaManifest {
    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.writeVarint(version)
        writer.writeVarint(UInt64(documents.count))
        for document in documents {
            writer.writeString(document.type)
            writer.writeVarint(UInt64(document.fields.count))
            for field in document.fields {
                writer.writeString(field.id)
                writer.writeString(field.name)
                writer.write(field.kind.rawValue)
                writer.write(field.valueType.rawValue)
                if let defaultValue = field.defaultValue {
                    writer.write(1)
                    writer.writeBytes(defaultValue)
                } else {
                    writer.write(0)
                }
                writer.writeVarint(field.introducedIn)
            }
        }
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.readVarint()
        var documents: [DocumentSpec] = []
        for _ in 0..<(try reader.readVarint()) {
            let type = try reader.readString()
            var fields: [FieldSpec] = []
            for _ in 0..<(try reader.readVarint()) {
                let id = try reader.readString()
                let name = try reader.readString()
                guard let kind = CRDTKind(rawValue: try reader.read()) else {
                    throw ManifestError.unknownEncoding("kind of \(id)")
                }
                guard let valueType = ValueType(rawValue: try reader.read()) else {
                    throw ManifestError.unknownEncoding("value type of \(id)")
                }
                let defaultValue = try reader.read() == 1 ? try reader.readBytes() : nil
                fields.append(
                    FieldSpec(
                        id: id, name: name, kind: kind, valueType: valueType,
                        defaultValue: defaultValue, introducedIn: try reader.readVarint()))
            }
            documents.append(DocumentSpec(type: type, fields: fields))
        }
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
        self.init(version: version, documents: documents)
    }
}

extension Database {
    public func storedManifest() throws -> SchemaManifest? {
        try meta(manifestKey).map(SchemaManifest.init(decoding:))
    }

    public func saveManifest(_ manifest: SchemaManifest) throws {
        try setMeta(manifestKey, manifest.encoded())
    }
}

private let manifestKey = "manifest"
