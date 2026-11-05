//
//  ClaudeQuestionView.swift
//  boringNotch
//
//  The expanded-notch content shown while Claude is waiting on the user.
//

import SwiftUI

private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

struct ClaudeQuestionView: View {
    @ObservedObject var bridge = ClaudeBridge.shared
    let request: ClaudeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            switch request.kind {
            case .permission(let tool, let detail):
                PermissionContent(tool: tool, detail: detail)
            case .questions(let questions):
                QuestionsContent(questions: questions)
            case .notice(let message):
                NoticeContent(message: message)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(request.id) // reset selections when the next request arrives
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .foregroundStyle(claudeOrange)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(request.project)
                .font(.system(size: 12))
                .foregroundStyle(.gray)
                .lineLimit(1)
            Spacer()
            if bridge.queuedCount > 0 {
                Text("+\(bridge.queuedCount) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
        }
        .foregroundStyle(.white)
    }

    private var title: String {
        switch request.kind {
        case .permission: return "Claude needs permission"
        case .questions: return "Claude has a question"
        case .notice: return "Claude is waiting"
        }
    }
}

// MARK: - Permission

private struct PermissionContent: View {
    let tool: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow **\(tool)**?")
                .font(.system(size: 13))
                .foregroundStyle(.white)
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            }
            Spacer(minLength: 0)
            HStack {
                ClaudeButton("Answer in Claude", style: .plain) { ClaudeBridge.shared.answerInClaude() }
                Spacer()
                ClaudeButton("Deny", style: .secondary) { ClaudeBridge.shared.deny() }
                ClaudeButton("Allow", style: .primary) { ClaudeBridge.shared.allow() }
            }
        }
    }
}

// MARK: - Questions (AskUserQuestion)

private struct QuestionsContent: View {
    let questions: [ClaudeQuestion]
    @State private var selections: [Int: Set<String>] = [:]
    @State private var otherText: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionBlock(index: index, question: question)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                ClaudeButton("Answer in Claude", style: .plain) { ClaudeBridge.shared.answerInClaude() }
                Spacer()
                ClaudeButton("Send", style: .primary, disabled: !isComplete) {
                    ClaudeBridge.shared.answer(answers)
                }
            }
        }
    }

    private func questionBlock(index: Int, question: ClaudeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            FlowRow(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    let selected = selections[index, default: []].contains(option.label)
                    Button {
                        toggle(option.label, at: index, multiSelect: question.multiSelect)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .liquidGlass(in: Capsule(), tint: selected ? claudeOrange : nil, interactive: true)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(option.description)
                }
                TextField("Other…", text: Binding(
                    get: { otherText[index, default: ""] },
                    set: { otherText[index] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 160)
                .background(Capsule().fill(.white.opacity(0.08)))
                .foregroundStyle(.white)
                .onSubmit { if isComplete { ClaudeBridge.shared.answer(answers) } }
            }
        }
    }

    private func toggle(_ label: String, at index: Int, multiSelect: Bool) {
        var current = selections[index, default: []]
        if current.contains(label) {
            current.remove(label)
        } else if multiSelect {
            current.insert(label)
        } else {
            current = [label]
        }
        selections[index] = current
    }

    private func answerText(for index: Int) -> String {
        let question = questions[index]
        // Keep the option order Claude gave, not tap order.
        var parts = question.options.map(\.label).filter { selections[index, default: []].contains($0) }
        let other = otherText[index, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { parts.append(other) }
        return parts.joined(separator: ", ")
    }

    private var isComplete: Bool {
        questions.indices.allSatisfy { !answerText(for: $0).isEmpty }
    }

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.indices.map { (questions[$0].text, answerText(for: $0)) })
    }
}

// MARK: - Notice

private struct NoticeContent: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                ClaudeButton("Dismiss", style: .secondary) { ClaudeBridge.shared.dismiss() }
            }
        }
    }
}

// MARK: - Building blocks

private struct ClaudeButton: View {
    enum Style { case primary, secondary, plain }

    let title: String
    let style: Style
    let disabled: Bool
    let action: () -> Void

    init(_ title: String, style: Style, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: style == .primary ? .semibold : .medium))
                .padding(.horizontal, style == .plain ? 4 : 12)
                .padding(.vertical, 5)
                .modifier(ClaudeButtonBackground(style: style))
                .foregroundStyle(style == .plain ? .gray : .white)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

}

private struct ClaudeButtonBackground: ViewModifier {
    let style: ClaudeButton.Style

    func body(content: Content) -> some View {
        switch style {
        case .primary: content.liquidGlass(in: Capsule(), tint: claudeOrange, interactive: true)
        case .secondary: content.liquidGlass(in: Capsule(), interactive: true)
        case .plain: content
        }
    }
}

/// Lays children out left to right, wrapping to a new line when full (like CSS flex-wrap).
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
