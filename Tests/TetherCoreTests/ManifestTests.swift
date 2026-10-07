// Tests for schema manifests: encoding, lookups, the upgrade validator, and how a replica
// stores its manifest and stamps ops with its schema version.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private func manifest(version: UInt64, title: FieldSpec) -> SchemaManifest {
    SchemaManifest(version: version, documents: [DocumentSpec(type: "item", fields: [title])])
}

@Suite struct ManifestTests {
    @Test(arguments: [TaskListSchema.v1, TaskListSchema.v2, TaskListSchema.v3])
    func manifestsRoundTrip(_ manifest: SchemaManifest) throws {
        #expect(try SchemaManifest(decoding: manifest.encoded()) == manifest)
        try manifest.validate()
    }

    @Test func exampleSchemasMatchTheDesign() throws {
        #expect(TaskListSchema.v1.field(Field.priority) == nil)
        let priority = try #require(TaskListSchema.v2.field(Field.priority))
        var reader = ByteReader(try #require(priority.defaultValue))
        #expect(try Int64.read(from: &reader) == TaskListSchema.mediumPriority)
        let item = try #require(TaskListSchema.v3.documents.first { $0.type == "item" })
        #expect(item.fields.first { $0.id == Field.title }?.name == "name")
        #expect(TaskListSchema.v3.field(Field.views)?.kind == .counter)
        #expect(!TaskListSchema.v2.opKinds.contains(OpKind.increment.rawValue))
        #expect(TaskListSchema.v3.opKinds.contains(OpKind.increment.rawValue))
    }

    @Test func orSetSubfieldsResolveToTheirBaseField() {
        #expect(TaskListSchema.v1.field("items/0a1b2c")?.id == Field.items)
        #expect(TaskListSchema.v1.field("tags/ff")?.kind == .orSet)
        #expect(TaskListSchema.v1.field("nope") == nil)
    }

    @Test func eachVersionIsAValidUpgradeOfTheLast() throws {
        try TaskListSchema.v2.validate(upgradingFrom: TaskListSchema.v1)
        try TaskListSchema.v3.validate(upgradingFrom: TaskListSchema.v2)
        try TaskListSchema.v3.validate(upgradingFrom: TaskListSchema.v1)
    }

    @Test func unsafeChangesAreRefused() {
        let old = manifest(
            version: 1, title: FieldSpec(id: "title", kind: .lww, valueType: .string))
        #expect(throws: ManifestError.kindChanged("title")) {
            try manifest(
                version: 2, title: FieldSpec(id: "title", kind: .orSet, valueType: .string)
            )
            .validate(upgradingFrom: old)
        }
        #expect(throws: ManifestError.typeChanged("title")) {
            try manifest(version: 2, title: FieldSpec(id: "title", kind: .lww, valueType: .int64))
                .validate(upgradingFrom: old)
        }
        #expect(throws: ManifestError.versionNotIncreasing(from: 1, to: 1)) {
            try old.validate(upgradingFrom: old)
        }
        #expect(throws: ManifestError.introducedAfterVersion("title")) {
            try manifest(
                version: 1,
                title: FieldSpec(id: "title", kind: .lww, valueType: .string, introducedIn: 2)
            ).validate()
        }
    }

    @Test func renamingAndRemovingFieldsAreAllowed() throws {
        let old = manifest(
            version: 1, title: FieldSpec(id: "title", kind: .lww, valueType: .string))
        try manifest(
            version: 2, title: FieldSpec(id: "title", name: "name", kind: .lww, valueType: .string)
        )
        .validate(upgradingFrom: old)
        try SchemaManifest(version: 2, documents: []).validate(upgradingFrom: old)
    }
}

@Suite struct ReplicaManifestTests {
    private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!

    @Test func opsCarryTheWritersSchemaVersion() async throws {
        let v1 = try await Replica.open(path: ":memory:", manifest: TaskListSchema.v1)
        let v2 = try await Replica.open(path: ":memory:", manifest: TaskListSchema.v2)
        #expect(
            try await v1.perform(.createList(list, title: "a")).allSatisfy { $0.schemaVersion == 1 }
        )
        #expect(
            try await v2.perform(.createList(list, title: "b")).allSatisfy { $0.schemaVersion == 2 }
        )
    }

    @Test func manifestIsStoredAndUpgradesAreChecked() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TetherManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let first = try await Replica.open(path: path, manifest: TaskListSchema.v1)
        #expect(try await first.database.storedManifest() == TaskListSchema.v1)
        await first.database.close()

        let upgraded = try await Replica.open(path: path, manifest: TaskListSchema.v3)
        #expect(try await upgraded.database.storedManifest() == TaskListSchema.v3)
        await upgraded.database.close()

        let broken = SchemaManifest(
            version: 4,
            documents: [
                DocumentSpec(
                    type: "item",
                    fields: [FieldSpec(id: Field.title, kind: .lww, valueType: .int64)])
            ])
        await #expect(throws: ManifestError.typeChanged(Field.title)) {
            try await Replica.open(path: path, manifest: broken)
        }

        // Going back to an older app version is allowed (a user can downgrade).
        let downgraded = try await Replica.open(path: path, manifest: TaskListSchema.v2)
        #expect(downgraded.manifest.version == 2)
    }
}
