import Foundation
import Network

struct MCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Writes one HTTP response, either complete or as a Server-Sent Events stream.
/// Every connection closes after its response.
final class MCPHTTPResponder: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var finished = false
    private var streaming = false
    private var keepAlive: DispatchSourceTimer?

    init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    func send(status: Int, contentType: String? = nil, body: Data = Data(), headers: [String: String] = [:]) {
        queue.async { [self] in
            guard !finished, !streaming else { return }
            finished = true
            var fields = headers
            if let contentType { fields["Content-Type"] = contentType }
            fields["Content-Length"] = String(body.count)
            write(head(status, fields) + body, final: true)
        }
    }

    func json(_ status: Int, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        send(status: status, contentType: "application/json", body: body)
    }

    func beginEventStream() {
        queue.async { [self] in
            guard !finished, !streaming else { return }
            streaming = true
            write(head(200, ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]), final: false)
            // Comments keep idle proxies and client timeouts from closing long generations.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in self?.write(Data(": keep-alive\n\n".utf8), final: false) }
            timer.resume()
            keepAlive = timer
        }
    }

    func event(_ object: Any, final: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        queue.async { [self] in
            guard streaming, !finished else { return }
            if final { finished = true; keepAlive?.cancel(); keepAlive = nil }
            write(Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8), final: final)
        }
    }

    fileprivate func abandon() {
        queue.async { [self] in finished = true; keepAlive?.cancel(); keepAlive = nil }
    }

    private func head(_ status: Int, _ fields: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private func write(_ data: Data, final: Bool) {
        connection.send(content: data, completion: .contentProcessed { [connection] error in
            if final || error != nil { connection.cancel() }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"; case 202: return "Accepted"; case 400: return "Bad Request"
        case 403: return "Forbidden"; case 404: return "Not Found"; case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"; case 413: return "Payload Too Large"; case 415: return "Unsupported Media Type"
        default: return "Error"
        }
    }
}

/// Minimal HTTP/1.1 listener bound to the loopback interface only.
final class MCPHTTPServer: @unchecked Sendable {
    enum State { case listening, failed(String) }
    private static let maximumHeader = 64 * 1024
    private static let maximumBody = 4 * 1024 * 1024
    private let queue = DispatchQueue(label: "app.lightx2v.mcp")
    private var listener: NWListener?
    private let handler: (MCPHTTPRequest, MCPHTTPResponder) -> Void

    init(handler: @escaping (MCPHTTPRequest, MCPHTTPResponder) -> Void) { self.handler = handler }

    func start(port: Int, onState: @escaping (State) -> Void) {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { onState(.failed("Invalid port \(port)")); return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: onState(.listening)
                case .failed(let error), .waiting(let error):
                    listener?.cancel()
                    if self?.listener === listener { self?.listener = nil }
                    onState(.failed(error.localizedDescription))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch { onState(.failed(error.localizedDescription)) }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let responder = MCPHTTPResponder(connection: connection, queue: self.queue)
            switch Self.parse(buffer) {
            case .incomplete:
                if complete || error != nil { connection.cancel(); return }
                self.receive(connection, buffer: buffer)
            case .invalid(let status):
                responder.send(status: status)
            case .request(let request):
                self.watchDisconnect(connection, responder: responder)
                self.handler(request, responder)
            }
        }
    }

    /// Observes the client closing early so long-running streams stop writing.
    private func watchDisconnect(_ connection: NWConnection, responder: MCPHTTPResponder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, complete, error in
            if complete || error != nil { responder.abandon(); connection.cancel() }
            else { self?.watchDisconnect(connection, responder: responder) }
        }
    }

    private enum Parsed { case incomplete, invalid(Int), request(MCPHTTPRequest) }

    private static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maximumHeader ? .invalid(413) : .incomplete
        }
        guard end.lowerBound <= maximumHeader, let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(400) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(400) }
        guard length <= maximumBody else { return .invalid(413) }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let path = String(start[1].split(separator: "?", maxSplits: 1).first ?? "")
        return .request(MCPHTTPRequest(method: String(start[0]), path: path, headers: headers,
                                       body: buffer.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
