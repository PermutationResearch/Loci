import SwiftUI

struct AutoRulesView: View {
    @Bindable var store: LibraryStore
    @State private var rules: [AutoRule] = []
    @State private var showNewRule = false
    @State private var newRuleName = ""
    @State private var newRuleTrigger: RuleTrigger = .fileImported
    @State private var newRuleAction: RuleAction = .autoTag

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
        .background(Color.white)
        .task { rules = AutoRulesEngine.allRules() }
        .sheet(isPresented: $showNewRule) {
            newRuleSheet
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AUTO RULES")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .tracking(0.35)
                    .foregroundStyle(.black.opacity(0.40))
                Text("\(rules.count) rules · \(rules.filter(\.isEnabled).count) active")
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.78))
            }
            Spacer()
            Button {
                showNewRule = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .lociFont(size: 10, weight: .bold, relativeTo: .caption2)
                    Text("New Rule")
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.78), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var rulesList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 88)
        }
    }

    private func ruleRow(_ rule: AutoRule) -> some View {
        HStack(spacing: 12) {
            Button {
                AutoRulesEngine.toggleRule(id: rule.id)
                rules = AutoRulesEngine.allRules()
            } label: {
                Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                    .lociFont(size: 16, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(rule.isEnabled ? .green : .black.opacity(0.20))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.72))
                HStack(spacing: 4) {
                    Text(rule.trigger.rawValue.replacingOccurrences(of: "_", with: " "))
                        .lociFont(size: 8.5, weight: .bold, design: .rounded, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(0.40))
                    Text("→")
                        .foregroundStyle(.black.opacity(0.20))
                    Text(rule.action.rawValue.replacingOccurrences(of: "_", with: " "))
                        .lociFont(size: 8.5, weight: .bold, design: .rounded, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(0.40))
                }
            }

            Spacer()

            if rule.runCount > 0 {
                Text("\(rule.runCount) runs")
                    .lociFont(size: 8.5, weight: .semibold, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.30))
            }

            Button {
                AutoRulesEngine.deleteRule(id: rule.id)
                rules = AutoRulesEngine.allRules()
            } label: {
                Image(systemName: "trash")
                    .lociFont(size: 9, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.25))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "gearshape.2")
                .lociFont(size: 32, weight: .semibold, relativeTo: .title)
                .foregroundStyle(.black.opacity(0.15))
            Text("No rules yet")
                .lociFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(.black.opacity(0.48))
            Text("Create rules to auto-tag, auto-collect, or auto-extract on import")
                .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.black.opacity(0.32))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newRuleSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Rule")
                .lociFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(.black.opacity(0.82))

            TextField("Rule name", text: $newRuleName)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHEN")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.35))
                Picker("Trigger", selection: $newRuleTrigger) {
                    ForEach([RuleTrigger.fileImported, .extensionSaved, .fileType, .sourceContains], id: \.self) { t in
                        Text(t.rawValue.replacingOccurrences(of: "_", with: " ")).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("THEN")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.35))
                Picker("Action", selection: $newRuleAction) {
                    ForEach([RuleAction.autoTag, .autoCollection, .autoExtract, .autoCompile], id: \.self) { a in
                        Text(a.rawValue.replacingOccurrences(of: "_", with: " ")).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Spacer()
                Button("Cancel") { showNewRule = false }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(.black.opacity(0.52))
                Button("Create") {
                    AutoRulesEngine.createRule(name: newRuleName, trigger: newRuleTrigger, action: newRuleAction)
                    rules = AutoRulesEngine.allRules()
                    showNewRule = false
                    newRuleName = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.82))
                .disabled(newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(Color(red: 0.98, green: 0.98, blue: 0.97))
    }
}
