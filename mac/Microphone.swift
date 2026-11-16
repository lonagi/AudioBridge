import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import CryptoKit
import Network

struct MicSource: Codable { let Id: String; let Name: String; let Available: Bool }
struct MicOutput: Codable { let Id: String; let Name: String; var InputName: String? = nil }
struct MicCommand: Codable { let Id: String; let Enabled: Bool?; let Source: String?; let OutputId: String? }
struct MicTelemetry: Codable { let Input: String; let IsDefault: Bool; let InputPeak: Float; let InputFrames: Int64; let ReceivedFrames: Int64; let DefaultsStatus: String }
struct MicReport: Codable {
    let Session: String; let Outputs: [MicOutput]; let Command: MicCommand?; let Status: String; let Revision: Int?
    var Telemetry: MicTelemetry? = nil
}
struct MicSnapshot: Codable {
    let Enabled: Bool; let Source: String; let OutputId: String; let Sources: [MicSource]
    let Status: String; let CommandId: String; let Revision: Int
}
struct MicDevice { let id: AudioDeviceID; let source: MicSource }

enum MicHardware {
    static func devices() -> [MicDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        var result: [MicDevice] = []
        for id in devices {
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameRef: Unmanaged<CFString>?; var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeRetainedValue() else { continue }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize: UInt32 = 4
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            let lower = (name as String).lowercased()
            let sourceId: String
            if lower.contains("hyperx") || lower.contains("quadcast") { sourceId = "hyperx" }
            else if transport == kAudioDeviceTransportTypeBuiltIn { sourceId = "builtin" }
            else { continue }
            if !result.contains(where: { $0.source.Id == sourceId }) {
                result.append(MicDevice(id: id, source: MicSource(Id: sourceId, Name: sourceId == "builtin" ? "Микрофон MacBook Pro" : name as String, Available: true)))
            }
        }
        return result
    }
    static func sources() -> [MicSource] {
        let actual = devices()
        return [("hyperx", "HyperX QuadCast S"), ("builtin", "Микрофон MacBook Pro")].map { id, name in
            actual.first(where: { $0.source.Id == id })?.source ?? MicSource(Id: id, Name: name + " (не подключён)", Available: false)
        }
    }
}

enum MicPacket {
    static func key(_ pairing: Data, stream: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: pairing + Data("AudioBridge microphone v1\n\(stream)".utf8)))
    }
    static func encode(_ pcm: Data, rate: UInt32, sequence: UInt64, key: SymmetricKey) throws -> Data {
        var header = Data("ABM1".utf8)
        var seq = sequence.littleEndian, hz = rate.littleEndian
        withUnsafeBytes(of: &seq) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &hz) { header.append(contentsOf: $0) }
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + header[4..<12])
        let sealed = try AES.GCM.seal(pcm, using: key, nonce: nonce, authenticating: header)
        let payload = header + sealed.ciphertext + sealed.tag
        var length = UInt16(payload.count).littleEndian
        var frame = Data(); withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }; frame.append(payload)
        return frame
    }
}

// Main-thread state. Microphone buffers are copied from the audio callback; no samples are saved to disk.
final class MicrophoneHub {
    let pairing: Data
    var enabled = false
    var source = "hyperx"
    var outputId = ""
    var outputs: [MicOutput] = []
    var telemetry: MicTelemetry?
    var windowsMicStatus = ""
    var status = "Микрофон выключен"
    var commandId = ""
    var revision = 0
    var session = ""
    var clientId = ""
    var lastSeen: TimeInterval = 0
    var connection: NWConnection?
    var engine: AVAudioEngine?
    var captureObserver: NSObjectProtocol?
    var captureFormat: AVAudioFormat?
    var captureRetries = 0
    var restartTimes: [TimeInterval] = []
    var lastTapBuffer: TimeInterval = 0
    var streamKey: SymmetricKey?
    var sequence: UInt64 = 0
    var generation = 0
    var inFlight = 0
    var peak: Float = 0
    var sources = MicHardware.sources()
    var lastHardwareCheck: TimeInterval = 0
    var permissionPending = false
    var syntheticTest = false
    var connected: Bool { !session.isEmpty && ProcessInfo.processInfo.systemUptime - lastSeen < 6 }
    init(pairing: Data) { self.pairing = pairing }
    func snapshot() -> MicSnapshot { MicSnapshot(Enabled: enabled, Source: source, OutputId: outputId, Sources: sources, Status: status, CommandId: commandId, Revision: revision) }
    func report(_ report: MicReport, client: String) {
        let newSession = session != report.Session || clientId != client
        if newSession {
            disable("Микрофон выключен"); session = report.Session; clientId = client; commandId = ""
        }
        lastSeen = ProcessInfo.processInfo.systemUptime
        telemetry = report.Telemetry; windowsMicStatus = report.Status
        outputs = report.Outputs.filter { ($0.InputName ?? "").contains("Virtual Mic for AudioRelay") }
        let automatic = outputs.first?.Id ?? ""
        if outputId != automatic {
            outputId = automatic; stopStream(); revision += 1
            if automatic.isEmpty && enabled { disable("Микрофон AudioRelay недоступен в Windows.") }
        }
        if let command = report.Command, command.Id != commandId {
            commandId = command.Id
            change(enabled: command.Enabled, source: command.Source)
        }
        if enabled, report.Revision == revision, report.Status.hasPrefix("Ошибка:") { disable(report.Status) }
    }
    func change(enabled requested: Bool? = nil, source nextSource: String? = nil) {
        if let nextSource {
            guard ["hyperx", "builtin"].contains(nextSource) else { return }
            if source != nextSource { source = nextSource; stopStream(); revision += 1 }
        }
        if requested == false { disable("Микрофон выключен"); return }
        if requested == true || enabled {
            guard connected else { disable("Сначала подключите Windows с поддержкой микрофона."); return }
            guard sources.contains(where: { $0.Id == source && $0.Available }) else { disable("Выбранный микрофон не подключён."); return }
            guard outputs.contains(where: { $0.Id == outputId }) else { disable("Не найден Virtual Mic for AudioRelay. Нужен AudioBridge 0.4.2 на Windows."); return }
            enabled = true; revision += 1
            status = "Подключение микрофона…"
        }
    }
    func disable(_ message: String) { enabled = false; revision += 1; status = message; stopStream() }
    func stopStream() {
        generation += 1
        stopCaptureEngine()
        connection?.cancel(); connection = nil; streamKey = nil; inFlight = 0; peak = 0
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHardwareCheck > 2 {
            sources = MicHardware.sources(); lastHardwareCheck = now
            if enabled && !sources.contains(where: { $0.Id == source && $0.Available }) { disable("Микрофон отключён от Mac. Выберите источник заново.") }
        }
        if enabled && !connected { disable("Связь с Windows потеряна, микрофон выключен.") }
        // Backstop in case macOS stopped the capture without a notification.
        if enabled, connection != nil, let engine, captureObserver != nil {
            if !engine.isRunning { restartCapture(generation) }
            // Running but silent: the device changed under the tap without stopping the engine.
            else if now - lastTapBuffer > 2 { restartCapture(generation, force: true) }
        }
        peak *= 0.85
    }
    func openStream(_ connection: NWConnection, stream: String) {
        stopStream(); self.connection = connection
        streamKey = MicPacket.key(pairing, stream: stream); sequence = 0; captureRetries = 0
        let expected = generation
        if syntheticTest {
            send(Data(repeating: 0, count: 960), rate: 48000, peak: 0, expected: expected)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startCapture(expected)
        case .notDetermined:
            status = "Разрешите AudioBridge доступ к микрофону на Mac."
            guard !permissionPending else { return }
            permissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in DispatchQueue.main.async {
                guard let self else { return }; self.permissionPending = false
                guard self.enabled, self.connected, self.connection != nil else { return }
                if granted { self.startCapture(self.generation) } else { self.disable("Нет разрешения на микрофон. Разрешите AudioBridge в настройках macOS.") }
            } }
        default: disable("Нет разрешения на микрофон. Разрешите AudioBridge в настройках macOS.")
        }
    }
    func stopCaptureEngine() {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        captureObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        captureFormat = nil
    }
    /// The input device changed under a running capture (headphones, Bluetooth profile, another app
    /// taking the device). Rebuild only the capture engine; the stream to Windows stays open.
    func restartCapture(_ expected: Int, force: Bool = false) {
        guard generation == expected, let engine else { return }
        // Same device, same format: just start the engine again. That sets no device, so it does
        // not trigger another configuration change.
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        if !force, let captureFormat, hardware.sampleRate == captureFormat.sampleRate, hardware.channelCount == captureFormat.channelCount {
            if (try? engine.start()) != nil, engine.isRunning { return }
        }
        let now = ProcessInfo.processInfo.systemUptime
        restartTimes = restartTimes.filter { now - $0 < 30 } + [now]
        guard restartTimes.count <= 6 else {
            restartTimes.removeAll(); disable("Микрофон Mac постоянно переключается. Включите его снова."); return
        }
        stopCaptureEngine()
        status = "Восстанавливаю микрофон после смены устройства…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startCapture(expected) }
    }
    func retryCapture(_ expected: Int, _ reason: String) {
        captureRetries += 1
        guard captureRetries <= 10 else { disable("Ошибка микрофона: \(reason)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startCapture(expected) }
    }
    func startCapture(_ expected: Int) {
        guard enabled, connected, generation == expected, connection != nil, engine == nil else { return }
        guard let device = MicHardware.devices().first(where: { $0.source.Id == source }) else {
            retryCapture(expected, "выбранный микрофон не найден"); return
        }
        do {
            let capture = AVAudioEngine()
            let input = capture.inputNode
            guard let unit = input.audioUnit else { throw NSError(domain: "Не удалось открыть микрофон", code: 1) }
            // AVAudioEngine may hand out an initialized AUHAL. Device changes require it stopped/uninitialized.
            _ = AudioOutputUnitStop(unit)
            let uninitialize = AudioUnitUninitialize(unit)
            guard uninitialize == noErr else { throw NSError(domain: "Не удалось подготовить микрофон", code: Int(uninitialize)) }
            var id = device.id
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw NSError(domain: "Не удалось выбрать микрофон", code: Int(result)) }
            // Tap at the selected device's own format. outputFormat(forBus:) still describes the macOS
            // default input after the device switch above, and tapping with it raised the
            // "format mismatch" exception that crashed the app whenever the two rates differed.
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.channelCount > 0, (8000...192000).contains(hardware.sampleRate),
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: hardware.channelCount, interleaved: false) else {
                retryCapture(expected, "формат устройства меняется"); return
            }
            input.installTap(onBus: 0, bufferSize: 480, format: format) { [weak self] buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
                var pcm = Data(count: frames * 2); var peak: Float = 0
                pcm.withUnsafeMutableBytes { raw in
                    let values = raw.bindMemory(to: Int16.self)
                    for f in 0..<frames {
                        var value: Float = 0
                        for c in 0..<count { value += channels[c][f * buffer.stride] }
                        value /= Float(count); value = value.isFinite ? max(-1, min(1, value)) : 0
                        peak = max(peak, abs(value)); values[f] = Int16(value * 32767).littleEndian
                    }
                }
                let rate = UInt32(buffer.format.sampleRate)
                DispatchQueue.main.async { self?.send(pcm, rate: rate, peak: peak, expected: expected) }
            }
            engine = capture; captureFormat = format
            captureObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: capture, queue: .main) { [weak self, weak capture] _ in
                // Selecting the device above makes AVAudioEngine post this once while it keeps running.
                // A real hand-off stops the engine first, so only react to that.
                guard let self, let capture, capture === self.engine, !capture.isRunning else { return }
                self.restartCapture(expected)
            }
            capture.prepare(); try capture.start()
            captureRetries = 0; lastTapBuffer = ProcessInfo.processInfo.systemUptime
            status = "Передаю: \(device.source.Name) → Windows"
        } catch {
            stopCaptureEngine()
            retryCapture(expected, error.localizedDescription)
        }
    }
    func send(_ pcm: Data, rate: UInt32, peak: Float, expected: Int) {
        guard enabled, connected, expected == generation, let connection, let key = streamKey else { return }
        lastTapBuffer = ProcessInfo.processInfo.systemUptime
        self.peak = max(self.peak, peak)
        for offset in stride(from: 0, to: pcm.count, by: 960) {
            guard inFlight < 24, sequence < UInt64.max else {
                stopStream(); status = "Восстанавливаю передачу микрофона…"; return
            }
            do {
                let part = Data(pcm[offset..<min(offset + 960, pcm.count)])
                let frame = try MicPacket.encode(part, rate: rate, sequence: sequence, key: key); sequence += 1
                let chunk = Data(String(frame.count, radix: 16).utf8) + Data("\r\n".utf8) + frame + Data("\r\n".utf8)
                inFlight += 1
                connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                    guard let self, self.generation == expected else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    if error != nil { self.stopStream(); self.status = "Восстанавливаю передачу микрофона…" }
                })
            } catch { disable("Ошибка шифрования микрофона"); return }
        }
    }
}
