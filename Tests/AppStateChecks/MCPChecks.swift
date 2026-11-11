import AppKit
import LightX2VCore

/// Drives the local MCP server over real HTTP against an AppStore whose inference
/// process is a fast fixture. State, preferences and outputs live in a new temporary directory.
@MainActor
func mcpChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mcp-check-" + UUID().uuidString)
    let previous = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    let suite = "app.lightx2v.mcp-check." + UUID().uuidString
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        UserDefaults().removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }
    func check(_ good: @autoclosure () -> Bool, _ message: String) throws {
        guard good() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func png(_ width: Int, _ height: Int, at url: URL) throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        image.bitmapData!.initialize(repeating: 200, count: width * height * 4)
        try image.representation(using: .png, properties: [:])!.write(to: url)
    }

    // Fixture workspace, model and inference process.
    let support = root.appendingPathComponent("support")
    let workspace = root.appendingPathComponent("workspace")
    let source = root.appendingPathComponent("source")
    let model = root.appendingPathComponent("model")
    let executable = root.appendingPathComponent("fixture-python")
    try fm.createDirectory(at: source.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
    try Data().write(to: source.appendingPathComponent("lightx2v/infer.py"))
    for name in ["transformer", "text_encoder", "vae", "scheduler", "processor"] {
        try fm.createDirectory(at: model.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: model.appendingPathComponent("model_index.json"))
    try png(64, 32, at: root.appendingPathComponent("fixture.png"))
    let reference = root.appendingPathComponent("reference image.png")
    try png(40, 30, at: reference)
    let script = """
    #!/usr/bin/env python3
    import json, shutil, sys
    from pathlib import Path
    request = json.load(open(sys.argv[-1]))
    outputs = request.get("outputs") or [{"seed": request["seed"], "output": request["output"]}]
    Path(request["output"]).with_name("fixture-request.json").write_text(json.dumps(request))
    for step in range(1, 9):
        print(json.dumps({"type": "step", "step": step, "total": 8}), flush=True)
    shutil.copyfile(Path(__file__).with_name("fixture.png"), outputs[0]["output"])
    print(json.dumps({"type": "done", "status": "completed", "duration": 0.2, "width": 64, "height": 32}), flush=True)
    """
    try Data(script.utf8).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let layout = WorkspaceLayout(workspace.path)
    try layout.prepare()
    var settings = AppSettings(repository: source.path, model: model.path, config: root.appendingPathComponent("config.json").path,
                               python: executable.path, workingDirectory: workspace.path)
    settings.promptEnhancement.enabled = false
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: workspace.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    for _ in 0..<300 where !store.readyModelResources.contains(.turbo) { try await Task.sleep(for: .milliseconds(10)) }
    try check(store.readyModelResources.contains(.turbo), "fixture Turbo model is ready")

    // Preferences are independent of the workspace and default to off.
    let defaults = UserDefaults(suiteName: suite)!
    let mcp = MCPController(defaults: defaults)
    try check(!mcp.enabled && mcp.port == MCPPort.defaultValue && mcp.status == .off, "MCP server defaults to off on the default port")
    mcp.attach(store)
    try check(mcp.status == .off, "attaching does not start a disabled server")
    let port = Int.random(in: 42000...48000)
    mcp.setPort(port)
    mcp.enabled = true
    for _ in 0..<300 where mcp.status != .listening(port) { try await Task.sleep(for: .milliseconds(10)) }
    try check(mcp.status == .listening(port) && mcp.endpoint == "http://127.0.0.1:\(port)/mcp", "enabled server listens on the configured loopback port")
    try check(MCPController(defaults: defaults).enabled && MCPController(defaults: defaults).port == port, "enabled state and port persist in preferences")

    let blocker = MCPController(defaults: UserDefaults(suiteName: suite + ".blocker")!)
    blocker.setPort(port); blocker.enabled = true; blocker.attach(store)
    for _ in 0..<300 { if case .failed = blocker.status { break }; try await Task.sleep(for: .milliseconds(10)) }
    if case .failed = blocker.status { print("PASS a busy port reports a start failure") } else { throw AppError.message("Busy port did not fail: \(blocker.status)") }
    blocker.stop()
    UserDefaults().removePersistentDomain(forName: suite + ".blocker")

    let url = URL(string: mcp.endpoint)!
    let session = URLSession(configuration: .ephemeral)
    func post(_ body: Any, headers: [String: String] = [:], accept: String = "application/json, text/event-stream",
              to target: URL? = nil) async throws -> (Int, [String: String], Data) {
        var request = URLRequest(url: target ?? url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        let fields = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") })
        return (http.statusCode, fields, data)
    }
    func rpc(_ id: Int, _ method: String, _ params: [String: Any] = [:], accept: String = "application/json") async throws -> [String: Any] {
        let (status, _, data) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], accept: accept)
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("Unexpected \(method) response \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return object
    }

    let initialize = try await rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                     "clientInfo": ["name": "check", "version": "1"]])
    let info = initialize["result"] as? [String: Any]
    try check(info?["protocolVersion"] as? String == "2025-06-18" && (info?["capabilities"] as? [String: Any])?["tools"] != nil,
              "initialize negotiates the protocol and advertises tools")
    let legacy = try await rpc(2, "initialize", ["protocolVersion": "1999-01-01"])
    try check((legacy["result"] as? [String: Any])?["protocolVersion"] as? String == MCPController.supportedProtocolVersions[0],
              "unsupported protocol versions fall back to the latest supported version")
    let notification = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try check(notification.0 == 202 && notification.2.isEmpty, "notifications are accepted without a body")

    let list = try await rpc(3, "tools/list")
    let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    let schema = tools.first?["inputSchema"] as? [String: Any]
    let properties = schema?["properties"] as? [String: Any] ?? [:]
    try check(tools.count == 1 && tools[0]["name"] as? String == "generate_image", "tools/list exposes only generate_image")
    try check(Set(properties.keys) == ["prompt", "aspect_ratio", "resolution", "seed", "prompt_enhancement", "input_images"]
              && schema?["required"] as? [String] == ["prompt"] && schema?["additionalProperties"] as? Bool == false,
              "tool schema lists every generation parameter and no image count")

    func call(_ id: Int, _ arguments: [String: Any]) async throws -> [String: Any] {
        let reply = try await rpc(id, "tools/call", ["name": "generate_image", "arguments": arguments])
        guard let result = reply["result"] as? [String: Any] else { throw AppError.message("tools/call returned no result: \(reply)") }
        return result
    }
    func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    let multiple = try await call(4, ["prompt": "Two cats", "count": 2])
    try check(multiple["isError"] as? Bool == true && text(multiple).contains("exactly one image"), "requests for several images are rejected")
    let badRatio = try await call(5, ["prompt": "Cat", "aspect_ratio": "5:1"])
    try check(badRatio["isError"] as? Bool == true && text(badRatio).contains("aspect_ratio"), "invalid aspect ratios are rejected")
    let unknown = try await rpc(6, "tools/call", ["name": "generate_video", "arguments": ["prompt": "x"]])
    try check((unknown["error"] as? [String: Any])?["code"] as? Int == -32602, "unknown tools return a JSON-RPC error")
    let missing = try await rpc(7, "resources/list")
    try check((missing["error"] as? [String: Any])?["code"] as? Int == -32601, "unknown methods return method not found")

    let draftPrompt = "User draft — keep me"
    store.prompt = draftPrompt
    let selectedBefore = store.selectedID
    store.environmentReady = false
    let notReady = try await call(8, ["prompt": "Cat"])
    try check(notReady["isError"] as? Bool == true && text(notReady).contains("PyTorch environment"), "calls before the environment is ready explain why")
    store.environmentReady = true

    let historyBefore = store.generations.count
    let result = try await call(9, ["prompt": "A lighthouse at dusk", "aspect_ratio": "16:9", "resolution": "512", "seed": 1234])
    let content = result["content"] as? [[String: Any]] ?? []
    let details = result["structuredContent"] as? [String: Any] ?? [:]
    let imageData = (content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }
    try check(result["isError"] as? Bool == false && content.first?["type"] as? String == "image"
              && content.first?["mimeType"] as? String == "image/png" && imageData.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide == 64,
              "tools/call returns the generated PNG inline: \(text(result))")
    let path = details["path"] as? String ?? ""
    try check(fm.fileExists(atPath: path) && path.hasPrefix(layout.outputs.path) && (details["seed"] as? Int) == 1234
              && details["width"] as? Int == 64 && details["height"] as? Int == 32,
              "result reports the saved path, seed and dimensions")
    let sent = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path).deletingLastPathComponent()
        .appendingPathComponent("fixture-request.json"))) as? [String: Any] ?? [:]
    try check(sent["width"] as? Int == 672 && sent["height"] as? Int == 384 && sent["outputs"] == nil && sent["promptEnhancement"] == nil,
              "the bridge receives one 512 16:9 output without enhancement")
    try check(store.generations.count == historyBefore + 1 && store.generations[0].request.outputs.count == 1
              && store.generations[0].status == .completed, "MCP generation is recorded in history as one image")
    try check(store.prompt == draftPrompt && store.selectedID == selectedBefore && !store.isRunning,
              "MCP generation keeps the composer draft and current creation")
    let log = (try? String(contentsOf: URL(fileURLWithPath: store.generations[0].directory).appendingPathComponent("run.log"), encoding: .utf8)) ?? ""
    try check(log.contains("Source: MCP"), "run log marks the MCP source in English")

    let edited = try await call(10, ["prompt": "Make it blue", "input_images": [reference.path], "aspect_ratio": "adaptive"])
    try check(edited["isError"] as? Bool == false && store.generations[0].request.inputImages.count == 1
              && store.generations[0].request.resolution == 1024 && store.generations[0].request.inputImages[0].path.hasPrefix(store.generations[0].directory),
              "image-to-image calls snapshot reference images into the task: \(text(edited))")
    let unreadable = try await call(11, ["prompt": "Edit", "input_images": [root.appendingPathComponent("missing.png").path]])
    try check(unreadable["isError"] as? Bool == true && !store.isRunning, "unreadable reference images fail without starting a task")

    // Streamable HTTP: an SSE response carries progress notifications before the result.
    let (streamStatus, streamHeaders, streamBody) = try await post(["jsonrpc": "2.0", "id": 12, "method": "tools/call",
        "params": ["name": "generate_image", "arguments": ["prompt": "Streamed"], "_meta": ["progressToken": "p1"]]],
        accept: "application/json, text/event-stream")
    let events = String(decoding: streamBody, as: UTF8.self).components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
    let progress = events.filter { $0["method"] as? String == "notifications/progress" }
    try check(streamStatus == 200 && streamHeaders["content-type"]?.hasPrefix("text/event-stream") == true && progress.count == 8
              && (progress.last?["params"] as? [String: Any])?["progressToken"] as? String == "p1"
              && ((events.last?["result"] as? [String: Any])?["isError"] as? Bool) == false,
              "SSE tool calls stream eight progress notifications then the result")

    // No authentication: only loopback hosts and local origins are accepted.
    let foreignOrigin = try await post(["jsonrpc": "2.0", "id": 13, "method": "ping"], headers: ["Origin": "https://example.com"])
    try check(foreignOrigin.0 == 403, "browser requests from other origins are rejected")
    let localOrigin = try await post(["jsonrpc": "2.0", "id": 14, "method": "ping"], headers: ["Origin": "http://localhost:3000"])
    try check(localOrigin.0 == 200, "local origins are accepted")
    try check(!MCPController.isLocal(host: "evil.test:\(port)") && MCPController.isLocal(host: "localhost:\(port)")
              && MCPController.isLocal(host: "[::1]:\(port)"), "DNS rebinding hosts are rejected")
    let wrongPath = try await post(["jsonrpc": "2.0", "id": 15, "method": "ping"], to: URL(string: "http://127.0.0.1:\(port)/other")!)
    try check(wrongPath.0 == 404, "only the /mcp endpoint is served")
    var get = URLRequest(url: url); get.httpMethod = "GET"
    let getStatus = (try await session.data(for: get).1 as! HTTPURLResponse).statusCode
    try check(getStatus == 405, "GET streams are not offered")

    mcp.setPort(port + 1)
    for _ in 0..<300 where mcp.status != .listening(port + 1) { try await Task.sleep(for: .milliseconds(10)) }
    try check(mcp.status == .listening(port + 1), "changing the port restarts the listener")
    mcp.enabled = false
    try check(mcp.status == .off, "disabling stops the server")
    var closed = false
    do { _ = try await post(["jsonrpc": "2.0", "id": 16, "method": "ping"], to: URL(string: "http://127.0.0.1:\(port + 1)/mcp")!) }
    catch { closed = true }
    try check(closed, "a disabled server no longer accepts connections")
}
