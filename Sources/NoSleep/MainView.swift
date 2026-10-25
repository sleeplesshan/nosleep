import SwiftUI
import NoSleepCore

/// A compact control surface. The model remains the sole owner of power state.
struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetails = false

    private var paper: Color {
        colorScheme == .dark
            ? Color(red: 0.115, green: 0.12, blue: 0.115)
            : Color(red: 0.965, green: 0.958, blue: 0.94)
    }

    private var ink: Color {
        colorScheme == .dark
            ? Color(red: 0.92, green: 0.92, blue: 0.89)
            : Color(red: 0.18, green: 0.20, blue: 0.19)
    }

    private var green: Color {
        colorScheme == .dark
            ? Color(red: 0.43, green: 0.73, blue: 0.55)
            : Color(red: 0.22, green: 0.47, blue: 0.32)
    }

    private var isEnabled: Bool {
        if case .enabled = model.state { return true }
        return false
    }

    private var isUnknown: Bool {
        if case .unknown = model.state { return true }
        return false
    }

    private var stateText: String {
        switch model.state {
        case .enabled: return model.t("On · Display can still sleep", "켜짐 · 디스플레이는 끌 수 있습니다")
        case .disabled: return model.t("Off · Sleep prevention is released", "꺼짐 · 잠자기 금지가 해제되었습니다")
        case .unknown: return model.t("Unable to confirm current state", "현재 상태를 확인할 수 없습니다")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                rule.padding(.top, 24)
                sleepControl.padding(.vertical, 23)
                lidContext.padding(.bottom, 22)
                rule
                displayActions.padding(.vertical, 20)
                if let message = model.message {
                    feedback(message)
                        .padding(.bottom, 18)
                }
                rule
                settings
                rule
                footer.padding(.top, 16)
                details.padding(.top, 12)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(paper)
        .foregroundStyle(ink)
        .tint(green)
        .font(AppTypography.font(size: 13))
        .frame(minWidth: 480, idealWidth: 520, minHeight: 680, idealHeight: 760)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(model.t("POWER, AT YOUR PACE", "내 작업에 맞춘 전원 설정"))
                .font(AppTypography.font(size: 10, weight: .medium))
                .tracking(model.language == .english ? 1.8 : 0.6)
                .foregroundStyle(.secondary)
            Text(model.t("Power, under control.", "잠자기를 내 뜻대로."))
                .font(AppTypography.font(size: 29))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }

    private var sleepControl: some View {
        HStack(alignment: .center, spacing: 13) {
            Circle()
                .fill(isUnknown ? Color.orange : (isEnabled ? green : ink.opacity(0.25)))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.t("Keep Mac awake", "Mac 잠자기 금지"))
                    .font(AppTypography.font(size: 21, weight: .semibold))
                    .tracking(-0.5)
                Text(model.isBusy ? model.t("Applying change…", "설정 적용 중…") : stateText)
                    .font(AppTypography.font(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.t("Applying power setting", "전원 설정 적용 중"))
            }
            if isUnknown {
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshing || model.isBusy)
                .help(model.t("Check current state", "현재 상태 다시 확인"))
                .accessibilityLabel(model.t("Check current state", "현재 상태 다시 확인"))
            } else {
                Toggle(model.t("Keep Mac awake", "Mac 잠자기 금지"), isOn: Binding(
                    get: { isEnabled },
                    set: { requested in
                        if requested != isEnabled { model.toggleSleep() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(model.isBusy)
                .accessibilityValue(isEnabled ? model.t("On", "켜짐") : model.t("Off", "꺼짐"))
            }
        }
    }

    private var lidContext: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 35, weight: .ultraLight))
                .foregroundStyle(ink.opacity(0.65))
                .frame(width: 55)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(isUnknown
                     ? model.t("Check the current power setting.", "현재 전원 설정을 확인하세요.")
                     : (isEnabled
                        ? model.t("Close the lid. Keep things running.", "덮개를 닫아도, 작업은 계속.")
                        : model.t("Other power settings still apply.", "다른 전원 설정은 그대로 적용됩니다.")))
                    .font(AppTypography.font(size: 13, weight: .medium))
                Text(lidContextDetail)
                    .font(AppTypography.font(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var lidContextDetail: String {
        if isUnknown {
            return model.t("Refresh to confirm whether sleep is prevented.", "새로 고침으로 잠자기 금지 상태를 확인하세요.")
        }
        if !isEnabled {
            return model.t("Other apps may still keep your Mac awake.", "다른 앱이 Mac의 잠자기를 막고 있을 수 있습니다.")
        }
        if model.legacyWatcherDetected {
            return model.t(
                "Existing lid automation is configured. Move it to Sleeplesshan to use the action below.",
                "기존 덮개 자동화가 설정되어 있습니다. Sleeplesshan으로 이전하면 아래 동작이 적용됩니다."
            )
        }
        switch model.lidAction {
        case .none:
            return model.t(
                "Choose a lid action below to turn the display off automatically.",
                "화면도 자동으로 끄려면 아래에서 덮개 동작을 선택하세요."
            )
        case .displayOff:
            return model.t(
                "Closing the lid sets the built-in display to brightness 0. Your work continues.",
                "덮개를 닫으면 내장 화면 밝기를 0으로 낮춥니다. 작업은 계속합니다."
            )
        case .lockAndDisplayOff:
            return model.t(
                "Closing the lid requests a lock and turns the display off. Work continues.",
                "덮개를 닫으면 잠금을 요청하고 화면을 끕니다. 작업은 계속합니다."
            )
        }
    }

    private var displayActions: some View {
        VStack(spacing: 9) {
            VStack(spacing: 7) {
                Button { model.performDisplayAction(lock: false) } label: {
                    actionLabel(
                        model.brightnessDimmed
                            ? model.t("Restore brightness", "원래 밝기로 복원")
                            : model.t("Turn display off", "디스플레이 끄기"),
                        symbol: model.brightnessDimmed ? "sun.max" : "sun.min"
                    )
                }
                .disabled(!model.brightnessAvailable && !model.brightnessDimmed)
                Text(brightnessCaption)
                    .font(AppTypography.font(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            Button { model.performDisplayAction(lock: true) } label: {
                actionLabel(model.t("Lock & turn display off", "잠금 후 디스플레이 끄기"), symbol: "lock")
            }
            if !model.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                    Text(model.t("Locking needs Accessibility access.", "화면 잠금에는 손쉬운 사용 권한이 필요합니다."))
                    Spacer(minLength: 0)
                    Button(model.t("Set up", "설정"), action: model.requestAccessibility)
                        .buttonStyle(.link)
                        .disabled(model.isBusy)
                }
                .font(AppTypography.font(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            }
        }
        .buttonStyle(InstrumentButtonStyle(ink: ink))
        .disabled(model.isBusy)
    }

    private var brightnessCaption: String {
        guard model.brightnessAvailable else {
            return model.t(
                "Brightness control unavailable on this display.",
                "이 화면에서는 밝기를 조절할 수 없습니다."
            )
        }
        if model.accessibilityGranted {
            return model.t(
                "Sets built-in display brightness to 0. Move the pointer or press a key to restore.",
                "내장 화면 밝기를 0으로 낮춥니다. 마우스 이동이나 키 입력으로 복원합니다."
            )
        }
        return model.t(
            "Sets built-in display brightness to 0. Move the pointer to restore, or use the brightness-up key (F2).",
            "내장 화면 밝기를 0으로 낮춥니다. 마우스를 움직여 복원하거나 밝기 높이기 키(F2)를 사용하세요."
        )
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title).font(AppTypography.font(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 43)
        .contentShape(Rectangle())
    }

    private var settings: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(model.t("When lid closes", "덮개를 닫으면"))
                    Spacer(minLength: 4)
                    Picker(model.t("When lid closes", "덮개를 닫으면"), selection: Binding(
                        get: { model.lidAction }, set: { model.setLidAction($0) }
                    )) {
                        Text(model.t("Do nothing", "아무 동작 안 함")).tag(LidAction.none)
                        Text(model.t("Turn display off", "디스플레이 끄기"))
                            .tag(LidAction.displayOff)
                            .disabled(!model.brightnessAvailable)
                        Text(model.t("Lock & turn display off", "잠금 후 디스플레이 끄기")).tag(LidAction.lockAndDisplayOff)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 227)
                    .disabled(model.isBusy || model.legacyWatcherDetected)
                }
                if model.legacyWatcherDetected {
                    HStack(spacing: 8) {
                        Text(model.t("Existing lid automation detected.", "기존 덮개 자동화가 감지되었습니다."))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(model.t("Manage", "관리")) { showsDetails = true }
                            .buttonStyle(.link)
                    }
                    .font(AppTypography.font(size: 10))
                }
            }
            .padding(.vertical, 15)
            rule
            VStack(spacing: 8) {
                Toggle(model.t("Launch at login", "로그인 시 실행"), isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.isBusy)
                if model.loginNeedsApproval {
                    HStack {
                        Text(model.t("Enable Sleeplesshan in Login Items.", "로그인 항목에서 Sleeplesshan을 허용하세요."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.t("Open Settings", "설정 열기"), action: model.openLoginSettings)
                            .buttonStyle(.link)
                    }
                    .font(AppTypography.font(size: 10))
                }
            }
            .padding(.vertical, 13)
            rule
            HStack(spacing: 12) {
                Text(model.t("Language", "언어"))
                Spacer()
                Picker(model.t("Language", "언어"), selection: $model.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .padding(.vertical, 14)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(model.t("Your sleep-prevention setting persists when you quit.", "잠자기 금지 설정은 앱을 종료해도 유지됩니다."))
                .font(AppTypography.font(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: model.refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing || model.isBusy)
            .help(model.t("Refresh status", "상태 새로 고침"))
            .accessibilityLabel(model.t("Refresh status", "상태 새로 고침"))
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.t(
                    "Sleep prevention is a system setting and survives quitting. Sleeplesshan’s lid automation only runs while the app is running.",
                    "잠자기 금지는 시스템 설정으로, 앱을 종료해도 유지됩니다. Sleeplesshan의 덮개 자동화는 앱이 실행 중일 때만 동작합니다."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(model.t("Lid", "덮개"))
                    Spacer()
                    Text(lidStateText).foregroundStyle(.secondary)
                }
                if model.legacyWatcherDetected {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.t("An existing lid automation is configured.", "기존 덮개 자동화가 설정되어 있습니다."))
                        Text(model.t("Move it to Sleeplesshan to manage lid actions here.", "Sleeplesshan으로 이전하면 여기에서 덮개 동작을 관리할 수 있습니다."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(model.t("Move lid automation to Sleeplesshan", "덮개 자동화를 Sleeplesshan으로 이전"), action: model.migrateLegacyWatcher)
                            .disabled(model.isBusy || !model.migrationReady)
                        if !model.migrationReady {
                            Text(model.t(
                                "To move it, enable Launch at login, allow Accessibility access, and confirm the lid state.",
                                "이전하려면 로그인 시 실행을 켜고, 손쉬운 사용 권한을 허용한 뒤 덮개 상태가 확인되어야 합니다."
                            ))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(model.diagnosticText)
                    .font(AppTypography.font(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.t("Copy diagnostics", "진단 정보 복사"), action: model.copyDiagnostics)
                    Spacer()
                    Button(model.t("Quit Sleeplesshan", "Sleeplesshan 종료"), action: model.quit)
                }
            }
            .font(AppTypography.font(size: 11))
            .padding(.top, 12)
            .padding(.bottom, 3)
        } label: {
            Text(model.t("Details & diagnostics", "상세 정보 및 진단"))
                .font(AppTypography.font(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var lidStateText: String {
        switch model.lidState {
        case .open: return model.t("Open", "열림")
        case .closed: return model.t("Closed", "닫힘")
        case .unknown: return model.t("Unknown", "확인 불가")
        }
    }

    private func feedback(_ message: LocalizedMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.isError ? "exclamationmark.circle" : "checkmark.circle")
                .accessibilityHidden(true)
            Text(message.text(language: model.language))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(AppTypography.font(size: 11))
        .foregroundStyle(message.isError ? Color.orange : green)
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle().fill(ink.opacity(0.13)).frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct InstrumentButtonStyle: ButtonStyle {
    var ink: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink.opacity(isEnabled ? 1 : 0.38))
            .background(ink.opacity(configuration.isPressed ? 0.075 : 0.015))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ink.opacity(configuration.isPressed ? 0.38 : 0.22), lineWidth: 1)
            }
    }
}
