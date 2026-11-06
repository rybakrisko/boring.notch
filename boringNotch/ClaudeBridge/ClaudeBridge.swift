//
//  ClaudeBridge.swift
//  boringNotch
//
//  Shows Claude Code permission prompts and questions in the notch and sends
//  the user's answer back to the waiting hook (see claude-bridge/ in the repo root).
//

import AppKit
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
}

final class ClaudeRequest: Identifiable {
    let id = UUID()
    let project: String
    let kind: ClaudeRequestKind
    /// Bundle ID of the app the Claude session runs in (Claude desktop, Terminal…).
    let host: String
    /// Claude's suggested "always allow" rules, passed back as-is.
    let alwaysAllowRules: [[String: Any]]
    fileprivate let toolInput: [String: Any]
    fileprivate let connection: ClaudeBridgeConnection?

    fileprivate init(project: String, kind: ClaudeRequestKind, host: String, alwaysAllowRules: [[String: Any]] = [],
                     toolInput: [String: Any] = [:], connection: ClaudeBridgeConnection?) {
        self.project = project
        self.kind = kind
        self.host = host
        self.alwaysAllowRules = alwaysAllowRules
        self.toolInput = toolInput
        self.connection = connection
    }

    /// Short description of the "always allow" rule, e.g. `Bash(npm test:*)`.
    var alwaysAllowDescription: String {
        alwaysAllowRules
            .flatMap { $0["rules"] as? [[String: Any]] ?? [] }
            .map { rule in
                let tool = rule["toolName"] as? String ?? ""
                if let content = rule["ruleContent"] as? String, !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            .joined(separator: ", ")
    }
}

@MainActor
final class ClaudeBridge: ObservableObject {
    static let shared = ClaudeBridge()
    static let port: UInt16 = 47823

    /// Used when the hook doesn't say which app the session runs in.
    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    /// Unanswered requests hand back to Claude's own prompt after this long.
    private static let answerTimeout: Duration = .seconds(300)

    @Published private(set) var current: ClaudeRequest?
    @Published private(set) var queuedCount = 0

    private var queue: [ClaudeRequest] = [] {
        didSet { queuedCount = queue.count }
    }
    private var server: ClaudeBridgeServer?
    private var timeoutTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard server == nil else { return }
        do {
            server = try ClaudeBridgeServer(port: Self.port) { path, host, body, connection in
                Task { @MainActor in
                    ClaudeBridge.shared.receive(path: path, host: host, body: body, connection: connection)
                }
            }
            server?.start()
        } catch {
            print("ClaudeBridge: could not start server: \(error)")
        }

        // If the user switches to the app the question came from, answer it there instead.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            Task { @MainActor in ClaudeBridge.shared.handBack(toAppWithBundleID: bundleID) }
        }
    }

    // MARK: - Incoming hook events

    private func receive(path: String, host: String, body: Data, connection: ClaudeBridgeConnection) {
        // Only permission prompts and questions are shown; everything else
        // (e.g. "Claude is waiting for your input" notifications) is ignored.
        guard path == "/permission",
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            connection.respond(nil)
            return
        }
        let host = host.isEmpty ? Self.claudeDesktopBundleID : host

        // The user is already looking at Claude — let it show its own prompt.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host {
            connection.respond(nil)
            return
        }

        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent
        guard let request = permissionRequest(from: json, project: project, host: host, connection: connection) else {
            connection.respond(nil)
            return
        }
        connection.onClose = { [id = request.id] in
            // Hook was killed (e.g. the user answered or pressed Esc in Claude) — drop the question.
            Task { @MainActor in ClaudeBridge.shared.remove(id: id) }
        }
        enqueue(request)
    }

    private func permissionRequest(from json: [String: Any], project: String, host: String, connection: ClaudeBridgeConnection) -> ClaudeRequest? {
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
            return ClaudeRequest(project: project, kind: .questions(questions), host: host, toolInput: input, connection: connection)

        case "ExitPlanMode":
            // Plans are long; review them in Claude itself.
            return nil

        default:
            let suggestions = json["permission_suggestions"] as? [[String: Any]] ?? []
            return ClaudeRequest(
                project: project,
                kind: .permission(tool: tool, detail: Self.detail(for: input)),
                host: host,
                alwaysAllowRules: suggestions.filter { ($0["behavior"] as? String) == "allow" },
                toolInput: input,
                connection: connection
            )
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
        timeoutTask = Task { [id = request.id] in
            try? await Task.sleep(for: Self.answerTimeout)
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

    /// Returns every request from `bundleID` to Claude's own prompt.
    private func handBack(toAppWithBundleID bundleID: String) {
        for request in queue where request.host == bundleID {
            request.connection?.respond(nil)
        }
        queue.removeAll { $0.host == bundleID }
        if current?.host == bundleID {
            finish(with: nil)
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

    /// Allows this request and adds Claude's suggested rule so it isn't asked again.
    func alwaysAllow() {
        guard let rules = current?.alwaysAllowRules, !rules.isEmpty else { return allow() }
        finish(with: Self.decision(["behavior": "allow", "updatedPermissions": rules]))
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
