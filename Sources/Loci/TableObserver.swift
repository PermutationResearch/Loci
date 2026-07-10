import Combine
import Foundation
import GRDB

struct LociDatabaseChanges: Sendable {
    var referenceIDs: Set<UUID> = []
    var collectionsChanged = false
    var importJobsChanged = false
    var xPayloadsChanged = false

    var isEmpty: Bool {
        referenceIDs.isEmpty && !collectionsChanged && !importJobsChanged && !xPayloadsChanged
    }
}

private struct LociDatabaseState: Equatable {
    var references: [String: String]
    var collectionsToken: String
    var importJobsToken: String
    var xPayloadsToken: String
}

@MainActor
final class TableObserver {
    static let shared = TableObserver()

    private var cancellable: AnyCancellable?
    private var previousState: LociDatabaseState?

    func startObserving(onUpdate: @escaping (LociDatabaseChanges) -> Void) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }

        let observation = ValueObservation.tracking { db -> LociDatabaseState in
            let referenceRows = try Row.fetchAll(db, sql: """
                SELECT ri.id,
                       ri.updated_at || ':' || IFNULL(MAX(a.thumbnail_path), '') AS token
                FROM reference_items ri
                LEFT JOIN assets a ON a.reference_id = ri.id
                    AND (a.role = 'screenshot' OR a.role = 'primary')
                WHERE ri.deleted_at IS NULL
                GROUP BY ri.id, ri.updated_at
                """)
            let referencePairs: [(String, String)] = referenceRows.compactMap { row -> (String, String)? in
                guard let id = row["id"] as String?, let token = row["token"] as String? else { return nil }
                return (id, token)
            }
            let references: [String: String] = Dictionary(uniqueKeysWithValues: referencePairs)
            let collectionsToken = try String.fetchOne(db, sql: """
                SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '')
                FROM collections WHERE deleted_at IS NULL
                """) ?? ""
            let importJobsToken = try String.fetchOne(db, sql: """
                SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '') FROM import_jobs
                """) ?? ""
            let xPayloadsToken = try String.fetchOne(db, sql: """
                SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '')
                FROM import_jobs
                WHERE reference_id IS NOT NULL
                  AND (source = 'extension' OR source = 'wiki-compile')
                """) ?? ""
            return LociDatabaseState(
                references: references,
                collectionsToken: collectionsToken,
                importJobsToken: importJobsToken,
                xPayloadsToken: xPayloadsToken
            )
        }

        cancellable = AnyCancellable(
            observation.publisher(in: queue)
                .debounce(
                    for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(120),
                    scheduler: DispatchQueue.main
                )
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { [weak self] (state: LociDatabaseState) in
                        guard let self else { return }
                        defer { previousState = state }
                        guard let previousState else { return }
                        let allReferenceIDs = Set(previousState.references.keys).union(state.references.keys)
                        let changedReferenceIDs = Set(allReferenceIDs.compactMap { id -> UUID? in
                            guard previousState.references[id] != state.references[id] else { return nil }
                            return UUID(uuidString: id)
                        })
                        let changes = LociDatabaseChanges(
                            referenceIDs: changedReferenceIDs,
                            collectionsChanged: previousState.collectionsToken != state.collectionsToken,
                            importJobsChanged: previousState.importJobsToken != state.importJobsToken,
                            xPayloadsChanged: previousState.xPayloadsToken != state.xPayloadsToken
                        )
                        if !changes.isEmpty { onUpdate(changes) }
                    }
                )
        )
    }

    func stopObserving() {
        cancellable?.cancel()
        cancellable = nil
        previousState = nil
    }
}
