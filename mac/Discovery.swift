import Foundation
import CryptoKit
import Network

enum DiscoveryProtocol {
    static func response(to request: Data, key: SymmetricKey, port: UInt16) -> Data? {
        guard request.count == 52, Array(request.prefix(4)) == Array("WAD1".utf8),
              HMAC<SHA256>.isValidAuthenticationCode(request.suffix(32), authenticating: request.prefix(20), using: key) else { return nil }
        var response = Data("WAR1".utf8)
        response.append(request[4..<20])
        response.append(UInt8(port & 255)); response.append(UInt8(port >> 8))
        response.append(contentsOf: HMAC<SHA256>.authenticationCode(for: response, using: key))
        return response
    }
}

/// Answers discovery on its own queue: Windows stops sending audio when answers stop,
/// so a busy main thread must never delay them.
final class DiscoveryServer {
    let key: SymmetricKey
    let port: UInt16
    let queue = DispatchQueue(label: "local.audiobridge.discovery")
    var listener: NWListener?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    private let errorLock = NSLock()
    private var lastError: String?
    var error: String? {
        get { errorLock.lock(); defer { errorLock.unlock() }; return lastError }
        set { errorLock.lock(); lastError = newValue; errorLock.unlock() }
    }
    init(config: Configuration) {
        key = SymmetricKey(data: Data(base64Encoded: config.Key)!)
        port = config.Port
    }
    func start() { queue.async { self.startListener() } }
    private func startListener() {
        do {
            let listener = try NWListener(using: .udp, on: 49153)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.error = nil
                case .failed(let error):
                    self.error = error.localizedDescription
                    self.listener?.cancel()
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 64 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed: self?.connections.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: self.queue)
                connection.receiveMessage { [weak self] data, _, _, failure in
                    guard let self, failure == nil, let data,
                          let response = DiscoveryProtocol.response(to: data, key: self.key, port: self.port) else { connection.cancel(); return }
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
                self.queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
            }
            listener.start(queue: queue)
        } catch {
            self.error = error.localizedDescription
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
        }
    }
    func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            for connection in connections.values { connection.cancel() }
        }
    }
}
