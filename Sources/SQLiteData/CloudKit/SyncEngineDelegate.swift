#if canImport(CloudKit)
  public import CloudKit
  import CustomDump
  public import GRDB
  import IssueReporting

  /// An interface for observing ``SyncEngine`` events and customizing ``SyncEngine`` behavior.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// An event indicating a change to the device's iCloud account.
    ///
    /// By default, a sync engine will clear out local data when detecting a logout or account
    /// change. To override this behavior, _e.g._ if you want to prompt the user and let them decide
    /// if they want to clear their local data or not, implement this method, and explicitly call
    /// ``SyncEngine/deleteLocalData()`` if/when the data should be cleared.
    ///
    /// For example, an observable model could override this method to set up some alert state:
    ///
    /// ```swift
    /// @MainActor
    /// @Observable
    /// class MySyncEngineDelegate: SyncEngineDelegate {
    ///   var isResetDataAlertPresented = false
    ///
    ///   func syncEngine(
    ///     _ syncEngine: SyncEngine,
    ///     accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ///   ) {
    ///     switch changeType {
    ///     case .signOut, .switchAccounts:
    ///       isResetDataAlertPresented = true
    ///     case .signIn:
    ///       break
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// And then SwiftUI could drive an alert with this state:
    ///
    /// ```swift
    /// struct MyApp: App {
    ///   @State var syncEngineDelegate = MySyncEngineDelegate()
    ///
    ///   init() {
    ///     prepareDependencies {
    ///       try! $0.bootstrapDatabase(syncEngineDelegate: syncEngineDelegate)
    ///     }
    ///   }
    ///
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       MyRootView()
    ///         .alert(
    ///           "Reset local data?",
    ///           isPresented: $syncEngineDelegate.isDeleteLocalDataAlertPresented
    ///         ) {
    ///           Button("Reset", role: .destructive) {
    ///             Task {
    ///               try await syncEngine.deleteLocalData()
    ///             }
    ///           }
    ///         } message: {
    ///           Text(
    ///             """
    ///             You are no longer logged into iCloud. Would you like to reset your local data \
    ///             to the defaults? This will not affect your data in iCloud.
    ///             """
    ///           )
    ///         }
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - changeType: The iCloud account's change type.
    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async

    /// A new record — one iCloud has never had — that iCloud refused for lack of permission.
    ///
    /// This happens when a row is written under a share this device still believes it may write
    /// to, after the share's owner made it read-only: the device has not fetched the new share
    /// yet. The row is the only copy of what was just written, so the sync engine never deletes
    /// it. By default it is kept, left unsent, and reported as an issue.
    ///
    /// Implement this method to give such a row a home it may be sent to — for example, by moving
    /// it under a parent in this person's own zone. It is called inside the sync engine's write,
    /// with `db`, and what it writes there is recorded as a change of this device's, sent as any
    /// local edit is: a row moved to another zone is saved there.
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that sent the record.
    ///   - recordID: The refused record's identifier, in the zone it was refused in.
    ///   - tableName: The table of the row the record is of.
    ///   - primaryKey: The row's primary key, as the record's name carries it.
    ///   - db: The database connection the sync engine is writing with.
    /// - Returns: Whether the row was given a home; `false` leaves it unsent and reported.
    func syncEngine(
      _ syncEngine: SyncEngine,
      refusedNewRecord recordID: CKRecord.ID,
      tableName: String,
      primaryKey: String,
      in db: Database
    ) throws -> Bool
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngineDelegate {
    public func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      switch changeType {
      case .signOut, .switchAccounts:
        await withErrorReporting {
          try await syncEngine.deleteLocalData()
        }
      case .signIn:
        break
      @unknown default:
        break
      }
    }

    public func syncEngine(
      _ syncEngine: SyncEngine,
      refusedNewRecord recordID: CKRecord.ID,
      tableName: String,
      primaryKey: String,
      in db: Database
    ) throws -> Bool {
      false
    }
  }
#endif
