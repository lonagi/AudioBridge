import Foundation
import CryptoKit
import Network

enum UpdateAuth {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func tag(_ text: String, key: SymmetricKey) -> String { HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).map { String(format: "%02x", $0) }.joined() }
    static func request(_ method: String, _ path: String, _ nonce: String, _ body: Data, key: SymmetricKey) -> String {
        tag("AB-REQ/1\n\(method)\n\(path)\n\(nonce)\n\(hash(body))", key: key)
    }
    static func response(_ code: Int, _ nonce: String, _ digest: String, key: SymmetricKey) -> String {
        tag("AB-RESP/1\n\(code)\n\(nonce)\n\(digest)", key: key)
    }
    static func equal(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8), bb = Array(b.utf8)
        guard aa.count == 64, bb.count == 64 else { return false }
        var difference: UInt8 = 0
        for i in 0..<64 { difference |= aa[i] ^ bb[i] }
        return difference == 0
    }
}

struct WindowsPeer: Codable {
    let ClientId: String
    let Name: String
    let Version: String
    let State: String
    let Message: String
    let RequestId: String
    let Microphone: MicReport?
}
struct MicStreamRequest: Codable { let ClientId: String; let Session: String; let Stream: String }

final class DownloadServer {
    var listener: NWListener?
    let zip: Data
    let zipHash: String
    let version: String
    let path: String
    let key: SymmetricKey
    var error: String?
    var peer: WindowsPeer?
    var lastSeen: TimeInterval = 0
    var updateNote = "Для первого обновления Windows запустите Install.cmd из нового архива."
    var pendingId = ""
    var pendingClient = ""
    var nonces: [String: TimeInterval] = [:]
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var microphone: MicrophoneHub?
    var connected: Bool { peer != nil && ProcessInfo.processInfo.systemUptime - lastSeen < 10 }

    init(zip: Data, token: String, key: SymmetricKey, version: String) {
        self.zip = zip; zipHash = UpdateAuth.hash(zip); self.version = version
        self.path = "/\(token)/Windows-Audio.zip"; self.key = key
    }
    func requestUpdate() {
        guard connected, let peer else { updateNote = "Windows не подключён. Первый раз установите новую версию вручную."; return }
        pendingId = UUID().uuidString; pendingClient = peer.ClientId
        updateNote = "Запрос отправлен на \(peer.Name)…"
    }
    func start(port: UInt16 = 8765) {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state { self?.error = e.localizedDescription }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 16 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection); self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    switch state { case .failed, .cancelled: self?.connections.removeValue(forKey: id); default: break }
                }
                connection.start(queue: .main)
                self.read(connection, accumulated: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                    if self?.microphone?.connection !== connection { connection.cancel() }
                }
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription }
    }
    func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, failure in
            guard let self, let data, failure == nil else { connection.cancel(); return }
            var request = accumulated; request.append(data)
            guard request.count <= 24576 else { connection.cancel(); return }
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || request.count > 8192 { connection.cancel() } else { self.read(connection, accumulated: request) }; return
            }
            let lines = String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { connection.cancel(); return }
                let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard headers[name] == nil else { connection.cancel(); return }; headers[name] = value
            }
            guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...16384).contains(length) else { connection.cancel(); return }
            let total = end.upperBound + length
            if request.count < total {
                if complete { connection.cancel() } else { self.read(connection, accumulated: request) }; return
            }
            guard request.count == total else { connection.cancel(); return }
            self.handle(connection, method: String(first[0]), route: String(first[1]), headers: headers, body: Data(request[end.upperBound..<total]))
        }
    }
    func send(_ connection: NWConnection, code: Int, body: Data, nonce: String? = nil, zip: Bool = false) {
        let name = code == 200 ? "OK" : code == 401 ? "Unauthorized" : "Not Found"
        let auth = nonce.map { "X-AB-Auth: \(UpdateAuth.response(code, $0, zip ? zipHash : UpdateAuth.hash(body), key: key))\r\n" } ?? ""
        let header = "HTTP/1.1 \(code) \(name)\r\nContent-Type: \(zip ? "application/zip" : "application/json")\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(auth)\r\n"
        // One outstanding package response per connection. No arbitrary filesystem routes.
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
        })
    }
    func handle(_ connection: NWConnection, method: String, route: String, headers: [String: String], body: Data) {
        if method == "GET" && route == path { send(connection, code: 200, body: zip, zip: true); return }
        guard ["/api/status", "/api/package", "/api/microphone"].contains(route) else { send(connection, code: 404, body: Data("{}".utf8)); return }
        let now = ProcessInfo.processInfo.systemUptime
        nonces = nonces.filter { now - $0.value < 300 }
        guard let nonce = headers["x-ab-nonce"], nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit }),
              nonces[nonce] == nil, nonces.count < 4096,
              let signature = headers["x-ab-auth"], UpdateAuth.equal(signature, UpdateAuth.request(method, route, nonce, body, key: key)) else {
            send(connection, code: 401, body: Data("{}".utf8)); return
        }
        nonces[nonce] = now
        if method == "POST", route == "/api/microphone" {
            guard let microphone, microphone.enabled, microphone.connected,
                  let request = try? JSONDecoder().decode(MicStreamRequest.self, from: body),
                  request.ClientId == microphone.clientId, request.Session == microphone.session,
                  request.Stream.count == 32, request.Stream.allSatisfy({ $0.isHexDigit }) else {
                send(connection, code: 401, body: Data("{}".utf8), nonce: nonce); return
            }
            let tag = UpdateAuth.response(200, nonce, UpdateAuth.hash(Data()), key: key)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nX-AB-Auth: \(tag)\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak microphone] error in
                guard error == nil, let microphone, microphone.enabled, microphone.connected else { connection.cancel(); return }
                microphone.openStream(connection, stream: request.Stream)
            })
            return
        }
        if method == "GET" && route == "/api/package" { send(connection, code: 200, body: zip, nonce: nonce, zip: true); return }
        guard method == "POST", route == "/api/status", let report = try? JSONDecoder().decode(WindowsPeer.self, from: body),
              report.ClientId.count <= 64, !report.ClientId.isEmpty, report.Name.count <= 128, report.Version.count <= 32,
              report.State.count <= 32, report.Message.count <= 2048, report.RequestId.count <= 64 else { send(connection, code: 404, body: Data("{}".utf8), nonce: nonce); return }
        if connected, let peer, peer.ClientId != report.ClientId { send(connection, code: 401, body: Data("{}".utf8), nonce: nonce); return }
        let previous = peer
        peer = report; lastSeen = now
        if let mic = report.Microphone, mic.Session.count <= 64, !mic.Session.isEmpty,
           mic.Outputs.count <= 32, mic.Outputs.allSatisfy({ $0.Id.count <= 512 && $0.Name.count <= 256 }),
           mic.Status.count <= 1024, (mic.Command?.Id.count ?? 0) <= 64,
           (mic.Command?.OutputId?.count ?? 0) <= 512, (mic.Command?.Source?.count ?? 0) <= 32 {
            microphone?.report(mic, client: report.ClientId)
        }
        if pendingClient == report.ClientId && pendingId == report.RequestId { pendingId = ""; pendingClient = "" }
        switch report.State {
        case "Downloading": updateNote = "Windows скачивает обновление…"
        case "Restarting": updateNote = "Windows перезапускается. Звук восстановится после подключения."
        case "Current": updateNote = report.Message
        case "Error": updateNote = "Обновление Windows: \(report.Message)"
        case "Ready":
            if previous?.State == "Restarting" && report.Version == version { updateNote = "Готово: Windows обновлён до \(version) и подключён." }
            else if previous == nil { updateNote = "Windows подключён. Обновления можно запускать этой кнопкой." }
        default: break
        }
        var manifest: [String: Any] = ["Version": version, "Sha256": zipHash, "Size": zip.count, "RequestId": pendingClient == report.ClientId ? pendingId : ""]
        if let microphone { manifest["Microphone"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(microphone.snapshot())) }
        send(connection, code: 200, body: try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), nonce: nonce)
    }
}
