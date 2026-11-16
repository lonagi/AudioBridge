import AppKit
import AVFoundation
import CryptoKit
import Network
import Darwin

func lanIP() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return nil }
    defer { freeifaddrs(interfaces) }
    var current = interfaces
    var fallback: String?
    while let item = current {
        defer { current = item.pointee.ifa_next }
        guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: item.pointee.ifa_name)
        guard name.hasPrefix("en") || name == "bridge0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if name == "en0" { return ip }
            fallback = ip
        }
    }
    return fallback
}

final class Receiver {
    let key: SymmetricKey
    let config: Configuration
    var listener: NWListener?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var connectionSeen: [ObjectIdentifier: TimeInterval] = [:]
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var audioFormat: AVAudioFormat?
    var gate = SequenceGate()
    var generation = 0
    var queuedFrames = 0
    var packets = 0
    var missing = 0
    var resets = 0
    var peak: Float = 0
    var primed = false
    var startScheduled = false
    var enabled = true
    var error: String?
    var volume: Float = 0.5 { didSet { player.volume = volume } }
    var diagnosticsPath: String?

    init(config: Configuration) {
        self.config = config
        key = SymmetricKey(data: Data(base64Encoded: config.Key)!)
        engine.attach(player)
        player.volume = volume
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resetPlayback(); self.audioFormat = nil
        }
    }
    func start() {
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: config.Port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state {
                    self?.error = "Сеть: \(e.localizedDescription)"
                    self?.listener?.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                self.connectionSeen[id] = ProcessInfo.processInfo.systemUptime
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled:
                        self?.connections.removeValue(forKey: id)
                        self?.connectionSeen.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: .main)
                self.read(connection)
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription }
    }
    func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, failure in
            guard let self else { return }
            if failure != nil { connection.cancel(); return }
            guard let data, let packet = AudioPacket.decode(data, key: self.key) else { connection.cancel(); return }
            self.connectionSeen[ObjectIdentifier(connection)] = ProcessInfo.processInfo.systemUptime
            self.accept(packet)
            self.read(connection)
        }
    }
    func resetPlayback() {
        generation += 1
        player.stop()
        queuedFrames = 0; primed = false; startScheduled = false
    }
    func pruneConnections() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, lastSeen) in connectionSeen where now - lastSeen > 15 {
            connections[id]?.cancel()
        }
    }
    func accept(_ packet: AudioPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let continuity = gate.accept(packet, now: now) else { return }
        packets += 1; missing += continuity.missing
        guard enabled else { return }
        do {
            if audioFormat?.sampleRate != Double(packet.rate) || !engine.isRunning {
                resetPlayback()
                engine.stop()
                engine.disconnectNodeOutput(player)
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(packet.rate), channels: 2)!
                engine.connect(player, to: engine.mainMixerNode, format: format)
                audioFormat = format
                engine.prepare()
                try engine.start()
            }
            if continuity.reset || queuedFrames > packet.rate * 18 / 100 {
                resetPlayback(); resets += 1
            }
            if continuity.missing > 0 && continuity.missing <= 8 && !continuity.reset {
                let silence = Data(count: continuity.missing * packet.frames * 4)
                schedule(silence, frames: continuity.missing * packet.frames)
            } else if continuity.missing > 8 { resetPlayback(); resets += 1 }
            schedule(packet.pcm, frames: packet.frames)
            if !primed && !startScheduled {
                // Wait in wall-clock time so a 100 ms capture burst retains jitter headroom.
                // Short notifications also play even if shorter than the buffer target.
                startScheduled = true
                let currentGeneration = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self, self.enabled, self.generation == currentGeneration,
                          !self.primed, self.queuedFrames > 0 else { return }
                    self.player.play(); self.primed = true
                }
            }
            error = nil
        } catch { self.error = "Аудио: \(error.localizedDescription)" }
    }
    func schedule(_ pcm: Data, frames: Int) {
        guard let format = audioFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var maximum: Float = 0
        for f in 0..<frames {
            for c in 0..<2 {
                let offset = f * 4 + c * 2
                let raw = UInt16(pcm[offset]) | UInt16(pcm[offset + 1]) << 8
                let sample = Float(Int16(bitPattern: raw)) / 32768
                channels[c][f] = sample; maximum = max(maximum, abs(sample))
            }
        }
        peak = max(peak * 0.95, maximum)
        queuedFrames += frames
        let currentGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, currentGeneration == self.generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        resetPlayback()
        if !enabled { engine.stop() }
    }
    func snapshot() -> [String: Any] {
        ["packets": packets, "missing": missing, "bufferFrames": queuedFrames,
         "engineRunning": engine.isRunning, "playing": player.isPlaying,
         "resets": resets, "error": error ?? "", "enabled": enabled]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var receiver: Receiver!
    var server: DownloadServer?
    var discovery: DiscoveryServer?
    var status = NSTextField(labelWithString: "Ожидание Windows")
    var details = NSTextField(labelWithString: "")
    var level = NSLevelIndicator()
    var volumeText = NSTextField(labelWithString: "50%")
    var toggle = NSButton()
    var urlField = NSTextField()
    var address = NSTextField(labelWithString: "")
    var windowsStatus = NSTextField(labelWithString: "Windows: ожидаю новую версию отправителя")
    var updateStatus = NSTextField(wrappingLabelWithString: "")
    var updateButton = NSButton()
    var microphone: MicrophoneHub!
    var micToggle = NSButton()
    var micSource = NSPopUpButton()
    var micStatus = NSTextField(wrappingLabelWithString: "Микрофон выключен")
    var micLevel = NSLevelIndicator()
    var micMenuKey = ""
    var micHint = NSTextField(wrappingLabelWithString: "")

    var timer: Timer?
    var config: Configuration!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let resources = Bundle.main.resourceURL!
            config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("connection.json")))
            guard let key = Data(base64Encoded: config.Key), key.count == 32 else { throw NSError(domain: "Invalid key", code: 1) }
            receiver = Receiver(config: config)
            microphone = MicrophoneHub(pairing: key)
            if CommandLine.arguments.contains("--start-paused") { receiver.setEnabled(false) }
            discovery = DiscoveryServer(config: config)
            discovery?.start()
            if let i = CommandLine.arguments.firstIndex(of: "--diagnostics"), CommandLine.arguments.count > i + 1 {
                receiver.diagnosticsPath = CommandLine.arguments[i + 1]
            }
            if let zip = try? Data(contentsOf: resources.appendingPathComponent("Windows-Audio.zip")) {
                let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("windows-version.json"))) as! [String: String]
                server = DownloadServer(zip: zip, token: config.DownloadToken!, key: SymmetricKey(data: key), version: metadata["Version"]!)
                server?.microphone = microphone
                server?.start()
            }
            createWindow()
            receiver.start()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.refresh() }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert(); alert.messageText = "Не удалось открыть AudioBridge"
            alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AudioBridge 0.4.2 · Mac ↔ Windows"
        window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        let title = NSTextField(labelWithString: "Звук Windows в наушниках Mac")
        title.font = .systemFont(ofSize: 23, weight: .semibold); root.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Звук Mac и Windows звучит одновременно. Выход — текущее устройство звука macOS.")
        subtitle.textColor = .secondaryLabelColor; root.addArrangedSubview(subtitle)
        status.font = .systemFont(ofSize: 17, weight: .medium); root.addArrangedSubview(status)
        details.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        details.textColor = .secondaryLabelColor; root.addArrangedSubview(details)
        level.levelIndicatorStyle = .continuousCapacity; level.minValue = 0; level.maxValue = 1
        level.warningValue = 0.85; level.criticalValue = 0.98
        root.addArrangedSubview(level); level.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let volumeRow = NSStackView(); volumeRow.orientation = .horizontal; volumeRow.spacing = 12
        volumeRow.addArrangedSubview(NSTextField(labelWithString: "Громкость Windows"))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(changeVolume(_:)))
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        volumeRow.addArrangedSubview(slider); volumeRow.addArrangedSubview(volumeText); root.addArrangedSubview(volumeRow)
        let separator = NSBox(); separator.boxType = .separator; root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let micHeading = NSStackView(); micHeading.orientation = .horizontal; micHeading.spacing = 16
        let micTitle = NSTextField(labelWithString: "Микрофон Mac → Windows")
        micTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        micToggle = NSButton(title: "Включить микрофон", target: self, action: #selector(toggleMicrophone))
        micHeading.addArrangedSubview(micTitle); micHeading.addArrangedSubview(micToggle); root.addArrangedSubview(micHeading)
        micSource.target = self; micSource.action = #selector(selectMicrophone)
        let sourceRow = NSStackView(); sourceRow.orientation = .horizontal; sourceRow.spacing = 12
        sourceRow.addArrangedSubview(NSTextField(labelWithString: "Источник")); sourceRow.addArrangedSubview(micSource)
        micSource.widthAnchor.constraint(equalToConstant: 330).isActive = true; root.addArrangedSubview(sourceRow)
        micStatus.font = .systemFont(ofSize: 12); root.addArrangedSubview(micStatus)
        micLevel.levelIndicatorStyle = .continuousCapacity; micLevel.minValue = 0; micLevel.maxValue = 1
        root.addArrangedSubview(micLevel); micLevel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        micHint.font = .systemFont(ofSize: 11); micHint.textColor = .secondaryLabelColor; root.addArrangedSubview(micHint)
        let micSeparator = NSBox(); micSeparator.boxType = .separator; root.addArrangedSubview(micSeparator)
        micSeparator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let updateRow = NSStackView(); updateRow.orientation = .horizontal; updateRow.spacing = 16
        windowsStatus.font = .systemFont(ofSize: 13, weight: .medium)
        updateButton = NSButton(title: "Обновить Windows", target: self, action: #selector(updateWindows))
        updateRow.addArrangedSubview(windowsStatus); updateRow.addArrangedSubview(updateButton); root.addArrangedSubview(updateRow)
        updateStatus.font = .systemFont(ofSize: 12); updateStatus.textColor = .secondaryLabelColor
        root.addArrangedSubview(updateStatus)
        let instructions = NSTextField(wrappingLabelWithString: "На Windows скачайте ZIP по ссылке и запустите Install.cmd. Автозапуск можно отключить в Диспетчере задач.")
        root.addArrangedSubview(instructions)
        urlField.isEditable = false; urlField.isSelectable = true
        urlField.font = .systemFont(ofSize: 12); root.addArrangedSubview(urlField)
        urlField.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 12
        let copy = NSButton(title: "Скопировать ссылку", target: self, action: #selector(copyLink))
        toggle = NSButton(title: receiver.enabled ? "Приостановить звук" : "Возобновить звук", target: self, action: #selector(toggleAudio))
        buttons.addArrangedSubview(copy); buttons.addArrangedSubview(toggle); root.addArrangedSubview(buttons)
        address.font = .systemFont(ofSize: 11); address.textColor = .secondaryLabelColor; root.addArrangedSubview(address)
        let menu = NSMenu(); let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Завершить AudioBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem); NSApp.mainMenu = menu
        refresh(); window.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard receiver != nil else { return }
        microphone.tick(); refreshMicrophone()
        receiver.pruneConnections()
        let ip = lanIP() ?? config.MacIP
        urlField.stringValue = "http://\(ip):8765/\(config.DownloadToken!)/Windows-Audio.zip"
        let active = ProcessInfo.processInfo.systemUptime - receiver.gate.lastSeen < 1.5
        if let error = receiver.error { status.stringValue = error; status.textColor = .systemRed }
        else {
            status.stringValue = !receiver.enabled ? "Приём звука приостановлен" : active ? "Получаю звук Windows" : "Ожидание звука Windows…"
            status.textColor = active && receiver.enabled ? .systemGreen : .labelColor
        }
        let rate = receiver.audioFormat?.sampleRate ?? 48000
        details.stringValue = "Пакетов: \(receiver.packets)   ·   Пропущено: \(receiver.missing)   ·   Буфер: \(Int(Double(receiver.queuedFrames) / rate * 1000)) мс"
        level.doubleValue = active && receiver.enabled ? Double(receiver.peak * receiver.volume) : 0
        if let server {
            updateButton.isEnabled = server.connected && server.pendingId.isEmpty && server.peer?.State != "Downloading" && server.peer?.State != "Restarting"
            if server.connected, let peer = server.peer { windowsStatus.stringValue = "Windows: \(peer.Name) · \(peer.Version)" }
            else { windowsStatus.stringValue = "Windows: нет соединения с обновлением" }
            updateStatus.stringValue = server.updateNote
        }
        if let serverError = server?.error { address.stringValue = "Не удалось открыть ссылку для Windows: \(serverError)" }
        else if let discoveryError = discovery?.error { address.stringValue = "Автопоиск временно недоступен: \(discoveryError)" }
        else { address.stringValue = "Mac: \(ip)   ·   Автопоиск в сети   ·   Изменение IP обрабатывается автоматически" }
        var diagnostics = receiver.snapshot()
        diagnostics["microphoneEnabled"] = microphone.enabled
        diagnostics["microphoneCapturing"] = microphone.engine?.isRunning ?? false
        diagnostics["microphoneSource"] = microphone.source
        diagnostics["microphoneStatus"] = microphone.status
        diagnostics["windowsMicrophoneStatus"] = microphone.windowsMicStatus
        if let telemetry = microphone.telemetry, let data = try? JSONEncoder().encode(telemetry), let object = try? JSONSerialization.jsonObject(with: data) { diagnostics["windowsMicrophone"] = object }
        diagnostics["windowsVersion"] = server?.peer?.Version ?? ""
        if let path = receiver.diagnosticsPath, let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    func refreshMicrophone() {
        micToggle.title = microphone.enabled ? "Выключить микрофон" : "Включить микрофон"
        micToggle.isEnabled = microphone.connected
        micStatus.stringValue = microphone.connected ? microphone.status : "Ожидаю Windows. Микрофон выключен."
        micStatus.textColor = microphone.engine?.isRunning == true ? .systemGreen : .secondaryLabelColor
        if microphone.enabled, microphone.telemetry?.IsDefault == true, (microphone.telemetry?.InputFrames ?? 0) > 0 {
            micStatus.stringValue = "Микрофон подключён к Windows · AudioRelay"
        }
        micLevel.doubleValue = Double(microphone.telemetry?.InputPeak ?? 0)
        let key = microphone.sources.map { "\($0.Id):\($0.Name):\($0.Available)" }.joined() + microphone.outputs.map { "\($0.Id):\($0.Name)" }.joined()
        if key != micMenuKey {
            micMenuKey = key; micSource.removeAllItems()
            micSource.autoenablesItems = false
            for source in microphone.sources {
                micSource.addItem(withTitle: source.Name); micSource.lastItem?.representedObject = source.Id; micSource.lastItem?.isEnabled = source.Available
            }
        }
        micSource.select(micSource.itemArray.first { ($0.representedObject as? String) == microphone.source })
        micHint.stringValue = "Windows подключает микрофон автоматически. В игре или звонке используйте «По умолчанию». После запуска передача выключена."
    }
    @objc func toggleMicrophone() { microphone.change(enabled: !microphone.enabled); refreshMicrophone() }
    @objc func selectMicrophone() { microphone.change(source: micSource.selectedItem?.representedObject as? String); refreshMicrophone() }
    @objc func updateWindows() { server?.requestUpdate(); refresh() }
    @objc func changeVolume(_ sender: NSSlider) { receiver.volume = sender.floatValue; volumeText.stringValue = "\(Int(sender.doubleValue * 100))%" }
    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlField.stringValue, forType: .string) }
    @objc func toggleAudio() {
        receiver.setEnabled(!receiver.enabled)
        toggle.title = receiver.enabled ? "Приостановить звук" : "Возобновить звук"; refresh()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--microphone-control-test") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    MicrophoneTests.control(Data(base64Encoded: config.Key)!)
} else if CommandLine.arguments.contains("--mic-fixture") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let key = MicPacket.key(Data(base64Encoded: config.Key)!, stream: "0123456789abcdef0123456789abcdef")
    var pcm = Data(); for value: Int16 in [1234, -2345, 0, 32767] { var le = value.littleEndian; withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) } }
    try MicPacket.encode(pcm, rate: 48000, sequence: 0, key: key).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
} else if CommandLine.arguments.contains("--microphone-server-test") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let key = Data(base64Encoded: config.Key)!
    let server = DownloadServer(zip: Data(), token: "test", key: SymmetricKey(data: key), version: "0.4.2")
    server.microphone = MicrophoneHub(pairing: key); server.microphone?.syntheticTest = true
    server.start(port: 8766)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
    print("Synthetic microphone test on 8766; physical microphone is OFF"); fflush(stdout)
    dispatchMain()
} else if CommandLine.arguments.contains("--update-server-test") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let zip = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let server = DownloadServer(zip: zip, token: config.DownloadToken!, key: SymmetricKey(data: Data(base64Encoded: config.Key)!), version: "0.4.2")
    server.start(port: 8766)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    var queued = false
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler {
        if server.connected && !queued { server.requestUpdate(); queued = true }
    }
    timer.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
    print("Authenticated update test server on 8766; audio is OFF"); fflush(stdout)
    dispatchMain()
} else if CommandLine.arguments.contains("--verify-discovery") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let key = SymmetricKey(data: Data(base64Encoded: config.Key)!)
    let request = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    guard let response = DiscoveryProtocol.response(to: request, key: key, port: config.Port) else { fatalError("C# discovery authentication failed") }
    precondition(response.count == 54)
    var invalid = request; invalid[20] ^= 1
    precondition(DiscoveryProtocol.response(to: invalid, key: key, port: config.Port) == nil)
    precondition(DiscoveryProtocol.response(to: request.prefix(10), key: key, port: config.Port) == nil)
    precondition(DiscoveryProtocol.response(to: request, key: SymmetricKey(size: .bits256), port: config.Port) == nil)
    try response.write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    print("PASS: authenticated discovery request; rejects tampering, truncation and wrong key")
} else if CommandLine.arguments.contains("--discovery-server-test") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let server = DiscoveryServer(config: config)
    server.start()
    print("Discovery-only test server; audio is OFF")
    fflush(stdout)
    let duration = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 20 : 20
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { server.stop(); exit(0) }
    dispatchMain()
} else if CommandLine.arguments.contains("--verify-fixture") {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let key = SymmetricKey(data: Data(base64Encoded: config.Key)!)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    guard let packet = AudioPacket.decode(bytes, key: key) else { fatalError("C# → Swift AES-GCM failed") }
    precondition(packet.rate == 48000 && packet.frames == 4 && packet.pcm[1] == 64 && packet.pcm[3] == 192)
    var tampered = bytes; tampered[24] ^= 1
    precondition(AudioPacket.decode(tampered, key: key) == nil)
    tampered = bytes; tampered[16] ^= 1
    precondition(AudioPacket.decode(tampered, key: key) == nil)
    precondition(AudioPacket.decode(bytes.prefix(32), key: key) == nil)
    precondition(AudioPacket.decode(bytes, key: SymmetricKey(size: .bits256)) == nil)
    var gate = SequenceGate()
    precondition(gate.accept(packet, now: 10) != nil)
    precondition(gate.accept(packet, now: 10.1) == nil)
    let next = AudioPacket(session: packet.session, sequence: packet.sequence + 3, rate: packet.rate, frames: packet.frames, pcm: packet.pcm)
    precondition(gate.accept(next, now: 10.2)?.missing == 2)
    let other = AudioPacket(session: Data(repeating: 9, count: 8), sequence: 0, rate: packet.rate, frames: packet.frames, pcm: packet.pcm)
    precondition(gate.accept(other, now: 10.3) == nil)
    precondition(gate.accept(other, now: 11)?.reset == true)
    print("PASS: cross-language PCM/encryption, tamper rejection, truncation, wrong key, duplicates, loss and session isolation")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
