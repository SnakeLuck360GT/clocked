import CoreImage.CIFilterBuiltins
import SwiftUI

/// Step-by-step setup for the iPhone link: turn it on, optional Study Focus, scan a code to get the shortcuts
/// (with your links filled in), make two automations, then a live test.
struct PhoneLinkWizard: View {
    @ObservedObject var link: PhoneLink
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.intro
    @State private var testStartedAt = Date.distantFuture

    enum Step: Int, CaseIterable { case intro, focus, iphone, test }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.track).frame(height: 4)
                }
            }
            .padding(.bottom, Theme.Space.xl)

            Group {
                switch step {
                case .intro: intro
                case .focus: focus
                case .iphone: iphone
                case .test: test
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step == .intro { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                else { Button("Back") { step = Step(rawValue: step.rawValue - 1)! } }
                Spacer()
                switch step {
                case .intro:
                    Button("Turn On") {
                        settings.phoneLink = true
                        link.start()
                        step = .focus
                    }
                    .keyboardShortcut(.defaultAction)
                case .test:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                default:
                    Button("Continue") {
                        step = Step(rawValue: step.rawValue + 1)!
                        if step == .test { testStartedAt = Date() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, Theme.Space.l)
        }
        .padding(28)
        .frame(width: 560, height: 440)
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Catch your phone the moment you open it").font(.title2.weight(.semibold))
            Text("Your iPhone can tell Clocked when you open Instagram, TikTok or any app you pick, so the clock stops straight away. No guessing from your posture.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                point("wifi", "Works over your Wi-Fi. Nothing goes over the internet.")
                point("key", "Only messages with your own pairing key are accepted.")
                point("lock.shield", "A separate helper receives them. It can't use the camera, mic or your files.")
                point("timer", "Messages only count during a session.")
            }
            .padding(.top, Theme.Space.s)
        }
    }

    private var focus: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Study Focus (optional)").font(.title2.weight(.semibold))
            Text("Clocked can turn on a Study Focus when a session starts and off when it ends. Your iPhone follows, so the shortcuts can stay quiet the rest of the time.")
                .foregroundStyle(.secondary)
            Toggle("Turn on the Study Focus during sessions", isOn: $settings.runShortcuts)
            if settings.runShortcuts {
                VStack(alignment: .leading, spacing: 6) {
                    numbered(1, "In System Settings → Focus, add a Focus called Study and turn on Share Across Devices.")
                    numbered(2, "In Shortcuts on this Mac, make “Study Start” (Set Focus: Study, On) and “Study End” (Set Focus: Study, Off).")
                }
                .font(.callout)
                HStack {
                    Button("Open Focus Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                    }
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                }
            }
        }
    }

    private var iphone: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Scan this with your iPhone").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                if let qr = Self.qrCode(setupURL) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 170, height: 170)
                        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 8) {
                    numbered(1, "Open the Camera on your iPhone and point it at the code.")
                    numbered(2, "Tap the link that appears. The page walks you through adding two shortcuts and two automations, one step at a time, and copies your links for you.")
                    numbered(3, "Come back here when it says “Try it”.")
                }
                .font(.callout)
            }
            Text("Your links are in the code itself, and the page never sends them anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Try it").font(.title2.weight(.semibold))
            Text("Open one of your apps on your iPhone now. Your iPhone and this Mac need to be on the same Wi-Fi.")
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.m) {
                if let last = link.lastMessage, last.at >= testStartedAt {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("It works").font(.headline)
                        Text("Clocked heard “app \(last.event)” from your iPhone.").foregroundStyle(.secondary)
                    }
                } else if case .failed(let message) = link.state {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("The link couldn't start").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.large)
                    Text("Waiting for your iPhone…").foregroundStyle(.secondary)
                }
            }
            .padding(.top, Theme.Space.m)
        }
    }

    // MARK: - Pieces

    /// The setup page with your links in the part after #, which browsers never send to the server.
    private var setupURL: String {
        "https://snakeluck360gt.github.io/clocked/iphone/#host=\(link.hostName)&port=\(LinkPolicy.port)&key=\(settings.phoneLinkKey)"
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22) }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func qrCode(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
