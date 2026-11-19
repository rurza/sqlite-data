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
    /// What a hierarchy of rows in one table must survive on its way to and from CloudKit: a
    /// parent CloudKit no longer has, a library whose table gained its reference to itself after
    /// its rows were synchronized, a cycle, and a participant moving a row of someone's share.
    @MainActor
    @Suite(.taskLocal($additionalTables, [SynchronizedTable(for: Folder.self)]))
    final class HierarchicalSyncTests: BaseCloudKitTests, @unchecked Sendable {
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
      func localFolders() async throws -> [Folder] {
        try await userDatabase.read { db in try Folder.order(by: \.id).fetchAll(db) }
      }

      // MARK: - A parent CloudKit does not have

      /// Another device deleted folder 1, and this one has not heard yet. Moving folder 5, which
      /// holds 6, under 1 is refused by CloudKit — and must not delete 5 and 6, here or there.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func moveIntoRemotelyDeletedParentKeepsSubtree() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Folder(id: 1, title: "Gone")
            Folder(id: 5, title: "Mine")
            Folder(id: 6, title: "Inside", parentID: 5)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        _ = try syncEngine.modifyRecords(scope: .private, deleting: [Folder.recordID(for: 1)])

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(5).update { $0.parentID = #bind(1) }.execute(db)
          }
          // Refused; then the parent, which CloudKit has forgotten, and the row again; then the
          // parent as a new record.
          for _ in 1...3 {
            try await syncEngine.processPendingRecordZoneChanges(scope: .private)
          }
        }

        let folders = try await localFolders()
        expectNoDifference(
          folders,
          [
            Folder(id: 1, title: "Gone"),
            Folder(id: 5, title: "Mine", parentID: 1),
            Folder(id: 6, title: "Inside", parentID: 5),
          ]
        )
        let five = try syncEngine.private.database.record(for: Folder.recordID(for: 5))
        let six = try syncEngine.private.database.record(for: Folder.recordID(for: 6))
        _ = try syncEngine.private.database.record(for: Folder.recordID(for: 1))
        #expect(five.parent?.recordID == Folder.recordID(for: 1))
        #expect(six.parent?.recordID == Folder.recordID(for: 5))
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }

      /// A parent this device has, but in another zone, can never be referenced from the row's
      /// zone: the row is moved to the top of its hierarchy instead of being deleted.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func parentInAnotherZoneMovesRowToTop() async throws {
        try await seedHierarchy()
        let elsewhere = CKRecordZone.ID(zoneName: "elsewhere", ownerName: CKCurrentUserDefaultName)
        try await syncEngine.metadatabase.write { db in
          try SyncMetadata
            .where { $0.recordName.eq(Folder.recordName(for: 1)) }
            .update { $0.zoneName = #bind(elsewhere.zoneName) }
            .execute(db)
        }
        let two = try syncEngine.private.database.record(for: Folder.recordID(for: 2))

        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [(two, CKError(.referenceViolation))],
          syncEngine: syncEngine.private
        )

        let folders = try await localFolders()
        expectNoDifference(
          folders,
          [
            Folder(id: 1, title: "Home"),
            Folder(id: 2, title: "Kitchen"),
            Folder(id: 3, title: "Tiles", parentID: 2),
          ]
        )
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges
            .contains(.saveRecord(Folder.recordID(for: 2)))
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try syncEngine.private.database.record(for: Folder.recordID(for: 2)).parent == nil)
      }

      /// A row whose parent's own save failed for good is not sent again behind it: the next send
      /// would be refused the same way, for ever.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func rowIsNotResentBehindADroppedParent() async throws {
        try await seedHierarchy()
        let one = try syncEngine.private.database.record(for: Folder.recordID(for: 1))
        let two = try syncEngine.private.database.record(for: Folder.recordID(for: 2))

        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [
            (one, CKError(.quotaExceeded)),
            (two, CKError(.referenceViolation)),
          ],
          syncEngine: syncEngine.private
        )

        #expect(try await localFolders().count == 3)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }

      // MARK: - A table that gained its reference to itself

      /// The rows were synchronized by a build whose table had no reference to itself, so their
      /// metadata has no parent. The table is rebuilt with the reference before the engine starts:
      /// the start fills in each parent and sends exactly those rows, with their parent, and
      /// without claiming a newer edit than the one they carry.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func startFillsInParentsOfRowsSyncedWithoutThem() async throws {
        try await seedHierarchy()
        // What the build without the reference recorded: no parent anywhere.
        try await syncEngine.metadatabase.write { db in
          try SyncMetadata
            .where { $0.recordType.eq(Folder.tableName) }
            .update {
              $0.parentRecordPrimaryKey = #bind(nil)
              $0.parentRecordType = #bind(nil)
            }
            .execute(db)
        }
        let modificationTimes = try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .where { $0.recordType.eq(Folder.tableName) }
            .order(by: \.recordName)
            .select(\.userModificationTime)
            .fetchAll(db)
        }
        syncEngine.stop()

        // The migration: SQLite adds a foreign key only by rebuilding the table, with foreign keys
        // off, as a migrator runs it — on, dropping the old table would cascade into the new one.
        try await userDatabase.database.writeWithoutTransaction { db in
          try db.execute(sql: "PRAGMA foreign_keys = OFF")
          defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
          try db.inTransaction {
          try #sql(
            """
            CREATE TABLE "newFolders" (
              "id" INT PRIMARY KEY NOT NULL,
              "title" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "parentID" INTEGER REFERENCES "folders"("id") ON DELETE SET NULL
            ) STRICT
            """
          )
          .execute(db)
          try #sql(#"INSERT INTO "newFolders" SELECT "id", "title", "parentID" FROM "folders""#)
            .execute(db)
          try #sql(#"DROP TABLE "folders""#).execute(db)
          try #sql(#"ALTER TABLE "newFolders" RENAME TO "folders""#).execute(db)
            return .commit
          }
        }

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let relaunchedSyncEngine = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables,
            privateTables: syncEngine.privateTables,
            startImmediately: false
          )
          try await relaunchedSyncEngine.start()

          let pending = relaunchedSyncEngine.private.state.pendingRecordZoneChanges
          #expect(
            Set(pending) == [
              .saveRecord(Folder.recordID(for: 2)),
              .saveRecord(Folder.recordID(for: 3)),
            ]
          )
          try await relaunchedSyncEngine.processPendingRecordZoneChanges(scope: .private)

          let child = try relaunchedSyncEngine.private.database.record(for: Folder.recordID(for: 2))
          let grandchild = try relaunchedSyncEngine.private.database.record(
            for: Folder.recordID(for: 3)
          )
          #expect(child.parent?.recordID == Folder.recordID(for: 1))
          #expect(grandchild.parent?.recordID == Folder.recordID(for: 2))
          #expect(child.encryptedValues["title"] as? String == "Kitchen")

          let after = try await relaunchedSyncEngine.metadatabase.read { db in
            try SyncMetadata
              .where { $0.recordType.eq(Folder.tableName) }
              .order(by: \.recordName)
              .select { ($0.userModificationTime, $0.parentRecordName) }
              .fetchAll(db)
          }
          #expect(after.map(\.0) == modificationTimes)
          #expect(after.map(\.1) == [nil, "1:folders", "2:folders"])

          // A second start finds nothing to fill in.
          relaunchedSyncEngine.stop()
          let again = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables,
            privateTables: syncEngine.privateTables,
            startImmediately: false
          )
          try await again.start()
          #expect(again.private.state.pendingRecordZoneChanges.isEmpty)
        }
      }

      // MARK: - Order

      /// Deleting a hierarchy sends its deepest rows first: CloudKit refuses to delete a record
      /// another record still names as its parent, when the two are sent in separate batches.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteChildrenBeforeParents() async throws {
        try await seedHierarchy()
        try await userDatabase.userWrite { db in
          try Folder.find(1).delete().execute(db)
        }
        let pending = syncEngine.private.state.pendingRecordZoneChanges
        syncEngine.private.state.remove(pendingRecordZoneChanges: pending)
        syncEngine.private.state.add(
          pendingRecordZoneChanges: pending.sorted { "\($0)" < "\($1)" }
        )

        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(
          batch?.recordIDsToDelete == [
            Folder.recordID(for: 3),
            Folder.recordID(for: 2),
            Folder.recordID(for: 1),
          ]
        )

        // Each one alone, in that order, is accepted; the root first would not have been.
        for id in [3, 2, 1] {
          let results = try syncEngine.private.database.modifyRecords(
            deleting: [Folder.recordID(for: id)]
          )
          let result = try #require(results.deleteResults[Folder.recordID(for: id)])
          #expect(throws: Never.self) { try result.get() }
        }
        syncEngine.private.state.remove(
          pendingRecordZoneChanges: syncEngine.private.state.pendingRecordZoneChanges
        )
      }

      /// The root of a hierarchy deleted on its own, ahead of its children, is refused.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletingParentAheadOfChildrenIsRefused() async throws {
        try await seedHierarchy()
        let results = try syncEngine.private.database.modifyRecords(
          deleting: [Folder.recordID(for: 1)]
        )
        let result = try #require(results.deleteResults[Folder.recordID(for: 1)])
        #expect(throws: (any Error).self) { try result.get() }
        _ = try syncEngine.private.database.record(for: Folder.recordID(for: 1))
      }

      // MARK: - Cycles

      /// Two moves, each legal where it was made, make a ring. The triggers, the permission check,
      /// the send order and a deletion all run over it and finish.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cycleRunsThroughTriggersAndSends() async throws {
        try await seedHierarchy()
        _ = try await syncEngine.share(record: Folder(id: 1, title: "Home"), configure: { _ in })

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(1).update { $0.parentID = #bind(3) }.execute(db)
            try Folder.find(2).update { $0.title = "Galley" }.execute(db)
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        let one = try syncEngine.private.database.record(for: Folder.recordID(for: 1))
        #expect(one.parent?.recordID == Folder.recordID(for: 3))
        let two = try syncEngine.private.database.record(for: Folder.recordID(for: 2))
        #expect(two.encryptedValues["title"] as? String == "Galley")

        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(batch == nil)

        try await withDependencies {
          $0.currentTime.now += 2
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(2).delete().execute(db)
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        #expect(try await localFolders().isEmpty)
      }

      // MARK: - Shares

      /// A share of the root carries its grandchild: the grandchild's parents lead to the root,
      /// which carries the share.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func grandchildIsInRootsShare() async throws {
        try await seedHierarchy()
        let shared = try await syncEngine.share(
          record: Folder(id: 1, title: "Home"),
          configure: { _ in }
        )

        var record = try syncEngine.private.database.record(for: Folder.recordID(for: 3))
        var seen: Set<CKRecord.ID> = [record.recordID]
        while let parent = record.parent?.recordID, seen.insert(parent).inserted {
          record = try syncEngine.private.database.record(for: parent)
        }
        #expect(record.recordID == Folder.recordID(for: 1))
        #expect(record.share?.recordID == shared.share.recordID)
        #expect(seen.count == 3)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func receiveSharedHierarchy() async throws -> CKRecordZone.ID {
        let externalZoneID = CKRecordZone.ID(zoneName: "external.zone", ownerName: "external.owner")
        let root = CKRecord(
          recordType: Folder.tableName,
          recordID: Folder.recordID(for: 1, zoneID: externalZoneID)
        )
        root.setValue(1, forKey: "id", at: now)
        root.setValue("Home", forKey: "title", at: now)
        let share = CKShare(
          rootRecord: root,
          shareID: CKRecord.ID(
            recordName: "share-\(root.recordID.recordName)",
            zoneID: externalZoneID
          )
        )
        share.publicPermission = .readWrite
        let child = CKRecord(
          recordType: Folder.tableName,
          recordID: Folder.recordID(for: 2, zoneID: externalZoneID)
        )
        child.setValue(2, forKey: "id", at: now)
        child.setValue("Kitchen", forKey: "title", at: now)
        child.setValue(1, forKey: "parentID", at: now)
        child.parent = CKRecord.Reference(record: root, action: .none)

        try await syncEngine.modifyRecordZones(
          scope: .shared,
          saving: [CKRecordZone(zoneID: externalZoneID)]
        )
        .notify()
        try await syncEngine.modifyRecords(scope: .shared, saving: [root, share, child]).notify()
        return externalZoneID
      }

      /// A participant moving a row of someone's share to the top of their own hierarchy: the
      /// row stays in the owner's zone, CloudKit refuses a record there with neither a parent nor
      /// a share, and the move is undone from the server's copy.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func participantMovesSharedRowToTop() async throws {
        let externalZoneID = try await receiveSharedHierarchy()
        let folders = try await localFolders()
        expectNoDifference(
          folders,
          [Folder(id: 1, title: "Home"), Folder(id: 2, title: "Kitchen", parentID: 1)]
        )

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(2).update { $0.parentID = #bind(nil) }.execute(db)
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .shared)
        }

        let child = try syncEngine.shared.database.record(
          for: Folder.recordID(for: 2, zoneID: externalZoneID)
        )
        #expect(child.parent?.recordID == Folder.recordID(for: 1, zoneID: externalZoneID))
        let foldersAfter = try await localFolders()
        expectNoDifference(
          foldersAfter,
          [Folder(id: 1, title: "Home"), Folder(id: 2, title: "Kitchen", parentID: 1)]
        )
      }

      /// A participant moving a row of someone's share into a hierarchy of their own: the row
      /// takes its new parent's zone, so it is deleted from the owner's zone — the owner loses
      /// it. Pinned so that an app knows what it must refuse.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func participantMovesSharedRowIntoOwnHierarchy() async throws {
        let externalZoneID = try await receiveSharedHierarchy()
        try await userDatabase.userWrite { db in
          try db.seed { Folder(id: 10, title: "Mine") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try Folder.find(2).update { $0.parentID = #bind(10) }.execute(db)
          }
          try await syncEngine.processPendingRecordZoneChanges(scope: .shared)
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        #expect(throws: (any Error).self) {
          try self.syncEngine.shared.database.record(
            for: Folder.recordID(for: 2, zoneID: externalZoneID)
          )
        }
        let moved = try syncEngine.private.database.record(for: Folder.recordID(for: 2))
        #expect(moved.parent?.recordID == Folder.recordID(for: 10))
      }
    }
  }

  extension BaseCloudKitTests {
    /// A hierarchy whose rows are set loose when their parent is deleted, and a parent deleted
    /// on another device.
    @MainActor
    @Suite(.taskLocal($additionalTables, [SynchronizedTable(for: Shelf.self)]))
    final class LooseHierarchySyncTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func seedShelves() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Shelf(id: 1, title: "Home")
            Shelf(id: 2, title: "Kitchen", parentID: 1)
            Shelf(id: 3, title: "Tiles", parentID: 2)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func localShelves() async throws -> [Shelf] {
        try await userDatabase.read { db in try Shelf.order(by: \.id).fetchAll(db) }
      }

      // MARK: - A parent deleted elsewhere

      /// Another device deleted shelf 1 without having heard of 2 inside it, so iCloud holds 2
      /// under a parent it no longer has. Applying 1's deletion here sets 2 loose — and 2 is sent,
      /// at the top, so that a device that never had it can take it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfParentSendsLooseChildren() async throws {
        try await seedShelves()

        await syncEngine.handleFetchedRecordZoneChanges(
          deletions: [(Shelf.recordID(for: 1), Shelf.tableName)],
          syncEngine: syncEngine.private
        )

        let shelves = try await localShelves()
        expectNoDifference(
          shelves,
          [Shelf(id: 2, title: "Kitchen"), Shelf(id: 3, title: "Tiles", parentID: 2)]
        )
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(Shelf.recordID(for: 2))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try syncEngine.private.database.record(for: Shelf.recordID(for: 2)).parent == nil)
        #expect(
          try syncEngine.private.database.record(for: Shelf.recordID(for: 3)).parent?.recordID
            == Shelf.recordID(for: 2)
        )
      }

      /// A parent deleted with its whole subtree sets nothing loose and sends nothing.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfSubtreeSendsNothing() async throws {
        try await seedShelves()

        await syncEngine.handleFetchedRecordZoneChanges(
          deletions: [
            (Shelf.recordID(for: 3), Shelf.tableName),
            (Shelf.recordID(for: 2), Shelf.tableName),
            (Shelf.recordID(for: 1), Shelf.tableName),
          ],
          syncEngine: syncEngine.private
        )

        #expect(try await localShelves().isEmpty)
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }
    }
  }
#endif
