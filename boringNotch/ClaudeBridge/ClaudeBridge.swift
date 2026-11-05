//
//  ClaudeBridge.swift
//  boringNotch
//
//  Shows Claude Code permission prompts and questions in the notch and sends
//  the user's answer back to the waiting hook (see claude-bridge/ in the repo root).
//

import Combine
import Foundation

struct ClaudeQuestionOption: Hashable {
    let label: String
    let description: String
}

struct ClaudeQuestion: Hashable {
    let text: String
    let header: String
    let options: [ClaudeQuestionOption]
    let multiSelect: Bool
}

enum ClaudeRequestKind {
    /// Claude wants to run a tool. `detail` is the command, file or URL.
    case permission(tool: String, detail: String)
    /// Claude asked one or more multiple-choice questions (AskUserQuestion).
    case questions([ClaudeQuestion])
    /// Informational only, e.g. "Claude is waiting for your input".
    case notice(String)
}

final class ClaudeRequest: Identifiable {
    let id = UUID()
    let project: String
    let kind: ClaudeRequestKind
    fileprivate let toolInput: [String: Any]
    fileprivate let connection: ClaudeBridgeConnection?

    fileprivate init(project: String, kind: ClaudeRequestKind, toolInput: [String: Any] = [:], connection: ClaudeBridgeConnection?) {
        self.project = project
        self.kind = kind
        self.toolInput = toolInput
        self.connection = connection
    }
}

@MainActor
final class ClaudeBridge: ObservableObject {
    static let shared = ClaudeBridge()
    static let port: UInt16 = 47823

    /// Unanswered requests hand back to Claude's own prompt after this long.
    private static let answerTimeout: Duration = .seconds(300)
    private static let noticeDuration: Duration = .seconds(8)

    @Published private(set) var current: ClaudeRequest?
    @Published private(set) var queuedCount = 0

    private var queue: [ClaudeRequest] = [] {
        didSet { queuedCount = queue.count }
    }
    private var server: ClaudeBridgeServer?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard server == nil else { return }
        do {
            server = try ClaudeBridgeServer(port: Self.port) { path, body, connection in
                Task { @MainActor in
                    ClaudeBridge.shared.receive(path: path, body: body, connection: connection)
                }
            }
            server?.start()
        } catch {
            print("ClaudeBridge: could not start server: \(error)")
        }
    }

    // MARK: - Incoming hook events

    private func receive(path: String, body: Data, connection: ClaudeBridgeConnection) {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            connection.respond(nil)
            return
        }
        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent

        switch path {
        case "/permission":
            guard let request = permissionRequest(from: json, project: project, connection: connection) else {
                connection.respond(nil)
                return
            }
            connection.onClose = { [id = request.id] in
                // Hook was killed (e.g. the user pressed Esc in Claude) — drop the question.
                Task { @MainActor in ClaudeBridge.shared.remove(id: id) }
            }
            enqueue(request)

        case "/notify":
            connection.respond(nil)
            let type = json["notification_type"] as? String ?? ""
            guard ["idle_prompt", "agent_needs_input"].contains(type) else { return }
            let message = json["message"] as? String ?? "Claude is waiting for your input"
            enqueue(ClaudeRequest(project: project, kind: .notice(message), connection: nil))

        default:
            connection.respond(nil)
        }
    }

    private func permissionRequest(from json: [String: Any], project: String, connection: ClaudeBridgeConnection) -> ClaudeRequest? {
        let tool = json["tool_name"] as? String ?? "a tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]

        switch tool {
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                ClaudeQuestion(
                    text: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        ClaudeQuestionOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                    },
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            }
            guard !questions.isEmpty else { return nil }
            return ClaudeRequest(project: project, kind: .questions(questions), toolInput: input, connection: connection)

        case "ExitPlanMode":
            // Plans are long; review them in Claude itself.
            return nil

        default:
            return ClaudeRequest(project: project, kind: .permission(tool: tool, detail: Self.detail(for: input)), toolInput: input, connection: connection)
        }
    }

    private static func detail(for input: [String: Any]) -> String {
        for key in ["command", "file_path", "url", "path", "pattern", "query", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(400))
    }

    // MARK: - Queue

    private func enqueue(_ request: ClaudeRequest) {
        if current == nil {
            show(request)
        } else {
            queue.append(request)
        }
    }

    private func show(_ request: ClaudeRequest) {
        current = request
        timeoutTask?.cancel()
        let isNotice: Bool
        if case .notice = request.kind { isNotice = true } else { isNotice = false }
        timeoutTask = Task { [id = request.id] in
            try? await Task.sleep(for: isNotice ? Self.noticeDuration : Self.answerTimeout)
            guard !Task.isCancelled, self.current?.id == id else { return }
            self.finish(with: nil)
        }
    }

    private func remove(id: UUID) {
        if current?.id == id {
            finish(with: nil)
        } else {
            queue.removeAll { $0.id == id }
        }
    }

    private func finish(with reply: Data?) {
        timeoutTask?.cancel()
        current?.connection?.respond(reply)
        if queue.isEmpty {
            current = nil
        } else {
            show(queue.removeFirst())
        }
    }

    // MARK: - Answers from the notch UI

    func allow() {
        finish(with: Self.decision(["behavior": "allow"]))
    }

    func deny() {
        finish(with: Self.decision(["behavior": "deny", "message": "The user denied this from Dynamic Island."]))
    }

    /// `answers` maps each question's text to the chosen label(s), comma-separated.
    func answer(_ answers: [String: String]) {
        guard let request = current else { return }
        var updatedInput = request.toolInput
        updatedInput["answers"] = answers
        finish(with: Self.decision(["behavior": "allow", "updatedInput": updatedInput]))
    }

    /// Hand the request back so Claude shows its normal prompt.
    func answerInClaude() {
        finish(with: nil)
    }

    func dismiss() {
        finish(with: nil)
    }

    private static func decision(_ decision: [String: Any]) -> Data? {
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: output)
    }
}
