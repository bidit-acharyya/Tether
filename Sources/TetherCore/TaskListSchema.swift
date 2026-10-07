// The task list's three schema versions, used by the demo app and the mixed-version
// simulator: v2 adds a field of a known kind, v3 renames one and adds a new CRDT kind.

import Foundation
import TetherStorage

public enum TaskListSchema {
    public static let v1 = manifest(version: 1)
    public static let v2 = manifest(version: 2)
    public static let v3 = manifest(version: 3)

    /// 0 low, 1 medium, 2 high.
    public static let mediumPriority: Int64 = 1

    private static func manifest(version: UInt64) -> SchemaManifest {
        var item = [
            FieldSpec(
                id: Field.title, name: version >= 3 ? "name" : Field.title, kind: .lww,
                valueType: .string),
            FieldSpec(id: Field.done, kind: .lww, valueType: .bool),
            FieldSpec(id: Field.position, kind: .lww, valueType: .string),
            FieldSpec(id: Field.deleted, kind: .lww, valueType: .bool),
            FieldSpec(id: Field.tags, kind: .orSet, valueType: .string),
        ]
        if version >= 2 {
            var writer = ByteWriter()
            mediumPriority.write(to: &writer)
            item.append(
                FieldSpec(
                    id: Field.priority, kind: .lww, valueType: .int64,
                    defaultValue: writer.data, introducedIn: 2))
        }
        if version >= 3 {
            item.append(
                FieldSpec(id: Field.views, kind: .counter, valueType: .int64, introducedIn: 3))
        }
        let list = [
            FieldSpec(id: Field.title, kind: .lww, valueType: .string),
            FieldSpec(id: Field.items, kind: .orSet, valueType: .docID),
        ]
        return SchemaManifest(
            version: version,
            documents: [
                DocumentSpec(type: "list", fields: list), DocumentSpec(type: "item", fields: item),
            ])
    }
}
