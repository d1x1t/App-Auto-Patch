// AAPMenuBar.swift
// App Auto-Patch – macOS menu bar companion app
//
// Compile (requires Xcode Command Line Tools):
//   xcrun swiftc -framework Cocoa -framework SwiftUI -o AAPMenuBar AAPMenuBar.swift
//
// Installed to: /Library/Management/AppAutoPatch/AAPMenuBar
// Runs as:      logged-in user via LaunchAgent xyz.techitout.aap.menubar

import Cocoa
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: – State model
// ---------------------------------------------------------------------------

struct AAPState: Codable {
    // Possible status values:
    //   "idle"                 – no pending updates; icon hidden
    //   "pending_updates"      – updates discovered, awaiting user decision
    //   "hard_deadline"        – max deferrals exceeded; install will start automatically
    //   "patching_in_progress" – Installomator is running
    //   "up_to_date"           – patching complete or nothing to do; icon hidden
    var status: String
    var pendingUpdateCount: Int
    var pendingApps: [String]
    var lastPatchedDate: String?
    var nextRunDate: String?
    var stateUpdatedEpoch: TimeInterval?   // unix timestamp when this state was written
    var countdownSeconds: Int?             // DialogTimeoutDeferral at time of hard_deadline
}

// ---------------------------------------------------------------------------
// MARK: – Observable state model
// ---------------------------------------------------------------------------

class AAPStateModel: ObservableObject {
    // Paths – must match the constants written by App-Auto-Patch-via-Dialog.zsh
    let stateFilePath = "/Library/Management/AppAutoPatch/menubar-state.json"
    let cmdFilePath   = "/var/tmp/aap-menubar.cmd"

    @Published var state: AAPState = AAPState(
        status: "idle",
        pendingUpdateCount: 0,
        pendingApps: [],
        lastPatchedDate: nil,
        nextRunDate: nil,
        stateUpdatedEpoch: nil,
        countdownSeconds: nil
    )

    func reload() {
        guard
            let data  = FileManager.default.contents(atPath: stateFilePath),
            let loaded = try? JSONDecoder().decode(AAPState.self, from: data)
        else { return }
        DispatchQueue.main.async { self.state = loaded }
    }

    func writeCommand(_ cmd: String) {
        try? cmd.write(toFile: cmdFilePath, atomically: true, encoding: .utf8)
    }
}

// ---------------------------------------------------------------------------
// MARK: – SwiftUI Popover view
// ---------------------------------------------------------------------------

struct AAPPopoverView: View {
    @ObservedObject var appState: AAPStateModel
    // Dismiss callback so buttons can close the popover
    var onDismiss: () -> Void

    @State private var secondsRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            if !appState.state.pendingApps.isEmpty {
                appListSection
            }
            Divider().padding(.vertical, 8)
            actionSection
            Divider().padding(.vertical, 8)
            footerSection
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            appState.reload()
            startCountdownIfNeeded()
        }
        .onDisappear {
            stopCountdown()
        }
    }

    // ── Header ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(headerIconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.bottom, 10)
    }

    private var headerIconName: String {
        switch appState.state.status {
        case "hard_deadline":        return "exclamationmark.circle.fill"
        case "patching_in_progress": return "gearshape.fill"
        case "up_to_date":           return "checkmark.circle.fill"
        default:                     return "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var headerIconColor: Color {
        switch appState.state.status {
        case "hard_deadline":        return .red
        case "patching_in_progress": return .blue
        case "up_to_date":           return .green
        default:                     return .orange
        }
    }

    private var headerTitle: String {
        let count = appState.state.pendingUpdateCount
        switch appState.state.status {
        case "hard_deadline":
            return "\(count) update\(count == 1 ? "" : "s") will install soon"
        case "patching_in_progress":
            return "Patching in progress…"
        case "up_to_date":
            return "All apps are up to date"
        default:
            return "\(count) app update\(count == 1 ? "" : "s") available"
        }
    }

    private var headerSubtitle: String {
        switch appState.state.status {
        case "hard_deadline":
            return "Maximum deferrals reached"
        case "patching_in_progress":
            return "Please don't restart your Mac"
        default:
            return ""
        }
    }

    // ── App list ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private var appListSection: some View {
        let apps = appState.state.pendingApps
        VStack(alignment: .leading, spacing: 4) {
            let displayed = Array(apps.prefix(8))
            let overflow  = apps.count - displayed.count
            FlowLayout(spacing: 6) {
                ForEach(displayed, id: \.self) { app in
                    Text(app)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                }
            }
            if overflow > 0 {
                Text("… and \(overflow) more")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 4)
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var actionSection: some View {
        switch appState.state.status {
        case "hard_deadline":
            hardDeadlineActions
        case "patching_in_progress":
            patchingActions
        default:
            normalActions
        }
    }

    @ViewBuilder
    private var normalActions: some View {
        // Prominent "Update Now" button
        Button(action: {
            appState.writeCommand("install_now")
            onDismiss()
        }) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update Now")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProminentGreenButtonStyle())
        .padding(.bottom, 8)

        // Secondary defer buttons side-by-side
        HStack(spacing: 8) {
            Text("Defer:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("1 Hour") {
                appState.writeCommand("defer:60")
                onDismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Until Tomorrow") {
                appState.writeCommand("defer:1440")
                onDismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var hardDeadlineActions: some View {
        // Countdown label
        if secondsRemaining > 0 {
            HStack {
                Image(systemName: "timer")
                    .foregroundColor(.red)
                Text("Installing in \(formattedCountdown)…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                Spacer()
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Image(systemName: "timer")
                    .foregroundColor(.red)
                Text("Installing now…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                Spacer()
            }
            .padding(.vertical, 4)
        }
        Text("No deferrals remaining. Installation will begin automatically.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var patchingActions: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
                .padding(.trailing, 4)
            Text("Installation in progress…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastPatched = appState.state.lastPatchedDate, !lastPatched.isEmpty {
                footerRow(label: "Last patched:", value: lastPatched)
            }
            if let nextRun = appState.state.nextRunDate, !nextRun.isEmpty {
                footerRow(label: "Next run:", value: nextRun)
            }
        }
    }

    private func footerRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
    }

    // ── Countdown logic ───────────────────────────────────────────────────────

    private var formattedCountdown: String {
        let m = secondsRemaining / 60
        let s = secondsRemaining % 60
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        } else {
            return "\(s)s"
        }
    }

    private func startCountdownIfNeeded() {
        stopCountdown()
        guard appState.state.status == "hard_deadline",
              let epoch = appState.state.stateUpdatedEpoch,
              let total = appState.state.countdownSeconds else { return }

        let deadline = epoch + Double(total)
        let now = Date().timeIntervalSince1970
        let remaining = Int(deadline - now)
        secondsRemaining = max(remaining, 0)

        guard secondsRemaining > 0 else { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                if self.secondsRemaining > 0 {
                    self.secondsRemaining -= 1
                } else {
                    self.stopCountdown()
                }
            }
        }
        if let timer = countdownTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}

// ---------------------------------------------------------------------------
// MARK: – Button styles
// ---------------------------------------------------------------------------

struct ProminentGreenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Color.green.opacity(0.8) : Color.green)
            .cornerRadius(8)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.primary)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(configuration.isPressed
                ? Color(NSColor.controlBackgroundColor).opacity(0.7)
                : Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
    }
}

// ---------------------------------------------------------------------------
// MARK: – Flow layout (wrapping chip row for app names)
// ---------------------------------------------------------------------------

/// A simple left-to-right wrapping layout for the app name chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 268
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: – AppDelegate
// ---------------------------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var pollTimer: Timer?
    var lastStateMtime: Date?

    let appStateModel = AAPStateModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = false

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: AAPPopoverView(appState: appStateModel, onDismiss: { [weak self] in
                self?.closePopover()
            })
        )

        // Load state and start polling
        appStateModel.reload()
        updateIcon()
        startPolling()

        // Observe state changes to update icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange),
            name: NSNotification.Name("AAPStateChanged"),
            object: nil
        )
    }

    // ---------------------------------------------------------------------------
    // MARK: – Polling
    // ---------------------------------------------------------------------------

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollIfChanged()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func pollIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: appStateModel.stateFilePath)
        let mtime = attrs?[.modificationDate] as? Date
        if mtime != lastStateMtime {
            lastStateMtime = mtime
            appStateModel.reload()
            DispatchQueue.main.async { self.updateIcon() }
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: – Icon update
    // ---------------------------------------------------------------------------

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = appStateModel.state

        switch state.status {

        case "pending_updates":
            let cfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.orange]))
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill",
                                accessibilityDescription: "App updates available")
            button.image         = image?.withSymbolConfiguration(cfg)
            button.imagePosition = .imageLeading
            button.title         = state.pendingUpdateCount > 0 ? " \(state.pendingUpdateCount)" : ""
            statusItem.isVisible = true

        case "hard_deadline":
            let cfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.red]))
            let image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                accessibilityDescription: "Install required")
            button.image         = image?.withSymbolConfiguration(cfg)
            button.imagePosition = .imageLeading
            button.title         = " Install required"
            statusItem.isVisible = true

        case "patching_in_progress":
            let cfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            let image = NSImage(systemSymbolName: "gearshape.fill",
                                accessibilityDescription: "Patching in progress")
            button.image         = image?.withSymbolConfiguration(cfg)
            button.imagePosition = .imageLeading
            button.title         = " Patching…"
            statusItem.isVisible = true

        default:
            // "idle" or "up_to_date" – hide the icon
            statusItem.isVisible = false
            if popover.isShown { closePopover() }
        }
    }

    @objc func stateDidChange() {
        updateIcon()
    }

    // ---------------------------------------------------------------------------
    // MARK: – Popover toggle
    // ---------------------------------------------------------------------------

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        // Re-read state on open (onAppear in SwiftUI also does this, belt-and-suspenders)
        appStateModel.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        popover.performClose(nil)
    }
}

// ---------------------------------------------------------------------------
// MARK: – Entry point
// ---------------------------------------------------------------------------

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
