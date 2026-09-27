import AppKit
import Foundation

/// Uses Apple's recipient picker. A completed report is written only after
/// NSSharingService acknowledges sharing; opening the picker is not delivery.
final class Sender: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    let file: URL
    let report: URL
    var service: NSSharingService?

    init(file: URL, report: URL) { self.file = file; self.report = report }

    func status(_ state: String, error: String? = nil) {
        var record: [String: String] = ["state": state, "fileName": file.lastPathComponent]
        if let error { record["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: file.path),
              let share = NSSharingService(named: .sendViaAirDrop), share.canPerform(withItems: [file]) else {
            status("unavailable", error: "AirDrop service or delivery file unavailable")
            NSApp.terminate(nil)
            return
        }
        service = share
        share.delegate = self
        status("awaiting_recipient")
        NSApp.activate(ignoringOtherApps: true)
        share.perform(withItems: [file])
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        status("sending")
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        status("shared")
        NSApp.terminate(nil)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        status("failed", error: error.localizedDescription)
        NSApp.terminate(nil)
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: AirDropSender <file> <report.json>\n", stderr)
    exit(2)
}
let sender = Sender(file: URL(fileURLWithPath: CommandLine.arguments[1]),
                    report: URL(fileURLWithPath: CommandLine.arguments[2]))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = sender
app.run()
