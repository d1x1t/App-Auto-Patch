// AAPMenuBar.swift
// App Auto-Patch – macOS menu bar companion app
//
// Compile (requires Xcode Command Line Tools):
//   swiftc -o AAPMenuBar AAPMenuBar.swift
//
// Installed to: /Library/Management/AppAutoPatch/AAPMenuBar
// Runs as:      logged-in user via LaunchAgent xyz.techitout.aap.menubar

import Cocoa
import Foundation

// ---------------------------------------------------------------------------
// MARK: – State model
// ---------------------------------------------------------------------------

struct AAPState: Codable {
    var status: String           // "idle" | "pending_updates" | "patching_in_progress" | "up_to_date"
    var pendingUpdateCount: Int
    var pendingApps: [String]
    var lastPatchedDate: String?
    var nextRunDate: String?
}

// ---------------------------------------------------------------------------
// MARK: – AppDelegate
// ---------------------------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate {

    // Paths – must match the constants written by App-Auto-Patch-via-Dialog.zsh
    let stateFilePath = "/Library/Management/AppAutoPatch/menubar-state.json"
    let cmdFilePath   = "/var/tmp/aap-menubar.cmd"

    var statusItem: NSStatusItem!
    var pollTimer: Timer?

    // Track the last mtime of the state file so we only rebuild the menu when
    // something actually changed.
    var lastStateMtime: Date?

    // ---------------------------------------------------------------------------
    // MARK: – Launch
    // ---------------------------------------------------------------------------

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = false

        loadAndRefreshUI()
        startPolling()
    }

    // ---------------------------------------------------------------------------
    // MARK: – Polling
    // ---------------------------------------------------------------------------

    func startPolling() {
        // Poll every 15 s; cheap enough and resilient to file replacement.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollIfChanged()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func pollIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateFilePath)
        let mtime = attrs?[.modificationDate] as? Date
        if mtime != lastStateMtime {
            lastStateMtime = mtime
            loadAndRefreshUI()
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: – State loading
    // ---------------------------------------------------------------------------

    func loadAndRefreshUI() {
        guard
            let data  = FileManager.default.contents(atPath: stateFilePath),
            let state = try? JSONDecoder().decode(AAPState.self, from: data)
        else {
            // State file not yet written – hide icon and wait.
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.isVisible = false
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyState(state)
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: – UI update
    // ---------------------------------------------------------------------------

    func applyState(_ state: AAPState) {
        guard let button = statusItem.button else { return }

        switch state.status {

        case "pending_updates":
            let cfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill",
                                accessibilityDescription: "App updates available")
            button.image         = image?.withSymbolConfiguration(cfg)
            button.imagePosition = .imageLeading
            button.title         = state.pendingUpdateCount > 0 ? " \(state.pendingUpdateCount)" : ""
            statusItem.isVisible = true
            rebuildMenu(state: state)

        case "patching_in_progress":
            let cfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let image = NSImage(systemSymbolName: "gearshape.fill",
                                accessibilityDescription: "Patching in progress")
            button.image         = image?.withSymbolConfiguration(cfg)
            button.imagePosition = .imageLeading
            button.title         = " Patching…"
            statusItem.isVisible = true
            rebuildMenu(state: state)

        default:
            // "idle" or "up_to_date" – hide the icon
            statusItem.isVisible = false
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: – Menu construction
    // ---------------------------------------------------------------------------

    func rebuildMenu(state: AAPState) {
        let menu = NSMenu()

        switch state.status {

        case "pending_updates":
            // ── header ──
            let count = state.pendingUpdateCount
            let header = NSMenuItem(
                title: "\(count) app update\(count == 1 ? "" : "s") available",
                action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            // ── app list (up to 6) ──
            for app in state.pendingApps.prefix(6) {
                let item = NSMenuItem(title: "  • \(app)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if state.pendingApps.count > 6 {
                let more = NSMenuItem(
                    title: "  … and \(state.pendingApps.count - 6) more",
                    action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }

            menu.addItem(.separator())

            // ── actions ──
            let installItem = NSMenuItem(
                title: "Update Now", action: #selector(handleInstallNow), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)

            menu.addItem(.separator())

            let defer1h = NSMenuItem(
                title: "Defer 1 Hour", action: #selector(handleDefer1Hour), keyEquivalent: "")
            defer1h.target = self
            menu.addItem(defer1h)

            let deferDay = NSMenuItem(
                title: "Defer Until Tomorrow", action: #selector(handleDeferTomorrow), keyEquivalent: "")
            deferDay.target = self
            menu.addItem(deferDay)

        case "patching_in_progress":
            let item = NSMenuItem(title: "Patching in progress…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        default:
            let item = NSMenuItem(title: "All apps are up to date", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // ── footer ──
        if let lastPatched = state.lastPatchedDate {
            menu.addItem(.separator())
            let lp = NSMenuItem(title: "Last patched: \(lastPatched)", action: nil, keyEquivalent: "")
            lp.isEnabled = false
            menu.addItem(lp)
        }
        if let nextRun = state.nextRunDate {
            let nr = NSMenuItem(title: "Next run: \(nextRun)", action: nil, keyEquivalent: "")
            nr.isEnabled = false
            menu.addItem(nr)
        }

        statusItem.menu = menu
    }

    // ---------------------------------------------------------------------------
    // MARK: – Command writing
    // ---------------------------------------------------------------------------

    func writeCommand(_ cmd: String) {
        do {
            try cmd.write(toFile: cmdFilePath, atomically: true, encoding: .utf8)
        } catch {
            // If the write fails (e.g. permissions), nothing happens – the AAP
            // script will time out and use its default deferral action.
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: – Menu actions
    // ---------------------------------------------------------------------------

    @objc func handleInstallNow() {
        writeCommand("install_now")
        statusItem.isVisible = false
    }

    @objc func handleDefer1Hour() {
        writeCommand("defer:60")
        statusItem.isVisible = false
    }

    @objc func handleDeferTomorrow() {
        writeCommand("defer:1440")
        statusItem.isVisible = false
    }
}

// ---------------------------------------------------------------------------
// MARK: – Entry point
// ---------------------------------------------------------------------------

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
