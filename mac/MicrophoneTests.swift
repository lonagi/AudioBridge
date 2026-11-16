import Foundation
import CryptoKit

enum MicrophoneTests {
    static func control(_ key: Data) {
        let hub = MicrophoneHub(pairing: key)
        precondition(!hub.enabled && hub.engine == nil)
        let outputs = [MicOutput(Id: "virtual", Name: "Virtual Mic", InputName: "Virtual Mic for AudioRelay")]
        func report(_ command: MicCommand?, session: String = "test-session", status: String = "", revision: Int? = nil) {
            hub.report(MicReport(Session: session, Outputs: outputs, Command: command, Status: status, Revision: revision), client: "test-client")
        }
        report(MicCommand(Id: "missing-output", Enabled: true, Source: nil, OutputId: nil))
        precondition(hub.enabled && hub.engine == nil && hub.outputId == "virtual")
        hub.change(enabled: false)
        report(MicCommand(Id: "select", Enabled: nil, Source: "builtin", OutputId: "virtual"))
        precondition(!hub.enabled && hub.source == "builtin" && hub.outputId == "virtual")
        report(MicCommand(Id: "enable", Enabled: true, Source: nil, OutputId: nil))
        precondition(hub.enabled && hub.engine == nil) // No capture before an authenticated stream is opened.
        hub.change(enabled: false)
        report(MicCommand(Id: "enable", Enabled: true, Source: nil, OutputId: nil))
        precondition(!hub.enabled) // Repeated commands cannot undo a Mac-side mute.
        hub.change(source: "airpods"); precondition(hub.source == "builtin")
        hub.change(enabled: true); precondition(hub.enabled)
        report(nil, session: "restarted-windows"); precondition(!hub.enabled)
        hub.change(enabled: true); hub.lastSeen -= 10; hub.tick(); precondition(!hub.enabled)
        report(nil); hub.change(enabled: true)
        report(nil, status: "Ошибка: old error", revision: hub.revision - 1); precondition(hub.enabled)
        report(nil, status: "Ошибка: current error", revision: hub.revision); precondition(!hub.enabled)
        let actual = MicHardware.sources()
        precondition(actual.count == 2 && Set(actual.map { $0.Id }) == Set(["hyperx", "builtin"]))
        print("PASS: default off, automatic AudioRelay route, source whitelist, command deduplication, remote restart, lost lease and error revisions")
        print("Microphones: " + actual.map { "\($0.Name)=\($0.Available)" }.joined(separator: ", "))
    }
}
