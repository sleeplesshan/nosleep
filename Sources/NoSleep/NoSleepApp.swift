import AppKit
import Combine
import SwiftUI
import NoSleepCore

@main
enum NoSleepEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let state = try await MacPowerBackend().readState()
                print("SleepDisabled: \(state == .enabled ? "1" : "0")")
                print("Lid: \(LidReader.read())")
                print("Accessibility: \(DisplayService.accessibilityGranted)")
                print("Previous watcher present: \(LegacyWatcher.exists)")
            } catch { fputs("Sleeplesshan: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        _ = AppTypography.register()
        model = AppModel()
        let content = MainView(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sleeplesshan"
        window.identifier = NSUserInterfaceItemIdentifier("NoSleepMain")
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 480, height: 620)
        window.setContentSize(NSSize(width: 520, height: 760))
        window.center()
        window.setFrameAutosaveName("NoSleepMain")
        window.isReleasedWhenClosed = false
        window.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onStateChange = { [weak self] in self?.updateStatusItem() }
        model.$language.sink { [weak self] _ in Task { @MainActor in self?.updateStatusItem(); self?.buildMainMenu() } }.store(in: &subscriptions)
        buildMainMenu()
        updateStatusItem()
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isBusy == true { model.explainPendingOperation(); showWindow(); return .terminateCancel }
        if model != nil && !model.restoreBrightnessBeforeQuit() { showWindow(); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refresh() }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.refresh()
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Sleeplesshan")
        appMenu.font = AppTypography.nsFont(size: 13)
        appMenu.addItem(withTitle: model.t("About Sleeplesshan", "Sleeplesshan 정보"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: model.t("Hide Sleeplesshan", "Sleeplesshan 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: model.t("Quit Sleeplesshan", "Sleeplesshan 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: model.t("Window", "윈도우"))
        windowMenu.font = AppTypography.nsFont(size: 13)
        windowMenu.addItem(withTitle: model.t("Open Sleeplesshan", "Sleeplesshan 열기"), action: #selector(openFromMenu), keyEquivalent: "0").target = self
        windowMenu.addItem(withTitle: model.t("Close", "닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: model.t("Minimize", "최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func updateStatusItem() {
        let symbol = model.state == .enabled ? "sun.max.fill" : (model.state == .unknown ? "questionmark.circle" : "moon")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sleeplesshan")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = model.t("Sleeplesshan — ", "Sleeplesshan — ") + (model.state == .enabled ? model.t("Sleep prevention on", "잠자기 금지 켜짐") : model.state == .disabled ? model.t("Sleep prevention off", "잠자기 금지 꺼짐") : model.t("State unknown", "상태 확인 불가"))
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { showWindow(); return }
        let menu = NSMenu()
        menu.font = AppTypography.nsFont(size: 13)
        menu.addItem(withTitle: model.t("Open Sleeplesshan", "Sleeplesshan 열기"), action: #selector(openFromMenu), keyEquivalent: "").target = self
        let toggle = menu.addItem(withTitle: model.state == .enabled ? model.t("Turn sleep prevention off", "잠자기 금지 해제") : model.t("Keep Mac awake", "잠자기 금지 켜기"), action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self; toggle.isEnabled = model.state != .unknown && !model.isBusy
        menu.addItem(.separator())
        let display = menu.addItem(withTitle: model.brightnessDimmed ? model.t("Restore brightness", "원래 밝기로 복원") : model.t("Turn display off", "디스플레이 끄기"), action: #selector(displayFromMenu), keyEquivalent: "")
        display.target = self; display.isEnabled = (model.brightnessAvailable || model.brightnessDimmed) && !model.isBusy
        menu.addItem(withTitle: model.t("Lock & turn display off", "잠금 후 디스플레이 끄기"), action: #selector(lockFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("Quit Sleeplesshan", "Sleeplesshan 종료"), action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func openFromMenu() { showWindow() }
    @objc private func toggleFromMenu() { model.toggleSleep() }
    @objc private func displayFromMenu() { model.performDisplayAction(lock: false) }
    @objc private func lockFromMenu() { model.performDisplayAction(lock: true) }
    @objc private func quitFromMenu() { model.quit() }
}
