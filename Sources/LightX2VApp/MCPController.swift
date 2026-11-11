import Foundation
import LightX2VCore

/// Local MCP server (Streamable HTTP, JSON-RPC 2.0) exposing one image generation tool.
/// It listens on 127.0.0.1 only and has no authentication. Its preferences are
/// stored independently of the workspace, like the interface language.
@MainActor
final class MCPController: ObservableObject {
    static let shared = MCPController()
    static let path = "/mcp"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    enum Status: Equatable { case off, starting, listening(Int), failed(String) }

    @Published var enabled: Bool {
        didSet { guard oldValue != enabled else { return }; defaults.set(enabled, forKey: Self.enabledKey); restart() }
    }
    @Published private(set) var port: Int
    @Published private(set) var status: Status = .off

    private static let enabledKey = "mcpServerEnabled"
    private static let portKey = "mcpServerPort"
    private let defaults: UserDefaults
    private weak var store: AppStore?
    private var server: MCPHTTPServer?
    private var generation = 0

    var endpoint: String { "http://127.0.0.1:\(port)\(Self.path)" }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["LIGHTX2V_APP_PREFERENCES_SUITE"]
            .flatMap(UserDefaults.init(suiteName:)) ?? .standard
        enabled = self.defaults.bool(forKey: Self.enabledKey)
        let saved = self.defaults.integer(forKey: Self.portKey)
        port = MCPPort.range.contains(saved) ? saved : MCPPort.defaultValue
    }

    func attach(_ store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        restart()
    }

    func setPort(_ value: Int) {
        guard MCPPort.range.contains(value), value != port else { return }
        port = value
        defaults.set(value, forKey: Self.portKey)
        restart()
    }

    func stop() {
        generation += 1
        server?.stop(); server = nil
        status = .off
    }

    private func restart() {
        server?.stop(); server = nil
        generation += 1
        guard enabled, store != nil else { status = .off; return }
        let current = generation
        let port = self.port
        status = .starting
        let server = MCPHTTPServer { [weak self] request, responder in
            Task { @MainActor [weak self] in self?.handle(request, responder) }
        }
        self.server = server
        server.start(port: port) { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                switch state {
                case .listening: self.status = .listening(port)
                case .failed(let message): self.status = .failed(message); self.server = nil
                }
            }
        }
    }

    // MARK: HTTP

    private func handle(_ request: MCPHTTPRequest, _ responder: MCPHTTPResponder) {
        // No authentication: reject browser pages and DNS rebinding, accept local clients only.
        guard Self.isLocal(host: request.header("host")) else { responder.send(status: 403); return }
        if let origin = request.header("origin"), !Self.isLocal(origin: origin) { responder.send(status: 403); return }
        guard request.path == Self.path else { responder.send(status: 404); return }
        switch request.method {
        case "POST": break
        case "GET", "DELETE": responder.send(status: 405, headers: ["Allow": "POST"]); return
        default: responder.send(status: 405, headers: ["Allow": "POST"]); return
        }
        guard (request.header("content-type") ?? "").lowercased().hasPrefix("application/json") else { responder.send(status: 415); return }
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) else {
            responder.json(400, Self.error(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }
        let accept = (request.header("accept") ?? "").lowercased()
        if let messages = payload as? [Any] {
            guard !messages.isEmpty else { responder.json(400, Self.error(id: NSNull(), code: -32600, message: "Invalid Request")); return }
            Task {
                var replies: [Any] = []
                for message in messages { if let reply = await self.reply(to: message, progress: nil) { replies.append(reply) } }
                if replies.isEmpty { responder.send(status: 202) } else { responder.json(200, replies) }
            }
            return
        }
        let message = payload as? [String: Any]
        if message?["method"] as? String == "tools/call", message?["id"] != nil, accept.contains("text/event-stream") {
            // Stream long generations so clients receive progress and keep-alives.
            responder.beginEventStream()
            let token = ((message?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["progressToken"]
            let progress: ((Int, Int) -> Void)? = token.map { token in
                { step, total in
                    responder.event(["jsonrpc": "2.0", "method": "notifications/progress",
                                     "params": ["progressToken": token, "progress": step, "total": total,
                                                "message": "Step \(step) of \(total)"] as [String: Any]])
                }
            }
            Task {
                let reply = await self.reply(to: payload, progress: progress) ?? Self.error(id: NSNull(), code: -32600, message: "Invalid Request")
                responder.event(reply, final: true)
            }
            return
        }
        Task {
            if let reply = await self.reply(to: payload, progress: nil) { responder.json(200, reply) }
            else { responder.send(status: 202) }
        }
    }

    nonisolated static func isLocal(host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        if host.hasPrefix("[") { host = String(host.dropFirst().prefix { $0 != "]" }) }
        else if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    nonisolated static func isLocal(origin: String) -> Bool {
        guard let components = URLComponents(string: origin), let host = components.host else { return false }
        return isLocal(host: host.contains(":") ? "[\(host)]" : host)
    }

    // MARK: JSON-RPC

    /// Returns nil for notifications and client responses, which receive no reply.
    private func reply(to message: Any, progress: ((Int, Int) -> Void)?) async -> Any? {
        guard let message = message as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return Self.error(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lightx2v-app", "title": "LightX2V APP",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"],
                "instructions": "Use generate_image to create one image per call with Qwen-Image-2.1-Turbo running locally. "
                    + "The image is returned inline and saved in the LightX2V APP workspace; its path is included in the result."
            ] as [String: Any])
        case "ping":
            return Self.result(id: id, [String: Any]())
        case "tools/list":
            return Self.result(id: id, ["tools": [MCPImageArguments.tool]])
        case "tools/call":
            guard params["name"] as? String == MCPImageArguments.toolName else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            return Self.result(id: id, await callGenerateImage(params["arguments"] as? [String: Any] ?? [:], progress: progress))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callGenerateImage(_ raw: [String: Any], progress: ((Int, Int) -> Void)?) async -> [String: Any] {
        func failure(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }
        guard let store else { return failure("LightX2V APP is not ready yet.") }
        let arguments: MCPImageArguments
        do { arguments = try MCPImageArguments.parse(raw) } catch { return failure(error.localizedDescription) }
        let job: Generation
        do { job = try await store.generateForMCP(arguments) { step, total in progress?(step, total) } }
        catch { return failure(error.localizedDescription) }
        guard job.status == .completed else {
            return failure("Generation \(job.status.rawValue): \(job.error ?? job.status.label)")
        }
        let path = job.request.output
        let data: Data
        do { data = try await Task.detached { try Data(contentsOf: URL(fileURLWithPath: path)) }.value }
        catch { return failure("The image was generated but could not be read: \(error.localizedDescription)") }
        var details: [String: Any] = ["path": path, "seed": job.request.seed, "prompt": job.request.prompt]
        if let width = job.actualWidth, let height = job.actualHeight { details["width"] = width; details["height"] = height }
        if let enhanced = job.enhancement?.prompt, !enhanced.isEmpty { details["enhanced_prompt"] = enhanced }
        if let duration = job.duration { details["duration_seconds"] = NSDecimalNumber(string: String(format: "%.1f", duration)) }
        let summary = (try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? path
        return ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
                            ["type": "text", "text": summary]],
                "structuredContent": details,
                "isError": false]
    }

    private static func result(id: Any, _ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
