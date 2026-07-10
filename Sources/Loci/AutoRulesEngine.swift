import Foundation
import GRDB

struct AutoRule: Identifiable, Hashable {
    var id: UUID
    var name: String
    var trigger: RuleTrigger
    var action: RuleAction
    var isEnabled: Bool
    var runCount: Int
    var lastRunAt: Date?
    var createdAt: Date
}

enum RuleTrigger: String, Codable, Hashable {
    case fileImported = "file_imported"
    case extensionSaved = "extension_saved"
    case fileType = "file_type"
    case sourceContains = "source_contains"
}

enum RuleAction: String, Codable, Hashable {
    case autoTag = "auto_tag"
    case autoCollection = "auto_collection"
    case autoExtract = "auto_extract"
    case autoCompile = "auto_compile"
}

struct RuleDefinition: Codable, Hashable {
    var trigger: RuleTrigger
    var action: RuleAction
    var parameters: [String: String]
}

@MainActor
enum AutoRulesEngine {
    static func allRules() -> [AutoRule] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM auto_rules ORDER BY created_at DESC").compactMap { row in
                    guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                          let name = row["name"] as String?,
                          let triggerStr = row["trigger_json"] as String?,
                          let actionStr = row["action_json"] as String? else { return nil }
                    let trigger = (try? JSONDecoder().decode(RuleTrigger.self, from: Data(triggerStr.utf8))) ?? .fileImported
                    let action = (try? JSONDecoder().decode(RuleAction.self, from: Data(actionStr.utf8))) ?? .autoTag
                    return AutoRule(
                        id: id, name: name, trigger: trigger, action: action,
                        isEnabled: (row["is_enabled"] as Int? ?? 1) != 0,
                        runCount: row["run_count"] as Int? ?? 0,
                        lastRunAt: (row["last_run_at"] as String?).flatMap { ISO8601DateFormatter().date(from: $0) },
                        createdAt: ISO8601DateFormatter().date(from: row["created_at"] as String? ?? "") ?? Date()
                    )
                }
            }
        } catch {
            return []
        }
    }

    static func createRule(name: String, trigger: RuleTrigger, action: RuleAction) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let id = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO auto_rules (id, name, trigger_json, action_json, is_enabled, run_count, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, 0, ?, ?)
                """, arguments: [id.uuidString, name, "\"\(trigger.rawValue)\"", "\"\(action.rawValue)\"", now, now])
            }
        } catch {
            print("GRDB createRule failed: \(error)")
        }
    }

    static func toggleRule(id: UUID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE auto_rules SET is_enabled = CASE WHEN is_enabled = 1 THEN 0 ELSE 1 END WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            print("GRDB toggleRule failed: \(error)")
        }
    }

    static func deleteRule(id: UUID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM auto_rules WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            print("GRDB deleteRule failed: \(error)")
        }
    }

    static func processImport(itemID: ReferenceItem.ID, fileExtension: String, sourceURL: URL?) {
        let rules = allRules().filter { $0.isEnabled }
        for rule in rules {
            guard shouldTrigger(rule: rule, fileExtension: fileExtension, sourceURL: sourceURL) else { continue }
            executeAction(rule: rule, itemID: itemID)
            incrementRunCount(ruleID: rule.id)
        }
    }

    static func runRulesForImport(itemID: ReferenceItem.ID, source: ImportSourceKind, payload: String) {
        let rules = allRules().filter { $0.isEnabled }
        for rule in rules {
            let matchesTrigger: Bool
            switch rule.trigger {
            case .fileImported:
                matchesTrigger = source == .file
            case .extensionSaved:
                matchesTrigger = source == .browserExtension
            case .fileType:
                let ext = (payload as NSString).pathExtension.lowercased()
                matchesTrigger = !ext.isEmpty
            case .sourceContains:
                matchesTrigger = true
            }
            guard matchesTrigger else { continue }
            executeAction(rule: rule, itemID: itemID)
            incrementRunCount(ruleID: rule.id)
        }
    }

    private static func shouldTrigger(rule: AutoRule, fileExtension: String, sourceURL: URL?) -> Bool {
        switch rule.trigger {
        case .fileImported:
            return true
        case .fileType:
            return true
        case .extensionSaved:
            return true
        case .sourceContains:
            return true
        }
    }

    private static func executeAction(rule: AutoRule, itemID: ReferenceItem.ID) {
        switch rule.action {
        case .autoTag:
            let tagName = rule.name.replacingOccurrences(of: " ", with: "-").lowercased()
            TagHierarchy.addTag(tagName, to: itemID)
        case .autoCollection:
            break
        case .autoExtract:
            Task { @MainActor in
                await ImportCoordinator.shared.enqueueProcess()
            }
        case .autoCompile:
            Task { @MainActor in
                await ImportCoordinator.shared.enqueueProcess()
            }
        }
    }

    private static func incrementRunCount(ruleID: UUID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE auto_rules SET run_count = run_count + 1, last_run_at = ? WHERE id = ?", arguments: [now, ruleID.uuidString])
            }
        } catch {}
    }
}
