import AppKit
import AVFoundation
import CryptoKit
import Network
import Darwin
import os

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

let audioLog = Logger(subsystem: "local.audiobridge.receiver", category: "audio")

/// Receives the Windows stream and plays it.
///
/// Everything below runs on `queue`, never on the main thread, so window updates, microphone
/// setup or a slow Core Audio call during a Bluetooth switch cannot stall playback.
/// The output engine is rebuilt from scratch after device changes and whenever the watchdog
/// sees it stop rendering. That is what restarting the app used to fix by hand.
final class Receiver {
    struct Stats {
        var packets = 0, missing = 0, resets = 0, recoveries = 0, dropped = 0, underruns = 0
        var queuedFrames = 0, rate = 48000.0, peak: Float = 0, lastSeen: TimeInterval = 0
        var engineRunning = false, playing = false, enabled = true, bufferTargetMs = 60
        var error: String?
    }
    let key: SymmetricKey
    let config: Configuration
    let queue = DispatchQueue(label: "local.audiobridge.receiver", qos: .userInteractive)
    var diagnosticsPath: String?

    private let statsLock = NSLock()
    private var shared = Stats()
    /// Thread-safe copy for the UI.
    var stats: Stats { statsLock.lock(); defer { statsLock.unlock() }; return shared }
    private func update(_ change: (inout Stats) -> Void) { statsLock.lock(); change(&shared); statsLock.unlock() }

    // State owned by `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (connection: NWConnection, seen: TimeInterval)] = [:]
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?
    private var engineRate = 0
    private var configObserver: NSObjectProtocol?
    private var gate = SequenceGate()
    private var generation = 0
    private var queuedFrames = 0
    private var primed = false
    private var startScheduled = false
    private var needsRebuffer = false
    private var enabled = true
    private var volume: Float = 0.5
    private var peak: Float = 0
    private var lastPacket: TimeInterval = 0
    private var lastRendered: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 0.5
    private var targetMs = 60.0
    private var lastUnderrun: TimeInterval = 0
    private var lowestQueued = Int.max
    private var trimFrames = 0
    /// After a dry-out that followed a long gap: audio arriving much faster than real time means the
    /// network held packets back (an underrun); audio at normal pace means Windows simply paused.
    private var stallProbe: (start: TimeInterval, gap: TimeInterval, frames: Int)?
    private var watchdog: DispatchSourceTimer?

    private static let baseTargetMs = 60.0, maxTargetMs = 160.0, headroomMs = 150.0

    init(config: Configuration) {
        self.config = config
        key = SymmetricKey(data: Data(base64Encoded: config.Key)!)
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() { queue.async { self.startListener(); self.startWatchdog() } }
    func setEnabled(_ value: Bool) {
        update { $0.enabled = value }
        queue.async {
            self.enabled = value
            if value { self.resetPlayback() } else { self.teardownEngine() }
        }
    }
    func setVolume(_ value: Float) { queue.async { self.volume = value; self.player?.volume = value } }
    /// Test only: reproduce what macOS does to the output during device hand-offs.
    func simulate(_ event: String) {
        queue.async {
            switch event {
            case "device-change": self.recover("output device changed (test)")
            case "stall": if let player = self.player { self.engine?.disconnectNodeOutput(player) }  // running, but nothing renders
            case "stop": self.engine?.stop()  // stopped without a notification
            default: break
            }
        }
    }
    func snapshot() -> [String: Any] {
        let s = stats
        return ["packets": s.packets, "missing": s.missing, "bufferFrames": s.queuedFrames,
                "engineRunning": s.engineRunning, "playing": s.playing, "resets": s.resets,
                "recoveries": s.recoveries, "dropped": s.dropped, "underruns": s.underruns,
                "bufferTargetMs": s.bufferTargetMs, "error": s.error ?? "", "enabled": s.enabled]
    }

    // MARK: Network

    private func startListener() {
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: config.Port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .failed(let e) = state else { return }
                self.setError("Сеть: \(e.localizedDescription)")
                self.listener?.cancel(); self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = (connection, self.now)
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.connections.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.start(queue: queue)
        } catch {
            setError("Сеть: \(error.localizedDescription)")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
        }
    }
    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, failure in
            guard let self else { return }
            if failure != nil { connection.cancel(); return }
            guard let data, let packet = AudioPacket.decode(data, key: self.key) else { connection.cancel(); return }
            self.connections[ObjectIdentifier(connection)]?.seen = self.now
            self.accept(packet)
            self.read(connection)
        }
    }
    private func setError(_ text: String?) {
        if stats.error != text { update { $0.error = text } }
    }

    // MARK: Playback

    private func accept(_ packet: AudioPacket) {
        let time = now
        guard let continuity = gate.accept(packet, now: time) else { return }
        let gap = time - lastPacket
        lastPacket = time
        update { $0.packets += 1; $0.missing += continuity.missing; $0.lastSeen = time }
        guard enabled, ensureEngine(rate: packet.rate), let player else { return }
        if continuity.reset || continuity.missing > 8 {
            // New sound after silence, or a big loss: start a fresh buffer with jitter headroom.
            if queuedFrames > 0 { noteReset(continuity.reset ? "new stream" : "lost \(continuity.missing) packets") }
            resetPlayback()
        } else {
            if needsRebuffer {
                // The buffer ran dry: wait for a cushion again before resuming.
                needsRebuffer = false; trimFrames = 0
                player.pause(); primed = false; startScheduled = false
                update { $0.playing = false }
                // Only a stream that kept coming and still ran dry is a network underrun. A short pause
                // on the Windows side (no app playing sound) must not raise latency.
                if gap <= targetMs / 1000 + 0.05 { countUnderrun(time) } else { stallProbe = (time, gap, 0) }
            }
            if let probe = stallProbe {
                if time - probe.start <= 0.02 {
                    let frames = probe.frames + packet.frames
                    if Double(frames) >= 0.6 * probe.gap * Double(packet.rate) { countUnderrun(time); stallProbe = nil }
                    else { stallProbe = (probe.start, probe.gap, frames) }
                } else { stallProbe = nil }
            }
            if continuity.missing > 0 {
                let frames = continuity.missing * packet.frames
                schedule(Data(count: frames * 4), frames: frames, player: player)
            }
        }
        // Keep latency bounded without flushing what is already queued: when the sender's clock
        // runs ahead or a burst arrives, skip this 5 ms packet instead of resetting the player.
        // trimFrames removes latency that piled up earlier (see checkHealth) the same way.
        let targetFrames = Int(Double(packet.rate) * targetMs / 1000)
        if (trimFrames > 0 && queuedFrames > targetFrames) || queuedFrames + packet.frames > Int(Double(packet.rate) * (targetMs + Self.headroomMs) / 1000) {
            trimFrames = max(0, trimFrames - packet.frames)
            update { $0.dropped += 1 }
            return
        }
        schedule(packet.pcm, frames: packet.frames, player: player)
        if !primed { startWhenBuffered() }
        if stats.error != nil { setError(nil) }
    }
    private func schedule(_ pcm: Data, frames: Int, player: AVAudioPlayerNode) {
        guard let format = streamFormat, pcm.count >= frames * 4,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var maximum: Float = 0
        pcm.withUnsafeBytes { raw in
            for f in 0..<frames {
                for c in 0..<2 {
                    let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (f * 2 + c) * 2, as: Int16.self))) / 32768
                    channels[c][f] = sample; maximum = max(maximum, abs(sample))
                }
            }
        }
        peak = max(peak * 0.95, maximum)
        queuedFrames += frames
        let expected = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard expected == self.generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                self.lowestQueued = min(self.lowestQueued, self.queuedFrames)
                self.lastRendered = self.now
                if self.queuedFrames == 0 && self.primed { self.needsRebuffer = true }
            }
        }
        let queued = queuedFrames, level = peak
        update { $0.queuedFrames = queued; $0.peak = level }
    }
    private func startWhenBuffered() {
        guard let engine, let player else { return }
        if queuedFrames >= Int(Double(engineRate) * targetMs / 1000) { play(player, engine); return }
        guard !startScheduled else { return }
        startScheduled = true
        let expected = generation
        // Wall-clock fallback so short sounds still play even if shorter than the target.
        queue.asyncAfter(deadline: .now() + targetMs / 1000) { [weak self] in
            guard let self, self.generation == expected, !self.primed, self.queuedFrames > 0,
                  let engine = self.engine, let player = self.player else { return }
            self.play(player, engine)
        }
    }
    private func play(_ player: AVAudioPlayerNode, _ engine: AVAudioEngine) {
        // play() raises an Objective-C exception (and kills the app) when the engine is stopped or
        // the player lost its connection, both of which happen while macOS reconfigures the output.
        guard engine.isRunning else { recover("engine stopped before play"); return }
        guard player.engine === engine, !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty else {
            recover("player lost its output connection"); return
        }
        player.play()
        primed = true; startScheduled = false; lastRendered = now
        update { $0.playing = true }
    }
    private func resetPlayback() {
        generation += 1
        player?.stop()
        queuedFrames = 0; primed = false; startScheduled = false; needsRebuffer = false
        trimFrames = 0; lowestQueued = Int.max; stallProbe = nil
        update { $0.queuedFrames = 0; $0.playing = false }
    }
    private func countUnderrun(_ time: TimeInterval) {
        lastUnderrun = time
        targetMs = min(Self.maxTargetMs, targetMs + 20)
        let target = Int(targetMs)
        update { $0.underruns += 1; $0.bufferTargetMs = target }
    }
    private func noteReset(_ reason: String) {
        update { $0.resets += 1 }
        audioLog.notice("buffer reset: \(reason, privacy: .public)")
    }

    // MARK: Engine lifecycle

    private func ensureEngine(rate: Int) -> Bool {
        if let engine, engineRate == rate {
            if engine.isRunning { return true }
            recover("engine stopped")  // macOS stopped it; rebuild after the device settles
        }
        guard now >= retryAt else { return false }
        buildEngine(rate: rate)
        return engine != nil
    }
    private func buildEngine(rate: Int) {
        teardownEngine()
        // A brand-new engine binds to the current default output with its current format.
        // Reusing the old graph after a device change is what left playback stuck.
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = volume
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
            guard let self else { return }
            self.queue.async {
                guard let engine, engine === self.engine else { return }
                self.recover("output device changed")
            }
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine; self.player = player; streamFormat = format; engineRate = rate
            configObserver = observer
            retryDelay = 0.5
            update { $0.engineRunning = true; $0.rate = Double(rate) }
            audioLog.notice("output engine started at \(rate) Hz")
        } catch {
            NotificationCenter.default.removeObserver(observer)
            retryAt = now + retryDelay
            audioLog.error("output engine failed to start: \(error.localizedDescription, privacy: .public), retry in \(self.retryDelay) s")
            retryDelay = min(retryDelay * 2, 5)
            setError("Аудио: \(error.localizedDescription)")
        }
    }
    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        generation += 1
        player?.stop(); engine?.stop()
        engine = nil; player = nil; streamFormat = nil; engineRate = 0
        queuedFrames = 0; primed = false; startScheduled = false; needsRebuffer = false
        trimFrames = 0; lowestQueued = Int.max; stallProbe = nil
        update { $0.engineRunning = false; $0.playing = false; $0.queuedFrames = 0 }
    }
    /// Drops the current engine and builds a fresh one on the next packet. Repeated device
    /// notifications (Bluetooth profile switches come in bursts) only push the rebuild later.
    private func recover(_ reason: String) {
        audioLog.notice("audio recovery: \(reason, privacy: .public)")
        teardownEngine()
        retryAt = max(retryAt, now + 0.3)
        update { $0.recoveries += 1 }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdog = timer
    }
    private func checkHealth() {
        let time = now
        for entry in connections.values where time - entry.seen > 15 { entry.connection.cancel() }
        if let engine {
            if !engine.isRunning {
                recover("engine stopped without notification")
            } else if primed, queuedFrames > 0, time - lastRendered > 0.8 {
                recover("output stopped rendering")
            } else if time - lastPacket > 120 {
                audioLog.notice("idle for 2 minutes, releasing the output device")
                teardownEngine()
            }
        }
        if targetMs > Self.baseTargetMs, time - lastUnderrun > 30 {
            targetMs -= 10; lastUnderrun = time
        }
        // If the buffer never dropped below target + 20 ms during the last half second, the extra
        // is pure delay (a burst at startup, or a sender clock slightly faster than the Mac's).
        if primed, lowestQueued != Int.max, engineRate > 0 {
            let target = Int(Double(engineRate) * targetMs / 1000), slack = engineRate / 50
            if lowestQueued > target + slack { trimFrames = lowestQueued - target }
        }
        lowestQueued = Int.max
        let running = engine?.isRunning ?? false, queued = queuedFrames, target = Int(targetMs)
        update { $0.engineRunning = running; $0.queuedFrames = queued; $0.bufferTargetMs = target }
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
    var volume: Float = 0.5

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        window.title = "AudioBridge \(version) (Mac ↔ Windows)"
        window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        let title = NSTextField(labelWithString: "Звук Windows в наушниках Mac")
        title.font = .systemFont(ofSize: 23, weight: .semibold); root.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Звук Mac и Windows звучит одновременно. Выход: текущее устройство звука macOS.")
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
        toggle = NSButton(title: receiver.stats.enabled ? "Приостановить звук" : "Возобновить звук", target: self, action: #selector(toggleAudio))
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
        let ip = lanIP() ?? config.MacIP
        let audio = receiver.stats
        urlField.stringValue = "http://\(ip):8765/\(config.DownloadToken!)/Windows-Audio.zip"
        let active = ProcessInfo.processInfo.systemUptime - audio.lastSeen < 1.5
        if let error = audio.error { status.stringValue = error; status.textColor = .systemRed }
        else {
            status.stringValue = !audio.enabled ? "Приём звука приостановлен" : active ? "Получаю звук Windows" : "Ожидание звука Windows…"
            status.textColor = active && audio.enabled ? .systemGreen : .labelColor
        }
        var detail = "Пакетов: \(audio.packets)      Пропущено: \(audio.missing)      Буфер: \(Int(Double(audio.queuedFrames) / audio.rate * 1000)) мс"
        if audio.recoveries > 0 { detail += "      Восстановлений звука: \(audio.recoveries)" }
        details.stringValue = detail
        level.doubleValue = active && audio.enabled ? Double(audio.peak * volume) : 0
        if let server {
            updateButton.isEnabled = server.connected && server.pendingId.isEmpty && server.peer?.State != "Downloading" && server.peer?.State != "Restarting"
            if server.connected, let peer = server.peer { windowsStatus.stringValue = "Windows: \(peer.Name), версия \(peer.Version)" }
            else { windowsStatus.stringValue = "Windows: нет соединения с обновлением" }
            updateStatus.stringValue = server.updateNote
        }
        if let serverError = server?.error { address.stringValue = "Не удалось открыть ссылку для Windows: \(serverError)" }
        else if let discoveryError = discovery?.error { address.stringValue = "Автопоиск временно недоступен: \(discoveryError)" }
        else { address.stringValue = "Mac: \(ip)      Автопоиск в сети      Изменение IP обрабатывается автоматически" }
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
            micStatus.stringValue = "Микрофон подключён к Windows через AudioRelay"
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
    @objc func changeVolume(_ sender: NSSlider) { volume = sender.floatValue; receiver.setVolume(volume); volumeText.stringValue = "\(Int(sender.doubleValue * 100))%" }
    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlField.stringValue, forType: .string) }
    @objc func toggleAudio() {
        receiver.setEnabled(!receiver.stats.enabled)
        toggle.title = receiver.stats.enabled ? "Приостановить звук" : "Возобновить звук"; refresh()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--receiver-test") {
    // Headless playback test on the config's port. Feed it with: WindowsAudio --config <same> --test-silence
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let receiver = Receiver(config: config)
    receiver.start()
    func show(_ label: String) {
        let s = receiver.stats
        print("\(label): packets=\(s.packets) running=\(s.engineRunning) playing=\(s.playing) recoveries=\(s.recoveries) resets=\(s.resets) dropped=\(s.dropped) underruns=\(s.underruns) bufferMs=\(Int(Double(s.queuedFrames) / s.rate * 1000))")
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { show("before device change"); receiver.simulate("device-change") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { show("after device change"); receiver.simulate("stall") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { show("after stall"); receiver.simulate("stop") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
        show("after stop")
        let s = receiver.stats
        guard s.packets > 0, s.recoveries >= 3, s.engineRunning, s.playing else { print("FAIL: playback did not recover"); exit(1) }
        print("PASS: playback recovers from a device change, a stalled engine and a silently stopped engine without a restart"); exit(0)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--microphone-control-test") {
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
