import AppKit
import Combine
import Foundation
import NoSleepCore
import ServiceManagement

enum AppLanguage: String, CaseIterable { case english, korean }

struct LocalizedMessage {
    let english: String
    let korean: String
    let isError: Bool
    func text(language: AppLanguage) -> String { language == .korean ? korean : english }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: SleepState = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language"); updateDiagnostics() }
    }
    @Published private(set) var lidAction: LidAction
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var accessibilityGranted = false
    @Published var message: LocalizedMessage?
    @Published private(set) var diagnosticText = ""
    @Published private(set) var lidState: LidState = .unknown
    @Published private(set) var legacyWatcherDetected = false
    @Published private(set) var migrationReady = false
    @Published private(set) var migrationBackupPath: String?
    @Published private(set) var brightnessDimmed = false
    @Published private(set) var brightnessAvailable = false

    private let defaults: UserDefaults
    private let controller: PowerController
    private var lidMonitor = LidMonitorState()
    private var timer: Timer?
    private var cycleRunning = false
    private var lastRefresh: TimeInterval = -.infinity
    private var lastVerified: Date?
    private var isChangingLogin = false
    private var brightnessService: BrightnessService?
    private var lastKnownLid: LidState = .unknown
    var onStateChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controller = PowerController(backend: MacPowerBackend())
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:))
            ?? (Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .korean : .english)
        lidAction = defaults.string(forKey: "lidAction").flatMap(LidAction.init(rawValue:)) ?? .none
        do {
            let service = try BrightnessService()
            brightnessService = service
            service.onChange = { [weak self] in self?.updateBrightnessState() }
            service.onError = { [weak self] error in self?.report(error) }
            do { try service.recoverIfNeeded() } catch { report(error) }
            updateBrightnessState()
        } catch { report(error) }
        refreshServices()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.cycle() }
        }
        refresh()
    }

    func t(_ english: String, _ korean: String) -> String { language == .korean ? korean : english }

    func refresh() {
        lastRefresh = -.infinity
        Task { await cycle() }
    }

    private func cycle() async {
        guard !cycleRunning, !isBusy else { return }
        cycleRunning = true
        defer { cycleRunning = false }
        refreshServices()
        let currentLid = LidReader.read()
        let previousLid = lastKnownLid
        let changedLid = currentLid != lidState
        lidState = currentLid
        if currentLid != .unknown { lastKnownLid = currentLid }
        if previousLid == .closed && currentLid == .open && brightnessDimmed {
            do { try brightnessService?.restore() } catch { report(error) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let visible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.title == "Sleeplesshan" }
        if changedLid || now - lastRefresh >= (visible ? 1 : 3) {
            isRefreshing = true
            do {
                let previousState = state
                state = try await controller.readState()
                if state != previousState { message = nil }
                lastVerified = Date()
            } catch {
                // A concurrent setter can claim the actor while this task is awaiting.
                if case PowerControlError.busy = error { isRefreshing = false; return }
                state = .unknown
            }
            isRefreshing = false
            lastRefresh = ProcessInfo.processInfo.systemUptime
            onStateChange?()
        }
        updateDiagnostics()
        brightnessService?.refreshDisplays()
        updateBrightnessState()
        guard !isBusy else { return }
        // No two lid watchers may operate at once. Old watcher is explicitly migrated.
        let effectiveAction: LidAction = legacyWatcherDetected ? .none : lidAction
        if let action = lidMonitor.observe(currentLid, sleepState: state, action: effectiveAction, now: now) {
            await executeDisplay(lock: action == .lockAndDisplayOff, automatic: true)
        }
    }

    func toggleSleep() {
        guard !isBusy, state != .unknown else { return }
        let target = state != .enabled
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false; lastRefresh = -.infinity; onStateChange?(); updateDiagnostics() }
            do {
                // Honor the user's click even if a periodic read was already in flight.
                // Claim isBusy first so the next polling cycle cannot overtake this write.
                while isRefreshing { try await Task.sleep(for: .milliseconds(25)) }
                state = try await controller.setEnabled(target)
                lastVerified = Date()
                message = LocalizedMessage(
                    english: target ? "Sleep prevention is on. Your display can still turn off." : "Forced sleep prevention is off. Other apps and power settings may still keep your Mac awake.",
                    korean: target ? "잠자기 금지가 켜졌습니다. 화면은 끌 수 있습니다." : "강제 잠자기 금지를 해제했습니다. 다른 앱과 전원 설정은 Mac을 계속 깨워 둘 수 있습니다.", isError: false)
            } catch {
                state = await controller.lastObservedState
                report(error)
            }
        }
    }

    func performDisplayAction(lock: Bool) {
        guard !isBusy else { return }
        Task { await executeDisplay(lock: lock) }
    }

    private func executeDisplay(lock: Bool, automatic: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if lock {
                try brightnessService?.restore()
                try await DisplayService.turnOff(lock: true)
            } else {
                guard let brightnessService else { throw MacServiceError.failed("Built-in display brightness control is unavailable.") }
                if brightnessService.isDimmed && !automatic { try brightnessService.restore() }
                else { try brightnessService.dim() }
            }
            lidMonitor.markActionSucceeded(at: ProcessInfo.processInfo.systemUptime)
            message = LocalizedMessage(
                english: lock ? "Lock and display-off requested." : (brightnessDimmed ? "Built-in brightness is zero. Move the pointer or use the brightness-up key to restore." : "Brightness restored."),
                korean: lock ? "잠금과 디스플레이 끄기를 요청했습니다." : (brightnessDimmed ? "내장 디스플레이 밝기를 0으로 낮췄습니다. 마우스를 움직이거나 밝기 증가 키로 복원하세요." : "밝기를 복원했습니다."), isError: false)
        } catch { report(error) }
    }

    func setLidAction(_ action: LidAction) {
        lidAction = action
        defaults.set(action.rawValue, forKey: "lidAction")
        // Reset transition history: enabling while already closed must not trigger.
        lidMonitor = LidMonitorState()
        updateDiagnostics()
    }

    func setLoginEnabled(_ enabled: Bool) {
        guard !isChangingLogin else { return }
        isChangingLogin = true
        Task {
            defer { isChangingLogin = false; refreshServices() }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { report(error) }
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func requestAccessibility() { DisplayService.requestPermission(); refreshServices() }

    private func refreshServices() {
        accessibilityGranted = DisplayService.accessibilityGranted
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        legacyWatcherDetected = LegacyWatcher.exists
        migrationReady = loginEnabled && accessibilityGranted && lidState != .unknown && !isBusy && Bundle.main.bundleURL.pathExtension == "app"
    }

    func migrateLegacyWatcher() {
        guard migrationReady, legacyWatcherDetected, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false; refreshServices() }
            do {
                let backup = try await LegacyWatcher.migrate()
                migrationBackupPath = backup.path
                defaults.set(backup.path, forKey: "migrationBackupPath")
                setLidAction(.lockAndDisplayOff)
                message = LocalizedMessage(english: "The previous lid watcher was backed up and replaced. Sleeplesshan now handles lid closing.", korean: "이전 덮개 감시기를 백업하고 이전했습니다. 이제 Sleeplesshan이 덮개 닫기를 처리합니다.", isError: false)
            } catch { report(error) }
        }
    }

    func copyDiagnostics() {
        updateDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText, forType: .string)
    }

    func quit() { NSApp.terminate(nil) }

    func restoreBrightnessBeforeQuit() -> Bool {
        do { try brightnessService?.restore(); return true }
        catch { report(error); return false }
    }

    private func updateBrightnessState() {
        let wasDimmed = brightnessDimmed
        brightnessDimmed = brightnessService?.isDimmed ?? false
        brightnessAvailable = brightnessService?.available ?? false
        if wasDimmed && !brightnessDimmed {
            message = LocalizedMessage(english: "Brightness restored.", korean: "밝기를 복원했습니다.", isError: false)
        }
    }

    func explainPendingOperation() {
        message = LocalizedMessage(english: "Finish or cancel the current operation before quitting.", korean: "진행 중인 작업을 완료하거나 인증을 취소한 뒤 종료하세요.", isError: true)
    }

    private func updateDiagnostics() {
        let stateText = switch state { case .enabled: "1"; case .disabled: "0"; case .unknown: "unknown" }
        diagnosticText = "Sleeplesshan \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nSleepDisabled: \(stateText)\nLid: \(lidState)\nLid action: \(lidAction.rawValue)\nAccessibility: \(accessibilityGranted)\nLogin: \(loginEnabled)\nPrevious watcher: \(legacyWatcherDetected)\nLast read: \(lastVerified?.ISO8601Format() ?? "—")"
    }

    private func report(_ error: Error) {
        let detail = error.localizedDescription
        if detail.contains("cancelled") || detail.contains("(-128)") {
            message = LocalizedMessage(english: "Authentication cancelled. The current system state is shown.", korean: "인증을 취소했습니다. 현재 시스템 상태를 표시합니다.", isError: false)
        } else if case MacServiceError.permissionRequired = error {
            message = LocalizedMessage(english: "Allow Sleeplesshan in Privacy & Security → Accessibility to request screen locking. Display-only remains available.", korean: "화면 잠금을 사용하려면 개인정보 보호 및 보안 → 손쉬운 사용에서 Sleeplesshan을 허용하세요. 화면만 끄기는 바로 사용할 수 있습니다.", isError: true)
        } else {
            message = LocalizedMessage(english: "The action could not be verified. Check permissions and try again.\n\(detail.prefix(240))", korean: "동작을 확인하지 못했습니다. 권한을 확인하고 다시 시도하세요.\n\(detail.prefix(240))", isError: true)
        }
    }
}
