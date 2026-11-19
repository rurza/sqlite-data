#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import Foundation
  import InlineSnapshotTesting
  import SQLiteData
  import SnapshotTestingCustomDump
  import Testing

  extension BaseCloudKitTests {
    @Table("invalid:table")
    struct InvalidTable {
      let id: UUID
    }

    @MainActor
    struct SyncEngineValidationTests {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func tableNameValidation() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: InvalidTable.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          #"""
          SyncEngine.SchemaError(
            reason: .invalidTableName("invalid:table"),
            debugDescription: "Table name contains invalid character \':\'"
          )
          """#
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func foreignKeyActionValidation_NoAction() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "parents" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
                ) STRICT
                """
              )
              .execute(db)
              try #sql(
                """
                CREATE TABLE "childs" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "parentID" INTEGER REFERENCES "parents"("id") ON DELETE NO ACTION
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: Child.self, Parent.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .invalidForeignKeyAction(
              ForeignKey(
                table: "parents",
                from: "parentID",
                to: "id",
                onUpdate: .noAction,
                onDelete: .noAction,
                isNotNull: false
              )
            ),
            debugDescription: #"Foreign key "childs"."parentID" action not supported. Must be 'CASCADE', 'SET DEFAULT' or 'SET NULL'."#
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func foreignKeyActionValidation_Restrict() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "parents" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
                ) STRICT
                """
              )
              .execute(db)
              try #sql(
                """
                CREATE TABLE "childs" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "parentID" INTEGER REFERENCES "parents"("id") ON DELETE RESTRICT
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: Parent.self, Child.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .invalidForeignKeyAction(
              ForeignKey(
                table: "parents",
                from: "parentID",
                to: "id",
                onUpdate: .noAction,
                onDelete: .restrict,
                isNotNull: false
              )
            ),
            debugDescription: #"Foreign key "childs"."parentID" action not supported. Must be 'CASCADE', 'SET DEFAULT' or 'SET NULL'."#
          )
          """
        }
      }

      @Table struct Child: Identifiable {
        let id: Int
        var parentID: Parent.ID
      }
      @Table struct Parent: Identifiable {
        let id: Int
      }
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func foreignKeyPointsToOtherSynchronizedTable() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "parents" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
                ) STRICT
                """
              )
              .execute(db)
              try #sql(
                """
                CREATE TABLE "childs" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "parentID" INTEGER REFERENCES "parents"("id") ON DELETE CASCADE
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: Child.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .invalidForeignKey(
              ForeignKey(
                table: "parents",
                from: "parentID",
                to: "id",
                onUpdate: .noAction,
                onDelete: .cascade,
                isNotNull: false
              )
            ),
            debugDescription: #"Foreign key "childs"."parentID" references table "parents" that is not synchronized. Update 'SyncEngine.init' to synchronize "parents". "#
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func doNotValidateTriggersOnNonSyncedTables() async throws {
        let database = try DatabaseQueue(
          path: URL.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite").path()
        )
        try await database.write { db in
          try #sql(
            """
            CREATE TABLE "remindersLists" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "title" TEXT NOT NULL DEFAULT ''
            ) STRICT
            """
          )
          .execute(db)
          try #sql(
            """
            CREATE TRIGGER "non_temporary_trigger"
            AFTER UPDATE ON "remindersLists"
            FOR EACH ROW BEGIN
              SELECT 1;
            END
            """
          )
          .execute(db)
          try #sql(
            """
            CREATE TEMPORARY TRIGGER "temporary_trigger"
            AFTER UPDATE ON "remindersLists"
            FOR EACH ROW BEGIN
              SELECT 1;
            END
            """
          )
          .execute(db)
        }
        let _ = try await SyncEngine(
          container: MockCloudContainer(
            containerIdentifier: "deadbeef",
            privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
            sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
          ),
          userDatabase: UserDatabase(database: database),
          tables: []
        )
      }

      @Table struct ModelWithUniqueColumn {
        let id: Int
        let uniqueValue: Int
      }
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func uniquenessConstraint() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "modelWithUniqueColumns" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "uniqueValue" INTEGER NOT NULL,
                  UNIQUE("uniqueValue")
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: ModelWithUniqueColumn.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .uniquenessConstraint,
            debugDescription: "Uniqueness constraints are not supported for synchronized tables."
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func selfReferenceIsNotACycle() async throws {
        let database = try DatabaseQueue()
        try await database.write { db in
          try #sql(
            """
            CREATE TABLE "recursiveTables" (
              "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
              "parentID" INTEGER REFERENCES "recursiveTables"("id") ON DELETE CASCADE
            ) STRICT
            """
          )
          .execute(db)
        }
        _ = try await SyncEngine(
          container: MockCloudContainer(
            containerIdentifier: "deadbeef",
            privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
            sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
          ),
          userDatabase: UserDatabase(database: database),
          tables: RecursiveTable.self
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func selfReferenceBesideAnotherForeignKeyIsACycle() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "shelfOwners" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
                ) STRICT
                """
              )
              .execute(db)
              try #sql(
                """
                CREATE TABLE "ownedShelves" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "parentID" INTEGER REFERENCES "ownedShelves"("id") ON DELETE CASCADE,
                  "ownerID" INTEGER REFERENCES "shelfOwners"("id") ON DELETE CASCADE
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: ShelfOwner.self,
              OwnedShelf.self
            )
          }
        )
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .cycleDetected,
            debugDescription: "Cycles between tables are not currently permitted in schemas. A table may reference itself when that is its only foreign key."
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cycleValidation() async throws {
        let error = try #require(
          await #expect(throws: (any Error).self) {
            let database = try DatabaseQueue()
            try await database.write { db in
              try #sql(
                """
                CREATE TABLE "cycleAs" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "cycleBID" INTEGER REFERENCES "cycleBs"("id") ON DELETE CASCADE
                ) STRICT
                """
              )
              .execute(db)
              try #sql(
                """
                CREATE TABLE "cycleBs" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  "cycleAID" INTEGER REFERENCES "cycleAs"("id") ON DELETE CASCADE
                ) STRICT
                """
              )
              .execute(db)
            }
            _ = try await SyncEngine(
              container: MockCloudContainer(
                containerIdentifier: "deadbeef",
                privateCloudDatabase: MockCloudDatabase(databaseScope: .private),
                sharedCloudDatabase: MockCloudDatabase(databaseScope: .shared)
              ),
              userDatabase: UserDatabase(database: database),
              tables: CycleA.self,
              CycleB.self
            )
          }
        )
        assertInlineSnapshot(of: error.localizedDescription, as: .customDump) {
          """
          "Could not synchronize data with iCloud."
          """
        }
        assertInlineSnapshot(of: error, as: .customDump) {
          """
          SyncEngine.SchemaError(
            reason: .cycleDetected,
            debugDescription: "Cycles between tables are not currently permitted in schemas. A table may reference itself when that is its only foreign key."
          )
          """
        }
      }
    }
  }

  @Table struct RecursiveTable: Identifiable {
    let id: Int
    let parentID: RecursiveTable.ID?
  }
  @Table struct CycleA: Identifiable {
    let id: Int
    let cycleBID: CycleB.ID?
  }
  @Table struct CycleB: Identifiable {
    let id: Int
    let cycleAID: CycleA.ID?
  }
  @Table("shelfOwners") struct ShelfOwner: Identifiable {
    let id: Int
  }
  @Table("ownedShelves") struct OwnedShelf: Identifiable {
    let id: Int
    let parentID: OwnedShelf.ID?
    let ownerID: ShelfOwner.ID?
  }
#endif
