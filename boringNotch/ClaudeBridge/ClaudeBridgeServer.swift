//
//  ClaudeBridgeServer.swift
//  boringNotch
//
//  Minimal HTTP server on 127.0.0.1 that receives Claude Code hook events.
//  Each request is held open until the user answers in the notch (long-poll).
//

import Foundation
import Network

final class ClaudeBridgeConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var didParse = false
    private var didRespond = false

    /// Called if the client (the hook script) goes away before we answer.
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(onRequest: @escaping (_ path: String, _ body: Data, _ connection: ClaudeBridgeConnection) -> Void) {
        connection.start(queue: queue)
        receive(onRequest: onRequest)
    }

    private func receive(onRequest: @escaping (String, Data, ClaudeBridgeConnection) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if !self.didParse {
                switch self.parse() {
                case .incomplete:
                    break
                case .invalid(let status):
                    self.didParse = true
                    self.send(status: status, body: nil)
                    return
                case .request(let path, let body):
                    self.didParse = true
                    onRequest(path, body, self)
                }
            }

            if isComplete || error != nil {
                if !self.didRespond { self.onClose?() }
                self.connection.cancel()
                return
            }
            self.receive(onRequest: onRequest)
        }
    }

    private enum ParseResult {
        case incomplete
        case invalid(String)
        case request(path: String, body: Data)
    }

    private func parse() -> ParseResult {
        guard buffer.count <= 1_000_000 else { return .invalid("413 Payload Too Large") }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("400 Bad Request")
        }

        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2, requestLine[0] == "POST" else { return .invalid("405 Method Not Allowed") }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length":
                contentLength = Int(parts[1]) ?? 0
            case "origin":
                // Browsers always send Origin; the hook script (curl) never does.
                // Rejecting it stops web pages from posting fake questions.
                return .invalid("403 Forbidden")
            default:
                break
            }
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .request(path: String(requestLine[1]), body: body)
    }

    /// Sends the reply. A nil body means "no decision" (Claude shows its own prompt).
    func respond(_ body: Data?) {
        queue.async { self.send(status: "200 OK", body: body) }
    }

    private func send(status: String, body: Data?) {
        guard !didRespond else { return }
        didRespond = true
        let payload = body ?? Data()
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

final class ClaudeBridgeServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClaudeBridgeServer")
    private var connections: [ObjectIdentifier: ClaudeBridgeConnection] = [:]

    init(port: UInt16, onRequest: @escaping (String, Data, ClaudeBridgeConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { return }
            let connection = ClaudeBridgeConnection(connection: nwConnection, queue: self.queue)
            let key = ObjectIdentifier(connection)
            self.connections[key] = connection
            nwConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.queue.async { self?.connections.removeValue(forKey: key) }
                default:
                    break
                }
            }
            connection.start(onRequest: onRequest)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("ClaudeBridgeServer failed: \(error)")
            }
        }
    }

    func start() {
        listener.start(queue: queue)
    }
}
