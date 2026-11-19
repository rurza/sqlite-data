#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import Foundation
  import InlineSnapshotTesting
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    /// A table whose one foreign key references the table itself is a hierarchy: every row points
    /// at its parent row with `CKRecord.parent`, and a row with no parent is a root that can be
    /// shared with everything below it.
    @MainActor
    @Suite(.taskLocal($additionalTables, [SynchronizedTable(for: Folder.self)]))
    final class HierarchicalSharingTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func seedHierarchy() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Folder(id: 1, title: "Home")
            Folder(id: 2, title: "Kitchen", parentID: 1)
            Folder(id: 3, title: "Tiles", parentID: 2)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func childAndGrandchildCarryParents() async throws {
        try await seedHierarchy()

        assertQuery(
          SyncMetadata
            .where { $0.recordType.eq(Folder.tableName) }
            .order(by: \.recordName)
            .select { ($0.recordName, $0.parentRecordName) },
          database: syncEngine.metadatabase
        ) {
          """
          ┌─────────────┬─────────────┐
          │ "1:folders" │ nil         │
          │ "2:folders" │ "1:folders" │
          │ "3:folders" │ "2:folders" │
          └─────────────┴─────────────┘
          """
        }
        let child = try syncEngine.private.database.record(for: Folder.recordID(for: 2))
        let grandchild = try syncEngine.private.database.record(for: Folder.recordID(for: 3))
        #expect(child.parent?.recordID == Folder.recordID(for: 1))
        #expect(grandchild.parent?.recordID == Folder.recordID(for: 2))
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func shareRoot() async throws {
        try await seedHierarchy()

        let sharedRecord = try await syncEngine.share(
          record: Folder(id: 1, title: "Home"),
          configure: { _ in }
        )

        #expect(
          sharedRecord.share.recordID.recordName == "share-\(Folder.recordName(for: 1))"
        )
        let root = try syncEngine.private.database.record(for: Folder.recordID(for: 1))
        #expect(root.share?.recordID == sharedRecord.share.recordID)
        assertQuery(
          SyncMetadata
            .where { $0.recordType.eq(Folder.tableName) }
            .order(by: \.recordName)
            .select { ($0.recordName, $0.isShared) },
          database: syncEngine.metadatabase
        ) {
          """
          ┌─────────────┬───────┐
          │ "1:folders" │ true  │
          │ "2:folders" │ false │
          │ "3:folders" │ false │
          └─────────────┴───────┘
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func shareNonRootRow() async throws {
        try await seedHierarchy()

        let error = await #expect(throws: (any Error).self) {
          _ = try await self.syncEngine.share(
            record: Folder(id: 2, title: "Kitchen", parentID: 1),
            configure: { _ in }
          )
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SharingError(
            recordTableName: "folders",
            recordPrimaryKey: "2",
            reason: .recordNotRoot(
              [
                [0]: ForeignKey(
                  table: "folders",
                  from: "parentID",
                  to: "id",
                  onUpdate: .noAction,
                  onDelete: .cascade,
                  isNotNull: false
                )
              ]
            ),
            debugDescription: "Only root records are shareable, but parent record(s) detected via foreign key(s)."
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func moveSubfolderOutOfSharedTree() async throws {
        try await seedHierarchy()
        _ = try await syncEngine.share(record: Folder(id: 1, title: "Home"), configure: { _ in })

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(2).update { $0.parentID = #bind(nil) }.execute(db)
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        let moved = try syncEngine.private.database.record(for: Folder.recordID(for: 2))
        let grandchild = try syncEngine.private.database.record(for: Folder.recordID(for: 3))
        #expect(moved.parent == nil)
        #expect(moved.recordID.zoneID == SyncEngine.defaultTestZone.zoneID)
        #expect(grandchild.parent?.recordID == Folder.recordID(for: 2))

        // Now a root of its own, the moved folder can be shared with what it holds.
        let sharedRecord = try await syncEngine.share(
          record: Folder(id: 2, title: "Kitchen"),
          configure: { _ in }
        )
        #expect(
          sharedRecord.share.recordID.recordName == "share-\(Folder.recordName(for: 2))"
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func sendParentsBeforeChildren() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Folder(id: 1, title: "Home")
            Folder(id: 2, title: "Kitchen", parentID: 1)
            Folder(id: 3, title: "Tiles", parentID: 2)
          }
        }
        let pending = syncEngine.private.state.pendingRecordZoneChanges
        syncEngine.private.state.remove(pendingRecordZoneChanges: pending)
        syncEngine.private.state.add(pendingRecordZoneChanges: pending.reversed())

        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(
          batch?.recordsToSave.map(\.recordID) == [
            Folder.recordID(for: 1),
            Folder.recordID(for: 2),
            Folder.recordID(for: 3),
          ]
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func receiveChildrenBeforeParents() async throws {
        let root = CKRecord(recordType: Folder.tableName, recordID: Folder.recordID(for: 1))
        root.setValue(1, forKey: "id", at: now)
        root.setValue("Home", forKey: "title", at: now)
        let child = CKRecord(recordType: Folder.tableName, recordID: Folder.recordID(for: 2))
        child.setValue(2, forKey: "id", at: now)
        child.setValue("Kitchen", forKey: "title", at: now)
        child.setValue(1, forKey: "parentID", at: now)
        child.parent = CKRecord.Reference(record: root, action: .none)
        let grandchild = CKRecord(recordType: Folder.tableName, recordID: Folder.recordID(for: 3))
        grandchild.setValue(3, forKey: "id", at: now)
        grandchild.setValue("Tiles", forKey: "title", at: now)
        grandchild.setValue(2, forKey: "parentID", at: now)
        grandchild.parent = CKRecord.Reference(record: child, action: .none)

        _ = try syncEngine.modifyRecords(scope: .private, saving: [grandchild, child, root])
        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [grandchild, child, root].map {
            try! syncEngine.private.database.record(for: $0.recordID)
          },
          syncEngine: syncEngine.private
        )

        // Every row arrives in the one fetch: none waits for its parent in the next.
        assertQuery(Folder.order(by: \.id), database: userDatabase.database) {
          """
          ┌─────────────────────┐
          │ Folder(             │
          │   id: 1,            │
          │   title: "Home",    │
          │   parentID: nil     │
          │ )                   │
          ├─────────────────────┤
          │ Folder(             │
          │   id: 2,            │
          │   title: "Kitchen", │
          │   parentID: 1       │
          │ )                   │
          ├─────────────────────┤
          │ Folder(             │
          │   id: 3,            │
          │   title: "Tiles",   │
          │   parentID: 2       │
          │ )                   │
          └─────────────────────┘
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteRootDeletesHierarchy() async throws {
        try await seedHierarchy()

        try await userDatabase.userWrite { db in
          try Folder.find(1).delete().execute(db)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertQuery(Folder.all, database: userDatabase.database) {
          """
          (No results)
          """
        }
        for id in 1...3 {
          #expect(throws: (any Error).self) {
            try self.syncEngine.private.database.record(for: Folder.recordID(for: id))
          }
        }
      }
    }
  }
#endif
