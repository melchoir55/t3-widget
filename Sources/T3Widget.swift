// T3 Widget — a floating, always-on-top panel pinned to the top-left corner of the
// screen that shows what active T3 Code threads are doing right now, plus threads
// that finished in the last 24 hours (most recently interacted with first).
//
// Data sources:
// - This Mac's threads: T3 Code's local state database (~/.t3/userdata/statev2.sqlite),
//   opened read-only.
// - Threads in linked environments (other machines): the local T3 server's MCP endpoint,
//   which relays to them. The widget signs in with a read-only MCP client session that it
//   issues (and renews) through the `t3` CLI.
// The widget hides itself while the T3 server isn't running.

import AppKit
import SQLite3
import SwiftUI

// MARK: - Configuration

enum Config {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let userData = home.appendingPathComponent(".t3/userdata")
    static let dbPath = userData.appendingPathComponent("statev2.sqlite").path
    static let runtimePath = userData.appendingPathComponent("server-runtime.json").path
    static let cliPath = home.appendingPathComponent(".t3/bin/t3").path
    static let supportDir = home.appendingPathComponent("Library/Application Support/T3Widget")
    static let sessionPath = supportDir.appendingPathComponent("mcp-session.json").path
    static let t3BundleID = "com.t3tools.t3code"
    static let pollInterval: TimeInterval = 2
    static let remotePollInterval: TimeInterval = 3
    static let recentWindow: TimeInterval = 24 * 60 * 60
    static let width: CGFloat = 340
    static let margin: CGFloat = 8
    static let activeStatuses = ["queued", "preparing", "starting", "running", "waiting"]
    static let workingStatuses = ["preparing", "starting", "running"]
    static let endedStatuses = ["completed", "interrupted", "failed", "cancelled", "rolled_back"]
    static let zoomRange: ClosedRange<CGFloat> = 1...3
    static let detailWidth: CGFloat = 460
    static let detailMaxHeight: CGFloat = 420
    static let hoverShowDelay: TimeInterval = 0.35
    static let hoverHideDelay: TimeInterval = 0.4
}

// MARK: - Model

struct ActiveThread: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let environment: String?   // nil = this Mac
    let status: String
    let startedAt: Date?
    let activity: String   // short label, e.g. "$ cargo test" or "Writing"
    let output: String     // tail of the latest output
    let detail: String     // the latest item's full text, for the hover popup
}

struct RecentThread: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let environment: String?
    let status: String
    let lastInteraction: Date?
}

struct Snapshot: Equatable {
    var online = false
    var active: [ActiveThread] = []
    var recent: [RecentThread] = []
    var error: String?
    var notes: [String] = []   // problems reaching other environments

    var working: Bool { active.contains { Config.workingStatuses.contains($0.status) } }
}

// MARK: - Dates

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

func isoString(_ d: Date) -> String { isoFractional.string(from: d) }

func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

// MARK: - T3 server

func serverRuntime() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: Config.runtimePath) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func t3ServerIsRunning() -> Bool {
    guard
        let json = serverRuntime(),
        let pid = json["pid"] as? Int32 ?? (json["pid"] as? Int).map(Int32.init)
    else { return false }
    // Signal 0 checks existence without delivering anything.
    return kill(pid, 0) == 0 || errno == EPERM
}

// MARK: - Turn items → (activity label, output tail, full text)

struct ItemSummary {
    var activity: String
    var output: String  // last few lines, shown in the row
    var detail: String  // full text, shown in the hover popup
}

func describeItem(type: String, text: String, input: String = "", output: String = "",
                  tool: String = "", title: String = "") -> ItemSummary? {
    func item(_ activity: String, _ body: String, detail: String? = nil) -> ItemSummary {
        ItemSummary(activity: activity, output: tail(body), detail: full(detail ?? body))
    }
    switch type {
    case "assistant_message":
        return item("Writing", text)
    case "reasoning":
        return item("Thinking", text)
    case "command_execution":
        if !input.isEmpty {
            return item("$ " + firstLine(input), output, detail: "$ " + input + "\n\n" + output)
        }
        // Remote items carry the command and its output in one text field: "$ cmd\n…".
        let lines = text.split(whereSeparator: \.isNewline)
        let cmd = lines.first.map(String.init) ?? ""
        return item(firstLine(cmd.hasPrefix("$ ") ? cmd : "$ " + cmd),
                    lines.dropFirst().joined(separator: "\n"), detail: text)
    case "dynamic_tool":
        let name = tool.isEmpty ? (title.isEmpty ? firstLine(text, max: 40) : title) : shortTool(tool)
        let body = output.isEmpty ? text : output
        let detail = input.isEmpty || input == "{}" ? body : "Input:\n" + input + "\n\nOutput:\n" + body
        return item("Tool: " + name, body, detail: detail)
    case "file_change":
        return item("Editing files", title.isEmpty ? text : title,
                    detail: [title, text].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    case "web_search":
        return item("Searching the web", title.isEmpty ? text : title)
    case "subagent":
        return item("Running a subagent", title.isEmpty ? text : title,
                    detail: [title, text].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    case "user_input_request":
        return item("Waiting for your answer", "", detail: text)
    default:
        return nil
    }
}

/// e.g. "Waiting on 2 background tasks, 1 subagent".
func waitingLabel(bgTasks: Int, subagents: Int) -> String {
    func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
    var parts: [String] = []
    if bgTasks > 0 { parts.append(plural(bgTasks, "background task")) }
    if subagents > 0 { parts.append(plural(subagents, "subagent")) }
    return parts.isEmpty ? "Waiting" : "Waiting on " + parts.joined(separator: ", ")
}

func firstLine(_ s: String, max: Int = 80) -> String {
    let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    return line.count > max ? String(line.prefix(max)) + "…" : line
}

func shortTool(_ name: String) -> String {
    // mcp__t3-code__t3_thread_read → t3_thread_read
    name.components(separatedBy: "__").last ?? name
}

/// The whole text for the hover popup, capped at its last `maxChars` characters.
func full(_ s: String, maxChars: Int = 20_000) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count > maxChars ? "…" + String(t.suffix(maxChars)) : t
}

func tail(_ s: String, lines: Int = 3, maxChars: Int = 280) -> String {
    let kept = s.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .suffix(lines)
        .joined(separator: "\n")
    return kept.count > maxChars ? "…" + String(kept.suffix(maxChars)) : kept
}

// MARK: - Local database (this Mac)

/// Only touched from the serial local polling queue.
final class T3Store: @unchecked Sendable {
    private var db: OpaquePointer?

    deinit { if db != nil { sqlite3_close(db) } }

    private func open() throws {
        if db != nil { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(Config.dbPath, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw NSError(domain: "T3Widget", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
    }

    private func query(_ sql: String, _ binds: [String] = [], row: (OpaquePointer) -> Void) throws {
        try open()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db); db = nil  // reopen next time (schema may have changed)
            throw NSError(domain: "T3Widget", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient)
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    func snapshot() -> Snapshot {
        var snap = Snapshot(online: t3ServerIsRunning())
        guard snap.online else { return snap }

        let statuses = Config.activeStatuses.map { "'\($0)'" }.joined(separator: ",")
        let cutoff = isoString(Date().addingTimeInterval(-Config.recentWindow))

        // One row per top-level thread whose latest run is active or ended in the window, or
        // that is still busy after its run ended: background commands/monitors, subagents that
        // are running or have results not yet delivered, or a question/approval awaiting the user.
        // T3's sidebar labels those "Waiting" / "Awaiting Input", not ended.
        let threadsSQL = """
            SELECT thread_id, title, project, status, requested_at, completed_at, last_user,
                   bg_tasks, live_subagents, pending_request
            FROM (
              SELECT t.thread_id, t.title, COALESCE(p.title, '') AS project, r.status,
                     r.requested_at, r.completed_at,
                     (SELECT MAX(m.updated_at) FROM orchestration_v2_projection_messages m
                       WHERE m.thread_id = t.thread_id AND m.role = 'user') AS last_user,
                     (SELECT COALESCE(SUM(json_array_length(pt.payload_json, '$.pendingBackgroundTasks')), 0)
                        FROM orchestration_v2_projection_provider_threads pt
                       WHERE pt.thread_id = t.thread_id) AS bg_tasks,
                     (SELECT COUNT(*) FROM orchestration_v2_projection_subagents s
                       WHERE s.thread_id = t.thread_id
                         AND (s.status IN (\(statuses))
                              OR s.completion_delivery_state IN ('pending', 'claimed'))) AS live_subagents,
                     (SELECT q.kind FROM orchestration_v2_projection_runtime_requests q
                       WHERE q.thread_id = t.thread_id AND q.status = 'pending'
                       ORDER BY q.created_at DESC LIMIT 1) AS pending_request
              FROM orchestration_v2_projection_threads t
              JOIN orchestration_v2_projection_runs r
                ON r.thread_id = t.thread_id
               AND r.ordinal = (SELECT MAX(ordinal) FROM orchestration_v2_projection_runs
                                 WHERE thread_id = t.thread_id)
              LEFT JOIN projection_projects p ON p.project_id = t.project_id
              WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
                AND COALESCE(json_extract(t.payload_json, '$.lineage.relationshipToParent'), '')
                    <> 'subagent'
            )
            WHERE status IN (\(statuses)) OR completed_at >= ?1
               OR bg_tasks > 0 OR live_subagents > 0 OR pending_request IS NOT NULL
            """

        struct Row {
            let id, title, project, status: String
            let requested, completed, lastUser: String?
            let bgTasks, liveSubagents: Int
            let pendingRequest: String?
        }
        var rows: [Row] = []
        do {
            try query(threadsSQL, [cutoff]) { s in
                rows.append(Row(
                    id: text(s, 0) ?? "", title: text(s, 1) ?? "Untitled",
                    project: text(s, 2) ?? "", status: text(s, 3) ?? "",
                    requested: text(s, 4), completed: text(s, 5), lastUser: text(s, 6),
                    bgTasks: Int(sqlite3_column_int(s, 7)),
                    liveSubagents: Int(sqlite3_column_int(s, 8)),
                    pendingRequest: text(s, 9)))
            }
        } catch {
            snap.error = error.localizedDescription
            return snap
        }

        for row in rows {
            let runActive = Config.activeStatuses.contains(row.status)
            let busy = row.bgTasks > 0 || row.liveSubagents > 0
            if runActive || busy || row.pendingRequest != nil {
                let latest = latestOutput(threadID: row.id)
                var activity = latest.activity
                var status = row.status
                if let kind = row.pendingRequest {
                    status = "needs_user"
                    activity = kind == "user_input" ? "Waiting for your answer" : "Needs your approval"
                } else if !runActive || row.status == "waiting" {
                    status = "waiting"
                    activity = waitingLabel(bgTasks: row.bgTasks, subagents: row.liveSubagents)
                }
                snap.active.append(ActiveThread(
                    id: row.id, title: row.title, project: row.project, environment: nil,
                    status: status, startedAt: parseDate(row.requested),
                    activity: activity, output: latest.output, detail: latest.detail))
            } else {
                let last = [parseDate(row.completed), parseDate(row.lastUser)].compactMap { $0 }.max()
                snap.recent.append(RecentThread(
                    id: row.id, title: row.title, project: row.project, environment: nil,
                    status: row.status, lastInteraction: last))
            }
        }
        return snap
    }

    /// The most recent meaningful turn item for a thread.
    private func latestOutput(threadID: String) -> ItemSummary {
        let sql = """
            SELECT type,
                   json_extract(payload_json, '$.text'),
                   json_extract(payload_json, '$.input'),
                   json_extract(payload_json, '$.output'),
                   json_extract(payload_json, '$.toolName'),
                   json_extract(payload_json, '$.title')
            FROM orchestration_v2_projection_turn_items
            WHERE thread_id = ?1
              AND type IN ('assistant_message', 'command_execution', 'dynamic_tool', 'reasoning',
                           'file_change', 'web_search', 'subagent', 'user_input_request')
            ORDER BY ordinal DESC LIMIT 1
            """
        var result = ItemSummary(activity: "Starting…", output: "", detail: "")
        try? query(sql, [threadID]) { s in
            if let d = describeItem(type: text(s, 0) ?? "", text: text(s, 1) ?? "",
                                    input: text(s, 2) ?? "", output: text(s, 3) ?? "",
                                    tool: text(s, 4) ?? "", title: text(s, 5) ?? "") {
                result = d
            }
        }
        return result
    }
}

// MARK: - Linked environments (other machines), via the local server's MCP endpoint

struct WidgetError: LocalizedError {
    let message: String
    var unauthorized = false
    var errorDescription: String? { message }
}

/// The widget's own read-only MCP client session, issued with the `t3` CLI and kept in
/// ~/Library/Application Support/T3Widget/mcp-session.json (mode 0600).
final class SessionStore {
    struct Saved: Codable { let sessionId: String; let token: String; let expiresAt: String }
    private var current: Saved?
    private var lastIssue: Date?

    func token() throws -> String {
        if current == nil, let data = FileManager.default.contents(atPath: Config.sessionPath) {
            current = try? JSONDecoder().decode(Saved.self, from: data)
        }
        if let c = current, let exp = parseDate(c.expiresAt), exp.timeIntervalSinceNow > 2 * 86400 {
            return c.token
        }
        return try reissue()
    }

    /// Issues a fresh session (at most every 5 minutes) and revokes the previous one.
    @discardableResult
    func reissue() throws -> String {
        if let last = lastIssue, Date().timeIntervalSince(last) < 300 {
            throw WidgetError(message: "Couldn't sign in to the T3 server; retrying shortly.")
        }
        lastIssue = Date()
        let out = try runCLI(["auth", "session", "issue", "--subject", "mcp-client",
                              "--scope", "orchestration:read", "--ttl", "30d",
                              "--label", "T3 Widget", "--json"])
        guard let saved = try? JSONDecoder().decode(Saved.self, from: out) else {
            throw WidgetError(message: "The t3 CLI didn't return a session.")
        }
        try? FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Config.sessionPath, contents: try JSONEncoder().encode(saved),
                                       attributes: [.posixPermissions: 0o600])
        if let old = current?.sessionId, old != saved.sessionId {
            _ = try? runCLI(["auth", "session", "revoke", old])
        }
        current = saved
        return saved.token
    }

    private func runCLI(_ args: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: Config.cliPath) else {
            throw WidgetError(message: "t3 CLI not found at \(Config.cliPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.cliPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw WidgetError(message: "t3 \(args.prefix(3).joined(separator: " ")) failed")
        }
        return data
    }
}

/// A minimal synchronous MCP (streamable HTTP) client. Only used from the remote queue.
final class McpClient {
    private let sessions = SessionStore()
    private var mcpSession: String?
    private var nextID = 1

    func call(_ tool: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        do {
            return try callOnce(tool, args)
        } catch let e as WidgetError where e.unauthorized {
            try sessions.reissue()
            mcpSession = nil
            return try callOnce(tool, args)
        }
    }

    private func callOnce(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        if mcpSession == nil { try initialize() }
        var (status, json) = try post(method: "tools/call", params: ["name": tool, "arguments": args])
        if status == 404 {  // MCP session expired on the server
            try initialize()
            (status, json) = try post(method: "tools/call", params: ["name": tool, "arguments": args])
        }
        if let err = json["error"] as? [String: Any] {
            throw WidgetError(message: err["message"] as? String ?? "MCP error")
        }
        guard let result = json["result"] as? [String: Any] else {
            throw WidgetError(message: "Unexpected MCP response (HTTP \(status))")
        }
        if result["isError"] as? Bool == true {
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "tool failed"
            throw WidgetError(message: "\(tool): \(firstLine(text, max: 120))")
        }
        return result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func initialize() throws {
        mcpSession = nil
        let (_, json) = try post(method: "initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "t3-widget", "version": "1.1"],
        ])
        guard json["result"] != nil else { throw WidgetError(message: "MCP initialize failed") }
        _ = try? post(method: "notifications/initialized", params: nil, notification: true)
    }

    private func post(method: String, params: [String: Any]?, notification: Bool = false) throws
        -> (Int, [String: Any])
    {
        guard let origin = serverRuntime()?["origin"] as? String, let url = URL(string: origin + "/mcp")
        else { throw WidgetError(message: "T3 server address unknown") }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        if !notification { body["id"] = nextID; nextID += 1 }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(try sessions.token())", forHTTPHeaderField: "Authorization")
        if let mcpSession { req.setValue(mcpSession, forHTTPHeaderField: "Mcp-Session-Id") }

        let (data, response) = try send(req)
        if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id") { mcpSession = id }
        let status = response.statusCode
        if status == 401 { throw WidgetError(message: "Not signed in to the T3 server", unauthorized: true) }
        if notification || data.isEmpty { return (status, [:]) }

        var payload = data
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            // Take the last `data:` line of the event stream.
            let text = String(decoding: data, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("data:") }
            payload = Data((line?.dropFirst(5) ?? "").utf8)
        }
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private func send(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(WidgetError(message: "no response"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse { result = .success((data ?? Data(), http)) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

/// Threads in every linked environment. Only touched from the serial remote polling queue.
final class RemoteStore: @unchecked Sendable {
    private let mcp = McpClient()
    private var projectTitles: [String: (fetched: Date, titles: [String: String])] = [:]
    /// Background work per ended thread, keyed by env/thread and reused until updatedAt changes.
    private var backgroundCache: [String: (updatedAt: String, tasks: Int, subagents: Int)] = [:]

    func snapshot() -> Snapshot {
        var snap = Snapshot()
        guard t3ServerIsRunning() else { return snap }
        snap.online = true
        let links: [[String: Any]]
        do {
            links = try mcp.call("t3_environment_links")["links"] as? [[String: Any]] ?? []
        } catch {
            snap.notes.append("Other machines: \(error.localizedDescription)")
            return snap
        }
        for link in links {
            guard let envID = link["environmentId"] as? String else { continue }
            let label = link["label"] as? String ?? envID
            let status = link["status"] as? String ?? "unknown"
            guard status == "reachable" else {
                snap.notes.append("\(label): \(status)")
                continue
            }
            do { try fetch(envID: envID, label: label, into: &snap) }
            catch { snap.notes.append("\(label): \(error.localizedDescription)") }
        }
        return snap
    }

    private func threads(_ envID: String, statuses: [String], limit: Int) throws -> [[String: Any]] {
        let result = try mcp.call("t3_thread_list", [
            "environmentId": envID, "allProjects": true, "includeSubagents": false,
            "statuses": statuses, "limit": limit,
        ])
        return (result["threads"] as? [[String: Any]] ?? []).filter {
            ($0["relationshipToParent"] as? String) != "subagent"
        }
    }

    private func fetch(envID: String, label: String, into snap: inout Snapshot) throws {
        let titles = try projects(envID)
        let cutoff = Date().addingTimeInterval(-Config.recentWindow)

        for t in try threads(envID, statuses: Config.activeStatuses, limit: 100) {
            guard let id = t["threadId"] as? String else { continue }
            let latest = (try? latestActivity(envID: envID, threadID: id,
                                              itemCount: t["itemCount"] as? Int ?? 0))
            snap.active.append(ActiveThread(
                id: envID + "/" + id, title: t["title"] as? String ?? "Untitled",
                project: titles[t["projectId"] as? String ?? ""] ?? "", environment: label,
                status: t["status"] as? String ?? "", startedAt: latest?.started,
                activity: latest?.summary.activity ?? "Starting…", output: latest?.summary.output ?? "",
                detail: latest?.summary.detail ?? ""))
        }
        for t in try threads(envID, statuses: Config.endedStatuses, limit: 50) {
            guard let id = t["threadId"] as? String,
                  let updated = parseDate(t["updatedAt"] as? String), updated >= cutoff else { continue }
            // A finished turn can leave subagents or background commands running: in progress.
            if let work = try? backgroundWork(envID: envID, threadID: id,
                                              updatedAt: t["updatedAt"] as? String ?? ""),
               work.tasks + work.subagents > 0 {
                let latest = try? latestActivity(envID: envID, threadID: id,
                                                 itemCount: t["itemCount"] as? Int ?? 0)
                snap.active.append(ActiveThread(
                    id: envID + "/" + id, title: t["title"] as? String ?? "Untitled",
                    project: titles[t["projectId"] as? String ?? ""] ?? "", environment: label,
                    status: "waiting", startedAt: latest?.started,
                    activity: waitingLabel(bgTasks: work.tasks, subagents: work.subagents),
                    output: latest?.summary.output ?? "", detail: latest?.summary.detail ?? ""))
                continue
            }
            snap.recent.append(RecentThread(
                id: envID + "/" + id, title: t["title"] as? String ?? "Untitled",
                project: titles[t["projectId"] as? String ?? ""] ?? "", environment: label,
                status: t["status"] as? String ?? "", lastInteraction: updated))
        }
    }

    /// Counts the thread's subagents and background commands still running. The MCP API has
    /// no summary of this, so it pages through the timeline, only when updatedAt changes.
    private func backgroundWork(envID: String, threadID: String, updatedAt: String) throws
        -> (tasks: Int, subagents: Int)
    {
        let key = envID + "/" + threadID
        if let c = backgroundCache[key], c.updatedAt == updatedAt { return (c.tasks, c.subagents) }
        var tasks = 0, subagents = 0
        var after: Int?
        for _ in 0..<20 {
            var args: [String: Any] = [
                "environmentId": envID, "threadId": threadID, "view": "activity",
                "limit": 100, "runLimit": 1, "maxCharsPerItem": 1,
            ]
            if let after { args["afterPosition"] = after }
            let page = try mcp.call("t3_thread_read", args)
            for item in page["items"] as? [[String: Any]] ?? [] {
                let status = item["status"] as? String ?? ""
                guard status == "running" || status == "waiting" else { continue }
                switch item["type"] as? String ?? "" {
                case "subagent": subagents += 1
                case "command_execution", "dynamic_tool": tasks += 1
                default: break
                }
            }
            guard page["hasMore"] as? Bool == true, let next = page["nextPosition"] as? Int else { break }
            after = next
        }
        backgroundCache[key] = (updatedAt, tasks, subagents)
        return (tasks, subagents)
    }

    /// Project id → title for an environment, refreshed every 5 minutes.
    private func projects(_ envID: String) throws -> [String: String] {
        if let cached = projectTitles[envID], Date().timeIntervalSince(cached.fetched) < 300 {
            return cached.titles
        }
        var titles: [String: String] = [:]
        var cursor: Int? = 0
        while let c = cursor, c < 1000 {
            let page = try mcp.call("t3_project_list", ["environmentId": envID, "cursor": c, "limit": 100])
            for p in page["projects"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String { titles[id] = p["title"] as? String ?? "" }
            }
            cursor = page["nextCursor"] as? Int
        }
        projectTitles[envID] = (Date(), titles)
        return titles
    }

    private func latestActivity(envID: String, threadID: String, itemCount: Int) throws
        -> (summary: ItemSummary, started: Date?)
    {
        var args: [String: Any] = [
            "environmentId": envID, "threadId": threadID, "view": "activity",
            "limit": 4, "runLimit": 1, "maxCharsPerItem": 6000,
        ]
        if itemCount > 5 { args["afterPosition"] = itemCount - 5 }
        let result = try mcp.call("t3_thread_read", args)
        let started = parseDate((result["recentRuns"] as? [[String: Any]])?.first?["requestedAt"] as? String)
        for item in (result["items"] as? [[String: Any]] ?? []).reversed() {
            if let d = describeItem(type: item["type"] as? String ?? "", text: item["text"] as? String ?? "",
                                    title: item["title"] as? String ?? "") {
                return (d, started)
            }
        }
        return (ItemSummary(activity: "Starting…", output: "", detail: ""), started)
    }
}

// MARK: - Preferences

enum MascotKind: String, CaseIterable {
    case robot, cat
    var title: String { self == .robot ? "Typing Robot" : "Keyboard Cat" }
}

enum Prefs {
    private static let d = UserDefaults.standard
    static var stayOnTop: Bool {
        get { d.object(forKey: "stayOnTop") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayOnTop") }
    }
    static var zoom: CGFloat {
        get { CGFloat(d.object(forKey: "zoom") as? Double ?? 1) }
        set { d.set(Double(newValue), forKey: "zoom") }
    }
    static var mascot: MascotKind {
        get { MascotKind(rawValue: d.string(forKey: "mascot") ?? "") ?? .robot }
        set { d.set(newValue.rawValue, forKey: "mascot") }
    }
    /// Saved top-left corner of the widget (screen coordinates), nil = default corner.
    static var topLeft: NSPoint? {
        get {
            guard let a = d.array(forKey: "topLeft") as? [Double], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "topLeft") }
    }
}

// MARK: - View model

@MainActor
final class WidgetModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var now = Date()
    @Published var collapsed = false
    @Published var zoom: CGFloat = Prefs.zoom.clamped(to: Config.zoomRange)
    @Published var mascot: MascotKind = Prefs.mascot
    /// The active thread whose full text the hover popup shows, if any.
    @Published var detailID: String?
    var onChange: (() -> Void)?
    /// Each active row's frame, measured from the widget's top-left corner, for hover hit-testing.
    var rowFrames: [String: CGRect] = [:]

    private let store = T3Store()
    private let remote = RemoteStore()
    private let queue = DispatchQueue(label: "t3widget.poll", qos: .utility)
    private let remoteQueue = DispatchQueue(label: "t3widget.remote", qos: .utility)
    private var local = Snapshot()
    private var linked = Snapshot()
    private var timer: Timer?
    private let debug = ProcessInfo.processInfo.environment["T3WIDGET_DEBUG"] != nil

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        pollRemote()
    }

    func refresh() {
        let store = self.store
        queue.async {
            let snap = store.snapshot()
            DispatchQueue.main.async {
                self.local = snap
                self.publish()
            }
        }
    }

    /// Linked environments go through relays, so they're polled on their own queue and
    /// cadence; a slow machine never holds up this Mac's threads.
    private func pollRemote() {
        let remote = self.remote
        remoteQueue.async {
            let snap = remote.snapshot()
            DispatchQueue.main.async {
                self.linked = snap
                self.publish()
                DispatchQueue.main.asyncAfter(deadline: .now() + Config.remotePollInterval) { self.pollRemote() }
            }
        }
    }

    private func publish() {
        var snap = local
        if snap.online && linked.online {
            snap.active += linked.active
            snap.recent += linked.recent
            snap.notes = linked.notes
        }
        snap.active.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        snap.recent.sort { ($0.lastInteraction ?? .distantPast) > ($1.lastInteraction ?? .distantPast) }
        if debug { FileHandle.standardError.write(Data("\(snap)\n".utf8)) }
        now = Date()
        if snap != snapshot {
            snapshot = snap
            onChange?()
        }
    }

    func setZoom(_ value: CGFloat) {
        let z = ((value * 20).rounded() / 20).clamped(to: Config.zoomRange)
        guard z != zoom else { return }
        zoom = z
        Prefs.zoom = z
        // Resize the panel after SwiftUI has laid out at the new size.
        DispatchQueue.main.async { self.onChange?() }
    }

    func setMascot(_ kind: MascotKind) {
        mascot = kind
        Prefs.mascot = kind
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Zoom environment

private struct ZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var zoom: CGFloat {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

// MARK: - Activity graphic

/// A little drawing that animates while any thread is working, and sits still otherwise.
struct Mascot: View {
    let kind: MascotKind
    let working: Bool
    @Environment(\.zoom) private var z

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !working)) { timeline in
            let t = working ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                ctx.scaleBy(x: size.width / 48, y: size.height / 36)
                switch kind {
                case .robot: drawRobot(&ctx, t: t, on: working)
                case .cat: drawCat(&ctx, t: t, on: working)
                }
            }
        }
        .frame(width: 40 * z, height: 30 * z)
        .help(working ? "Agents are working — click to switch graphic" : "Nothing running — click to switch graphic")
    }
}

private func rr(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
}
private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path(); p.move(to: a); p.addLine(to: b); return p
}
private func round(_ w: Double) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

/// A robot at a desk, typing; the screen fills with code while it works.
func drawRobot(_ c: inout GraphicsContext, t: Double, on: Bool) {
    let steel = Color(red: 0.74, green: 0.79, blue: 0.87)
    let edge = Color(red: 0.32, green: 0.36, blue: 0.44)

    // Desk and monitor.
    c.fill(rr(0, 32, 48, 2, 1), with: .color(edge.opacity(0.7)))
    c.fill(rr(35.5, 21, 3, 9, 0), with: .color(Color(white: 0.32)))
    c.fill(rr(32, 29.5, 10, 2.5, 1), with: .color(Color(white: 0.32)))
    c.fill(rr(27, 6.5, 20, 15, 2), with: .color(Color(white: 0.24)))
    c.fill(rr(28.5, 8, 17, 12, 1),
           with: .color(on ? Color(red: 0.05, green: 0.15, blue: 0.28) : Color(white: 0.13)))

    // Code on screen: lines scroll up while the last one is being typed.
    let step = Int(t * 9), lineNo = step / 10, typed = step % 10
    let idle: [Double] = [9, 6, 11, 5]
    for i in 0..<4 {
        let idx = lineNo + i
        var w = on ? 4 + Double((idx * 37) % 10) : idle[i]
        if on && i == 3 { w *= Double(typed) / 10 }
        let x = 30 + Double((idx * 7) % 3) * 1.5   // indentation
        let color: Color = on ? (idx % 3 == 0 ? Color.cyan : Color.green).opacity(0.9) : Color(white: 0.36)
        c.fill(rr(x, 9.8 + Double(i) * 2.5, min(w, 44 - x), 1.2, 0.6), with: .color(color))
        if on && i == 3 && Int(t * 3) % 2 == 0 {  // cursor
            c.fill(rr(x + w + 0.5, 9.8 + 7.5, 1, 1.4, 0), with: .color(.white.opacity(0.9)))
        }
    }

    // Antenna, head, face.
    c.stroke(line(CGPoint(x: 13, y: 6.5), CGPoint(x: 13, y: 3)), with: .color(edge), style: round(1))
    let blink = on && Int(t * 3) % 2 == 0
    c.fill(circle(13, 2.3, 1.5), with: .color(blink ? Color(red: 1, green: 0.3, blue: 0.25) : Color(white: 0.6)))
    c.fill(rr(5.5, 6, 15, 11, 3), with: .color(steel))
    c.stroke(rr(5.5, 6, 15, 11, 3), with: .color(edge), lineWidth: 0.8)
    c.fill(rr(7.5, 8.5, 11, 6, 2), with: .color(Color(red: 0.1, green: 0.13, blue: 0.19)))
    if on {
        c.fill(circle(12.3, 11.5, 1.3), with: .color(.cyan))
        c.fill(circle(16.3, 11.5, 1.3), with: .color(.cyan))
    } else {
        for x in [10.0, 14.5] {
            c.stroke(line(CGPoint(x: x, y: 12), CGPoint(x: x + 2.2, y: 12)), with: .color(Color(white: 0.6)), style: round(0.9))
        }
    }

    // Body, keyboard, arms.
    c.fill(rr(7, 18.5, 12, 12.5, 3), with: .color(steel))
    c.stroke(rr(7, 18.5, 12, 12.5, 3), with: .color(edge), lineWidth: 0.8)
    c.fill(circle(11, 23, 1), with: .color(on ? .green : Color(white: 0.55)))
    c.fill(rr(15, 29, 13, 3, 1), with: .color(Color(white: 0.34)))
    for k in 0..<5 { c.fill(rr(16.2 + Double(k) * 2.4, 29.8, 1.6, 0.9, 0.3), with: .color(Color(white: 0.6))) }
    let lifts = on ? [max(0, sin(t * 16)) * 2.4, max(0, sin(t * 16 + .pi)) * 2.4] : [0, 0]
    for (i, (shoulder, hand)) in [(CGPoint(x: 15.5, y: 21), CGPoint(x: 20.5, y: 28.6)),
                                   (CGPoint(x: 17.5, y: 22), CGPoint(x: 25, y: 28.6))].enumerated() {
        let h = CGPoint(x: hand.x, y: hand.y - lifts[i])
        c.stroke(line(shoulder, h), with: .color(edge), style: round(2))
        c.fill(circle(h.x, h.y, 1.3), with: .color(steel))
        c.stroke(circle(h.x, h.y, 1.3), with: .color(edge), lineWidth: 0.6)
    }
}

/// A cat behind a keyboard; while work is going on it bangs the keys with stiff, straight arms.
func drawCat(_ c: inout GraphicsContext, t: Double, on: Bool) {
    let fur = Color(red: 0.93, green: 0.62, blue: 0.32)
    let stripe = Color(red: 0.7, green: 0.4, blue: 0.17)
    let cream = Color(red: 0.99, green: 0.9, blue: 0.78)
    let pink = Color(red: 0.95, green: 0.58, blue: 0.64)
    let ink = Color(white: 0.12)

    c.fill(rr(0, 32, 48, 2, 1), with: .color(Color(white: 0.4).opacity(0.7)))

    // Tail and body.
    let wag = on ? sin(t * 7) * 2.5 : 0
    var tailPath = Path()
    tailPath.move(to: CGPoint(x: 31, y: 25))
    tailPath.addQuadCurve(to: CGPoint(x: 41 + wag * 0.4, y: 13 + wag), control: CGPoint(x: 43, y: 26))
    c.stroke(tailPath, with: .color(fur), style: round(2.6))
    c.fill(Path(ellipseIn: CGRect(x: 15, y: 13, width: 18, height: 19)), with: .color(fur))
    c.fill(Path(ellipseIn: CGRect(x: 19.5, y: 17, width: 9, height: 12)), with: .color(cream))

    // Head (bobs while banging).
    let bob = on ? abs(sin(t * 20)) * 0.6 : 0
    c.translateBy(x: 0, y: bob)
    for ear in [[CGPoint(x: 17.5, y: 7.5), CGPoint(x: 18.3, y: 0.8), CGPoint(x: 22.5, y: 4.5)],
                [CGPoint(x: 25.5, y: 4.5), CGPoint(x: 29.7, y: 0.8), CGPoint(x: 30.5, y: 7.5)]] {
        var p = Path(); p.addLines(ear); p.closeSubpath()
        c.fill(p, with: .color(fur))
        var inner = Path()
        let m = CGPoint(x: (ear[0].x + ear[2].x) / 2, y: (ear[0].y + ear[2].y) / 2)
        inner.addLines([CGPoint(x: (ear[0].x + m.x) / 2, y: (ear[0].y + m.y) / 2 - 0.5),
                        CGPoint(x: ear[1].x * 0.7 + m.x * 0.3, y: ear[1].y * 0.7 + m.y * 0.3 + 0.8),
                        CGPoint(x: (ear[2].x + m.x) / 2, y: (ear[2].y + m.y) / 2 - 0.5)])
        inner.closeSubpath()
        c.fill(inner, with: .color(pink))
    }
    c.fill(Path(ellipseIn: CGRect(x: 16.5, y: 3.5, width: 15, height: 13)), with: .color(fur))
    for dx in [-2.0, 0, 2] {
        c.stroke(line(CGPoint(x: 24 + dx, y: 4.2), CGPoint(x: 24 + dx * 0.8, y: 6.3)), with: .color(stripe), style: round(0.8))
    }
    if on {  // wide, frantic eyes
        let jitter = sin(t * 31) * 0.35
        for x in [20.8, 27.2] {
            c.fill(circle(x, 9.6, 2.1), with: .color(.white))
            c.fill(circle(x + jitter, 9.8, 0.9), with: .color(ink))
        }
        c.fill(Path(ellipseIn: CGRect(x: 23.1, y: 13.1, width: 1.8, height: 1.6)), with: .color(ink))
    } else {  // content, eyes closed
        for x in [20.8, 27.2] {
            var arc = Path()
            arc.addArc(center: CGPoint(x: x, y: 9.2), radius: 1.6, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            c.stroke(arc, with: .color(ink), style: round(0.8))
        }
    }
    var nose = Path()
    nose.addLines([CGPoint(x: 23.2, y: 11.8), CGPoint(x: 24.8, y: 11.8), CGPoint(x: 24, y: 12.8)])
    nose.closeSubpath()
    c.fill(nose, with: .color(pink))
    for (a, b) in [((19.5, 12.0), (15.5, 11.2)), ((19.5, 13.0), (15.5, 13.6)),
                   ((28.5, 12.0), (32.5, 11.2)), ((28.5, 13.0), (32.5, 13.6))] {
        c.stroke(line(CGPoint(x: a.0, y: a.1), CGPoint(x: b.0, y: b.1)), with: .color(ink.opacity(0.6)), style: round(0.4))
    }
    c.translateBy(x: 0, y: -bob)

    // Keyboard, then the straight arms on top of it.
    c.fill(rr(6, 27, 36, 5, 1.5), with: .color(Color(white: 0.27)))
    let lifts = on ? [max(0, sin(t * 20)) * 5, max(0, sin(t * 20 + .pi)) * 5] : [0, 0]
    let paws = [CGPoint(x: 11.5, y: 28.6 - lifts[0]), CGPoint(x: 36.5, y: 28.6 - lifts[1])]
    for r in 0..<2 {
        for k in 0..<9 {
            let x = 7.5 + Double(k) * 3.7, y = 28 + Double(r) * 1.9
            let hit = on && paws.enumerated().contains { i, p in lifts[i] < 0.5 && abs(p.x - (x + 1.4)) < 3 }
            c.fill(rr(x, y, 2.8, 1.3, 0.3), with: .color(hit ? .yellow : Color(white: 0.5)))
        }
    }
    for (i, shoulder) in [CGPoint(x: 18.5, y: 17.5), CGPoint(x: 29.5, y: 17.5)].enumerated() {
        let paw = paws[i]
        c.stroke(line(shoulder, paw), with: .color(stripe), style: round(4.4))  // outline
        c.stroke(line(shoulder, paw), with: .color(fur), style: round(3.2))
        c.fill(Path(ellipseIn: CGRect(x: paw.x - 2.2, y: paw.y - 1.4, width: 4.4, height: 2.8)), with: .color(cream))
        if on && lifts[i] < 0.6 {  // impact marks
            let s: Double = i == 0 ? -1 : 1
            for (dx, dy) in [(2.8, -1.0), (2.2, -2.8), (0.6, -3.6)] {
                c.stroke(line(CGPoint(x: paw.x + s * dx, y: paw.y + dy),
                              CGPoint(x: paw.x + s * (dx + 1.2), y: paw.y + dy - 1.0)),
                         with: .color(.yellow), style: round(0.6))
            }
        }
    }
}

// MARK: - Views

struct StatusDot: View {
    let status: String
    @Environment(\.zoom) private var z
    var color: Color {
        switch status {
        case "running", "starting", "preparing": return .green
        case "waiting", "queued": return .yellow
        case "needs_user": return .purple
        case "completed": return .secondary
        case "failed": return .red
        default: return .orange  // interrupted, cancelled, rolled_back
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 7 * z, height: 7 * z)
    }
}

func place(_ project: String, _ environment: String?) -> String {
    [project.isEmpty ? nil : project, environment.map { "@ " + $0 }].compactMap { $0 }.joined(separator: " ")
}

struct WidgetView: View {
    @ObservedObject var model: WidgetModel

    var body: some View {
        let z = model.zoom
        VStack(alignment: .leading, spacing: 8 * z) {
            header
            if !model.collapsed {
                if let error = model.snapshot.error {
                    Text(error).font(.system(size: 10 * z)).foregroundStyle(.red)
                }
                ForEach(model.snapshot.notes, id: \.self) { note in
                    Text(note).font(.system(size: 9 * z)).foregroundStyle(.orange).lineLimit(2)
                }
                if model.snapshot.active.isEmpty && model.snapshot.recent.isEmpty {
                    Text("No active or recent threads").font(.system(size: 10 * z)).foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.active) { thread in
                    ActiveRow(thread: thread, now: model.now, highlighted: model.detailID == thread.id) {
                        model.rowFrames[thread.id] = $0
                    }
                }
                if !model.snapshot.recent.isEmpty {
                    Divider().opacity(0.4)
                    Text("ENDED · LAST 24H").font(.system(size: 9 * z, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.snapshot.recent) { RecentRow(thread: $0, now: model.now) }
                }
            }
        }
        .environment(\.zoom, z)
        .padding(10 * z)
        .frame(width: Config.width * z, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12 * z))
        .overlay(RoundedRectangle(cornerRadius: 12 * z).strokeBorder(.white.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    var header: some View {
        let z = model.zoom
        return HStack(spacing: 6 * z) {
            Mascot(kind: model.mascot, working: model.snapshot.working)
                .contentShape(Rectangle())
                .onTapGesture {
                    let all = MascotKind.allCases
                    model.setMascot(all[(all.firstIndex(of: model.mascot)! + 1) % all.count])
                }
            Text("T3").font(.system(size: 11 * z, weight: .bold, design: .rounded))
            Text("\(model.snapshot.active.count) active")
                .font(.system(size: 11 * z)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: model.collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 9 * z, weight: .semibold)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.collapsed.toggle()
            model.onChange?()
        }
    }
}

struct ActiveRow: View {
    let thread: ActiveThread
    let now: Date
    var highlighted = false
    var onFrame: (CGRect) -> Void = { _ in }
    @Environment(\.zoom) private var z
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * z) {
            HStack(spacing: 6 * z) {
                StatusDot(status: thread.status)
                Text(thread.title).font(.system(size: 12 * z, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4 * z)
                Text(relative(thread.startedAt, now: now))
                    .font(.system(size: 10 * z).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(thread.activity + " · " + place(thread.project, thread.environment))
                .font(.system(size: 10 * z, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            if !thread.output.isEmpty {
                Text(thread.output)
                    .font(.system(size: 10 * z, design: .monospaced))
                    .lineLimit(3)
                    .padding(6 * z)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(highlighted ? 0.3 : 0.18), in: RoundedRectangle(cornerRadius: 6 * z))
            }
        }
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onFrame(g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { onFrame($0) }
        })
        .onTapGesture(perform: openT3)
    }
}

/// The hover popup: the full text of an active thread's latest turn item.
struct DetailView: View {
    @ObservedObject var model: WidgetModel

    var body: some View {
        let z = model.zoom
        let thread = model.snapshot.active.first { $0.id == model.detailID }
        VStack(alignment: .leading, spacing: 6 * z) {
            if let thread {
                Text(thread.title).font(.system(size: 12 * z, weight: .semibold)).lineLimit(2)
                Text(thread.activity + " · " + place(thread.project, thread.environment))
                    .font(.system(size: 10 * z, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(thread.detail)
                            .font(.system(size: 10 * z, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8 * z)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: Config.detailMaxHeight * z)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6 * z))
                    // Start at the newest output, like a terminal.
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: thread.id) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .padding(10 * z)
        .frame(width: Config.detailWidth * z, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12 * z))
        .overlay(RoundedRectangle(cornerRadius: 12 * z).strokeBorder(.white.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RecentRow: View {
    let thread: RecentThread
    let now: Date
    @Environment(\.zoom) private var z
    var body: some View {
        HStack(spacing: 6 * z) {
            StatusDot(status: thread.status)
            Text(thread.title).font(.system(size: 11 * z)).lineLimit(1)
            Text(place(thread.project, thread.environment))
                .font(.system(size: 10 * z)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 4 * z)
            Text(relative(thread.lastInteraction, now: now) + " ago")
                .font(.system(size: 10 * z).monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openT3)
    }
}

func openT3() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.t3BundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
}

// MARK: - Window

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var mouseDown: NSEvent?
    /// Pinch, or ⌘-scroll, to zoom. Receives a multiplier.
    var onZoom: ((CGFloat) -> Void)?

    /// Click-and-drag anywhere moves the widget; a plain click still reaches the views.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown = event
            if level == .normal { orderFrontRegardless() }  // raise when not pinned on top
        case .leftMouseDragged:
            if let down = mouseDown {
                mouseDown = nil
                // The window server moves the window; the delegate saves where it lands.
                performDrag(with: down)
                return
            }
        case .leftMouseUp:
            mouseDown = nil
        case .magnify:
            onZoom?(1 + event.magnification)
            return
        case .scrollWheel where event.modifierFlags.contains(.command):
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.05
            onZoom?(1 + delta)
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = WidgetModel()
    var panel: WidgetPanel!
    var hosting: NSHostingView<WidgetView>!
    var detailPanel: NSPanel!
    var detailHosting: NSHostingView<DetailView>!
    let stayOnTopItem = NSMenuItem(title: "Stay on Top", action: #selector(toggleStayOnTop), keyEquivalent: "")
    let zoomMenu = NSMenu(title: "Zoom")
    let mascotMenu = NSMenu(title: "Activity Graphic")
    static let zoomPresets = [100, 125, 150, 175, 200, 250, 300]

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingView(rootView: WidgetView(model: model))
        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Config.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.delegate = self
        panel.onZoom = { [weak self] factor in
            guard let self else { return }
            self.model.setZoom(self.model.zoom * factor)
        }
        applyStayOnTop()

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(stayOnTopItem)
        menu.addItem(withTitle: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(.separator())

        zoomMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "")
        zoomMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "")
        zoomMenu.addItem(.separator())
        for pct in Self.zoomPresets {
            let item = zoomMenu.addItem(withTitle: "\(pct)%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            item.tag = pct
        }
        for item in zoomMenu.items { item.target = self }
        let zoomItem = menu.addItem(withTitle: "Zoom", action: nil, keyEquivalent: "")
        menu.setSubmenu(zoomMenu, for: zoomItem)

        for (i, kind) in MascotKind.allCases.enumerated() {
            let item = mascotMenu.addItem(withTitle: kind.title, action: #selector(pickMascot(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
        }
        let mascotItem = menu.addItem(withTitle: "Activity Graphic", action: nil, keyEquivalent: "")
        menu.setSubmenu(mascotMenu, for: mascotItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open T3 Code", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit T3 Widget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) && item.action != nil {
            item.target = self
        }
        hosting.menu = menu

        detailHosting = NSHostingView(rootView: DetailView(model: model))
        detailPanel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Config.detailWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        detailPanel.contentView = detailHosting
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = true
        detailPanel.hidesOnDeactivate = false
        detailPanel.isMovable = false
        // The app is never active, so tracking areas are unreliable: poll the pointer instead.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackPointer() }
        }

        model.onChange = { [weak self] in self?.layout() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.layout() } }

        model.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        stayOnTopItem.state = Prefs.stayOnTop ? .on : .off
        let pct = Int((model.zoom * 100).rounded())
        for item in zoomMenu.items where item.tag > 0 { item.state = item.tag == pct ? .on : .off }
        for item in mascotMenu.items {
            item.state = MascotKind.allCases[item.tag] == model.mascot ? .on : .off
        }
    }

    @objc func openApp() { openT3() }
    @objc func zoomIn() { model.setZoom(model.zoom + 0.25) }
    @objc func zoomOut() { model.setZoom(model.zoom - 0.25) }
    @objc func zoomPreset(_ sender: NSMenuItem) { model.setZoom(CGFloat(sender.tag) / 100) }
    @objc func pickMascot(_ sender: NSMenuItem) { model.setMascot(MascotKind.allCases[sender.tag]) }

    @objc func toggleStayOnTop() {
        Prefs.stayOnTop.toggle()
        applyStayOnTop()
    }

    @objc func resetPosition() {
        Prefs.topLeft = nil
        layout()
    }

    /// On: above everything, on every Space and over full-screen apps.
    /// Off: an ordinary window that other windows can cover; click it to raise it.
    func applyStayOnTop() {
        if Prefs.stayOnTop {
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        }
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: Hover popup

    private var hoverCandidate: (id: String, since: Date)?
    private var pointerLastInside = Date.distantPast

    /// The active row under the pointer (with its frame from the widget's top-left), if any.
    private func rowUnderPointer(_ p: NSPoint) -> (id: String, frame: CGRect)? {
        for thread in model.snapshot.active where !thread.detail.isEmpty {
            guard let f = model.rowFrames[thread.id] else { continue }
            let onScreen = NSRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY,
                                  width: f.width, height: f.height)
            if onScreen.contains(p) { return (thread.id, f) }
        }
        return nil
    }

    /// Show the popup after a short pause on a row; switch rows at once while it's open;
    /// keep it while the pointer is over it; hide it shortly after the pointer leaves both.
    func trackPointer() {
        guard panel.isVisible, !model.collapsed else {
            if model.detailID != nil { hideDetail() }
            return
        }
        let p = NSEvent.mouseLocation
        let now = Date()
        if let row = rowUnderPointer(p) {
            pointerLastInside = now
            if hoverCandidate?.id != row.id { hoverCandidate = (row.id, now) }
            let open = model.detailID != nil
            if model.detailID != row.id,
               open || now.timeIntervalSince(hoverCandidate!.since) >= Config.hoverShowDelay {
                hoveredRow = row
                showDetail()
            }
        } else {
            hoverCandidate = nil
            if detailPanel.isVisible && detailPanel.frame.contains(p) {
                pointerLastInside = now
            } else if model.detailID != nil,
                      now.timeIntervalSince(pointerLastInside) >= Config.hoverHideDelay {
                hideDetail()
            }
        }
    }

    private var hoveredRow: (id: String, frame: CGRect)?

    private func showDetail() {
        guard let row = hoveredRow, panel.isVisible,
              model.snapshot.active.contains(where: { $0.id == row.id && !$0.detail.isEmpty }) else { return }
        model.detailID = row.id
        // Let SwiftUI lay out the new text before sizing the panel.
        DispatchQueue.main.async { self.positionDetail() }
    }

    func hideDetail() {
        hoveredRow = nil
        hoverCandidate = nil
        model.detailID = nil
        detailPanel.orderOut(nil)
    }

    /// Beside the widget (right side, or left if there's no room), top-aligned with the row.
    private func positionDetail() {
        guard let id = model.detailID else { return }
        let row = (id: id, frame: model.rowFrames[id] ?? .zero)
        guard model.snapshot.active.contains(where: { $0.id == row.id && !$0.detail.isEmpty }) else {
            hideDetail(); return
        }
        detailHosting.layoutSubtreeIfNeeded()
        let size = detailHosting.fittingSize
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let gap: CGFloat = 6
        var x = panel.frame.maxX + gap
        if x + size.width > visible.maxX { x = panel.frame.minX - gap - size.width }
        x = x.clamped(to: visible.minX...max(visible.minX, visible.maxX - size.width))
        // Row frames are measured from the widget's top-left corner.
        let rowTop = row.frame == .zero ? detailPanel.frame.maxY : panel.frame.maxY - row.frame.minY
        let top = rowTop.clamped(to: (visible.minY + size.height)...visible.maxY)
        detailPanel.level = panel.level
        detailPanel.collectionBehavior = panel.collectionBehavior
        detailPanel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                             display: true)
        detailPanel.orderFrontRegardless()
    }

    private var layingOut = false

    /// Fires after the user drags the widget (and after our own resizes, which we skip).
    func windowDidMove(_ notification: Notification) {
        if !layingOut { saveTopLeft(); hideDetail() }
    }

    func saveTopLeft() {
        Prefs.topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// Keep the widget's top-left corner fixed (saved spot, or the default corner) as it grows.
    func layout() {
        guard model.snapshot.online else { panel.orderOut(nil); hideDetail(); return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let main = NSScreen.screens.first else { return }
        let fallback = NSPoint(x: main.visibleFrame.minX + Config.margin,
                               y: main.visibleFrame.maxY - Config.margin)
        var topLeft = Prefs.topLeft ?? fallback
        // If the saved spot is no longer on any screen (display unplugged), go back to default.
        let grab = NSRect(x: topLeft.x, y: topLeft.y - 30, width: 60, height: 30)
        if !NSScreen.screens.contains(where: { $0.frame.intersects(grab) }) { topLeft = fallback }
        layingOut = true
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height,
                              width: size.width, height: size.height), display: true)
        layingOut = false
        if !panel.isVisible { panel.orderFrontRegardless() }
        if model.detailID != nil { positionDetail() }  // follow content and row changes
    }
}

@main
struct T3WidgetApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar
        app.run()
    }
}
