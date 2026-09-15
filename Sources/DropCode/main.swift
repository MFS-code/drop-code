import AppKit
import ApplicationServices
import GhosttyTerminal
import QuartzCore
import UserNotifications

private let animationDuration: TimeInterval = 0.25
private let holdDelay: TimeInterval = 0.2

private enum SettingsKey {
    static let panelHeightPercentage = "panelHeightPercentage"
    static let panelWidthPercentage = "panelWidthPercentage"
    static let backgroundOpacityPercentage = "backgroundOpacityPercentage"
    static let launchCommand = "launchCommand"
    static let desktopNotificationsEnabled = "desktopNotificationsEnabled"
}

private enum LauncherPreset: String, CaseIterable {
    case openCode = "OpenCode"
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor Agent"
    case custom = "Custom"

    var command: String? {
        switch self {
        case .openCode: "opencode"
        case .codex: "codex"
        case .claude: "claude"
        case .cursor: "agent"
        case .custom: nil
        }
    }

    static func matching(command: String) -> LauncherPreset {
        allCases.first { $0.command == command } ?? .custom
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<ModifierChordMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.receive(type: type, flags: event.flags)
    }
    return Unmanaged.passUnretained(event)
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TerminalContainerView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PanelClipView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DesktopNotificationController: NSObject,
    UNUserNotificationCenterDelegate
{
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .denied:
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "Notifications are disabled for DropCode"
                    alert.informativeText = "Enable DropCode in System Settings > Notifications."
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }

            case .notDetermined:
                self?.center.requestAuthorization(options: [.alert]) { _, error in
                    if let error {
                        NSLog(
                            "DropCode notification authorization failed: %@",
                            String(describing: error)
                        )
                    }
                }

            default:
                break
            }
        }
    }

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "DropCode" : title
        content.body = body
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )) { error in
            if let error {
                NSLog(
                    "DropCode notification delivery failed: %@",
                    String(describing: error)
                )
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        completionHandler([.banner])
    }
}

@MainActor
final class DropPanelController: NSObject {
    private let panel: DropPanel
    private let clipView: PanelClipView
    private let terminalContainer: TerminalContainerView
    private let terminalController: TerminalController
    private lazy var notificationController: DesktopNotificationController? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return DesktopNotificationController()
    }()
    private var terminalView: TerminalView?
    private var previousApplication: NSRunningApplication?
    private var animationGeneration = 0
    private(set) var isVisible = false
    private var isLatched = false
    private var panelHeightRatio: CGFloat
    private var panelWidthRatio: CGFloat
    private var backgroundOpacity: Double
    private var launchCommand: String
    private var desktopNotificationsEnabled: Bool

    override init() {
        let defaults = UserDefaults.standard
        let heightPercentage = defaults.object(
            forKey: SettingsKey.panelHeightPercentage
        ) as? Double ?? 40
        let widthPercentage = defaults.object(
            forKey: SettingsKey.panelWidthPercentage
        ) as? Double ?? 100
        let opacityPercentage = defaults.object(
            forKey: SettingsKey.backgroundOpacityPercentage
        ) as? Double ?? 90
        let configuredLaunchCommand = defaults.string(
            forKey: SettingsKey.launchCommand
        ) ?? "opencode"
        let notificationsEnabled = defaults.object(
            forKey: SettingsKey.desktopNotificationsEnabled
        ) as? Bool ?? false
        let heightRatio = CGFloat(min(max(heightPercentage, 10), 100) / 100)
        let widthRatio = CGFloat(min(max(widthPercentage, 10), 100) / 100)
        let opacity = min(max(opacityPercentage, 0), 100) / 100

        panelHeightRatio = heightRatio
        panelWidthRatio = widthRatio
        backgroundOpacity = opacity
        launchCommand = configuredLaunchCommand
        desktopNotificationsEnabled = notificationsEnabled
        let initialScreen = NSScreen.main ?? NSScreen.screens[0]
        let initialFrame = Self.panelFrame(
            for: initialScreen,
            heightRatio: heightRatio,
            widthRatio: widthRatio
        )
        panel = DropPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        terminalContainer = TerminalContainerView(
            frame: NSRect(origin: .zero, size: initialFrame.size)
        )
        clipView = PanelClipView(
            frame: NSRect(origin: .zero, size: initialFrame.size)
        )

        terminalController = TerminalController(
            configuration: Self.terminalConfiguration,
            theme: TerminalTheme()
        )

        super.init()

        panel.backgroundColor = .clear
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.alphaValue = opacity
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        )
        clipView.autoresizingMask = [.width, .height]
        terminalContainer.autoresizingMask = [.width, .height]
        clipView.addSubview(terminalContainer)
        panel.contentView = clipView

        if notificationsEnabled {
            notificationController?.requestAuthorization()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        rebuildTerminal()
    }

    /// Displays were added, removed, or rearranged (including closing the lid
    /// or unplugging an external monitor). Re-anchor the panel to a screen
    /// that still exists so it never ends up stranded off-screen.
    @objc private func screenParametersDidChange(_ notification: Notification) {
        updatePanelGeometry()
    }

    func toggleLatched() {
        if isVisible {
            isLatched = false
            setVisible(false)
        } else {
            isLatched = true
            setVisible(true)
        }
    }

    func beginMomentary() -> Bool {
        guard !isVisible else { return false }
        isLatched = false
        setVisible(true)
        return isVisible
    }

    func endMomentary(openedByGesture: Bool) {
        guard openedByGesture, isVisible, !isLatched else { return }
        setVisible(false)
    }

    func restartOpenCode() {
        rebuildTerminal()
        if isVisible {
            focusTerminal()
        }
    }

    var panelHeightPercentage: Double {
        Double(panelHeightRatio * 100)
    }

    var panelWidthPercentage: Double {
        Double(panelWidthRatio * 100)
    }

    var backgroundOpacityPercentage: Double {
        backgroundOpacity * 100
    }

    var configuredLaunchCommand: String {
        launchCommand
    }

    var areDesktopNotificationsEnabled: Bool {
        desktopNotificationsEnabled
    }

    func setPanelHeightPercentage(_ percentage: Double) {
        let clamped = min(max(percentage, 10), 100)
        panelHeightRatio = CGFloat(clamped / 100)
        UserDefaults.standard.set(
            clamped,
            forKey: SettingsKey.panelHeightPercentage
        )

        updatePanelGeometry()
    }

    func setPanelWidthPercentage(_ percentage: Double) {
        let clamped = min(max(percentage, 10), 100)
        panelWidthRatio = CGFloat(clamped / 100)
        UserDefaults.standard.set(
            clamped,
            forKey: SettingsKey.panelWidthPercentage
        )
        updatePanelGeometry()
    }

    func setBackgroundOpacityPercentage(_ percentage: Double) {
        let clamped = min(max(percentage, 0), 100)
        backgroundOpacity = clamped / 100
        UserDefaults.standard.set(
            clamped,
            forKey: SettingsKey.backgroundOpacityPercentage
        )
        panel.alphaValue = backgroundOpacity
    }

    func setDesktopNotificationsEnabled(_ enabled: Bool) {
        desktopNotificationsEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: SettingsKey.desktopNotificationsEnabled
        )
        if enabled {
            notificationController?.requestAuthorization()
        }
    }

    @discardableResult
    func setLaunchCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        launchCommand = trimmed
        UserDefaults.standard.set(trimmed, forKey: SettingsKey.launchCommand)
        restartOpenCode()
        return true
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        animationGeneration += 1
        let generation = animationGeneration
        let duration = motionDuration

        if visible {
            let screen = targetScreen
            let frame = Self.panelFrame(
                for: screen,
                heightRatio: panelHeightRatio,
                widthRatio: panelWidthRatio
            )
            previousApplication = NSWorkspace.shared.frontmostApplication
            panel.setFrame(frame, display: false)
            clipView.layoutSubtreeIfNeeded()
            terminalContainer.frame = hiddenContentFrame
            terminalView?.setSurfaceVisible(true)
            panel.orderFrontRegardless()
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)

            animateContent(
                to: clipView.bounds,
                duration: duration,
                entering: true
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.focusTerminal()
            }
        } else {
            animateContent(
                to: hiddenContentFrame,
                duration: duration,
                entering: false
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self,
                      self.animationGeneration == generation,
                      !self.isVisible
                else { return }

                self.panel.orderOut(nil)
                self.terminalView?.setSurfaceVisible(false)
                self.restoreFocusAfterHiding()
            }
        }
    }

    /// Hands focus back to whatever the user was working in. The app that was
    /// frontmost when the panel opened is preferred, but only while it still
    /// has a window on the current Space; activating an app whose windows are
    /// on another desktop makes macOS switch to that desktop, which is
    /// disorienting when the panel was opened on one desktop and dismissed on
    /// another. Otherwise the owner of the topmost visible window is used.
    private func restoreFocusAfterHiding() {
        let previous = previousApplication
        previousApplication = nil

        let onScreenWindows = Self.onScreenApplicationWindows()
        if let previous,
           !previous.isTerminated,
           onScreenWindows.contains(where: { $0.ownerPID == previous.processIdentifier })
        {
            previous.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let topmost = onScreenWindows.first,
           let application = NSRunningApplication(processIdentifier: topmost.ownerPID)
        {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private struct OnScreenWindow {
        let ownerPID: pid_t
        let bounds: CGRect
    }

    /// Normal (layer 0) windows visible on the current Space, front to back,
    /// excluding DropCode's own windows.
    private static func onScreenApplicationWindows() -> [OnScreenWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windowInfo.compactMap { info in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ownPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 1, bounds.height > 1
            else { return nil }
            return OnScreenWindow(ownerPID: ownerPID, bounds: bounds)
        }
    }

    private func animateContent(
        to frame: NSRect,
        duration: TimeInterval,
        entering: Bool
    ) {
        guard duration > 0 else {
            terminalContainer.frame = frame
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                name: entering ? .easeOut : .easeIn
            )
            terminalContainer.animator().frame = frame
        }
    }

    private var hiddenContentFrame: NSRect {
        NSRect(
            x: clipView.bounds.minX,
            y: clipView.bounds.height,
            width: clipView.bounds.width,
            height: clipView.bounds.height
        )
    }

    private func updatePanelGeometry() {
        let screen = panel.screen ?? targetScreen
        let frame = Self.panelFrame(
            for: screen,
            heightRatio: panelHeightRatio,
            widthRatio: panelWidthRatio
        )
        panel.setFrame(frame, display: isVisible)
        clipView.layoutSubtreeIfNeeded()
        terminalContainer.frame = isVisible ? clipView.bounds : hiddenContentFrame
        terminalView?.fitToSize()
    }

    private func rebuildTerminal() {
        terminalView?.removeFromSuperview()

        let terminal = TerminalView(frame: terminalContainer.bounds)
        terminal.autoresizingMask = [.width, .height]
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 14,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            envVars: [
                "PATH": Self.commandPath,
                "SHELL": "/bin/zsh",
            ],
            command: launcherScriptPath(),
            waitAfterCommand: false,
            context: .window,
            resizeThrottleMilliseconds: 16
        )
        terminal.controller = terminalController
        terminalContainer.addSubview(terminal)
        terminalView = terminal

        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            terminal.fitToSize()
            terminal.setSurfaceVisible(self.isVisible)
        }
    }

    private func focusTerminal() {
        guard let terminalView else { return }
        panel.makeFirstResponder(terminalView)
    }

    private var targetScreen: NSScreen {
        let windows = Self.onScreenApplicationWindows()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let referenceWindow = windows.first { $0.ownerPID == frontmostPID }
            ?? windows.first

        if let windowBounds = referenceWindow?.bounds,
           let screen = NSScreen.screens.max(by: {
               Self.intersectionArea(of: $0, with: windowBounds)
                   < Self.intersectionArea(of: $1, with: windowBounds)
           }),
           Self.intersectionArea(of: screen, with: windowBounds) > 0
        {
            return screen
        }

        let mouse = NSEvent.mouseLocation
        return NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens[0]
    }

    private static func intersectionArea(
        of screen: NSScreen,
        with windowBounds: CGRect
    ) -> CGFloat {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey(
            "NSScreenNumber"
        )] as? NSNumber else { return 0 }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let intersection = displayBounds.intersection(windowBounds)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private var motionDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : animationDuration
    }

    private static func panelFrame(
        for screen: NSScreen,
        heightRatio: CGFloat,
        widthRatio: CGFloat
    ) -> NSRect {
        let screenFrame = screen.frame
        let height = max(1, floor(screenFrame.height * heightRatio))
        let width = max(1, floor(screenFrame.width * widthRatio))
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private static var terminalConfiguration: TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontSize(14)
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            builder.withCustom("mouse-hide-while-typing", "true")
            builder.withCustom("scrollbar", "never")
        }
    }

    private static var commandPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        return preferred.joined(separator: ":")
    }

    private func launcherScriptPath() -> String {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("DropCode", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("launch-agent.zsh")
        let escapedCommand = Self.shellQuote(launchCommand)
        let script = """
        #!/bin/zsh
        /bin/zsh -lic \(escapedCommand)
        exit_code=$?
        printf '\\nDropCode command exited (%d). Starting a login shell.\\n' "$exit_code"
        exec /bin/zsh -l
        """

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            NSLog("DropCode failed to write launcher script: %@", String(describing: error))
            return "/bin/zsh"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

extension DropPanelController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceDesktopNotificationDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        panel.title = title
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        guard desktopNotificationsEnabled else { return }
        notificationController?.send(
            title: title.isEmpty ? panel.title : title,
            body: body
        )
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let panelController: DropPanelController
    private let heightValueLabel = NSTextField(labelWithString: "")
    private let widthValueLabel = NSTextField(labelWithString: "")
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let launcherValueLabel = NSTextField(labelWithString: "")

    private lazy var heightSlider = NSSlider(
        value: panelController.panelHeightPercentage,
        minValue: 0,
        maxValue: 100,
        target: self,
        action: #selector(heightChanged)
    )

    private lazy var opacitySlider = NSSlider(
        value: panelController.backgroundOpacityPercentage,
        minValue: 0,
        maxValue: 100,
        target: self,
        action: #selector(opacityChanged)
    )

    private lazy var widthSlider = NSSlider(
        value: panelController.panelWidthPercentage,
        minValue: 0,
        maxValue: 100,
        target: self,
        action: #selector(widthChanged)
    )

    private lazy var notificationsCheckbox = NSButton(
        checkboxWithTitle: "Desktop notifications",
        target: self,
        action: #selector(notificationsChanged)
    )

    private let notificationHelpLabel: NSTextField = {
        let label = NSTextField(
            wrappingLabelWithString: "For OpenCode, enable Attention in OpenCode settings. Alerts appear when DropCode is unfocused."
        )
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var launcherPopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: LauncherPreset.allCases.map(\.rawValue))
        popup.target = self
        popup.action = #selector(launcherPresetChanged)
        return popup
    }()

    private lazy var commandField: NSTextField = {
        let field = NSTextField(string: "")
        field.placeholderString = "Shell command or script path"
        field.target = self
        field.action = #selector(applyLaunchCommand)
        return field
    }()

    private lazy var applyCommandButton: NSButton = {
        let button = NSButton(
            title: "Apply & Restart",
            target: self,
            action: #selector(applyLaunchCommand)
        )
        button.bezelStyle = .rounded
        return button
    }()

    init(panelController: DropPanelController) {
        self.panelController = panelController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let commandRow = NSStackView(views: [commandField, applyCommandButton])
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 8
        commandRow.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let stack = NSStackView(views: [
            settingHeader(title: "Screen height", valueLabel: heightValueLabel),
            heightSlider,
            settingHeader(title: "Screen width", valueLabel: widthValueLabel),
            widthSlider,
            settingHeader(title: "Window opacity", valueLabel: opacityValueLabel),
            opacitySlider,
            notificationsCheckbox,
            notificationHelpLabel,
            settingHeader(title: "Launcher", valueLabel: launcherValueLabel),
            launcherPopup,
            commandRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: heightSlider)
        stack.setCustomSpacing(20, after: widthSlider)
        stack.setCustomSpacing(24, after: opacitySlider)
        stack.setCustomSpacing(24, after: notificationHelpLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        heightSlider.isContinuous = true
        widthSlider.isContinuous = true
        opacitySlider.isContinuous = true
        heightSlider.widthAnchor.constraint(equalToConstant: 320).isActive = true
        widthSlider.widthAnchor.constraint(equalTo: heightSlider.widthAnchor).isActive = true
        opacitySlider.widthAnchor.constraint(equalTo: heightSlider.widthAnchor).isActive = true
        launcherPopup.widthAnchor.constraint(equalTo: heightSlider.widthAnchor).isActive = true
        notificationHelpLabel.widthAnchor.constraint(equalTo: heightSlider.widthAnchor).isActive = true

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])
        view = root
        syncValues()
    }

    func syncValues() {
        guard isViewLoaded else { return }
        heightSlider.doubleValue = panelController.panelHeightPercentage
        widthSlider.doubleValue = panelController.panelWidthPercentage
        opacitySlider.doubleValue = panelController.backgroundOpacityPercentage
        notificationsCheckbox.state = panelController.areDesktopNotificationsEnabled
            ? .on
            : .off
        commandField.stringValue = panelController.configuredLaunchCommand
        let preset = LauncherPreset.matching(
            command: panelController.configuredLaunchCommand
        )
        launcherPopup.selectItem(withTitle: preset.rawValue)
        updateValueLabels()
    }

    @objc private func heightChanged(_ sender: NSSlider) {
        let value = max(10, round(sender.doubleValue))
        sender.doubleValue = value
        panelController.setPanelHeightPercentage(value)
        updateValueLabels()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let value = round(sender.doubleValue)
        sender.doubleValue = value
        panelController.setBackgroundOpacityPercentage(value)
        updateValueLabels()
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        let value = max(10, round(sender.doubleValue))
        sender.doubleValue = value
        panelController.setPanelWidthPercentage(value)
        updateValueLabels()
    }

    @objc private func notificationsChanged(_ sender: NSButton) {
        panelController.setDesktopNotificationsEnabled(sender.state == .on)
    }

    @objc private func launcherPresetChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let preset = LauncherPreset(rawValue: title)
        else { return }

        if let command = preset.command {
            commandField.stringValue = command
        } else {
            view.window?.makeFirstResponder(commandField)
        }
        updateValueLabels()
    }

    @objc private func applyLaunchCommand() {
        guard panelController.setLaunchCommand(commandField.stringValue) else {
            NSSound.beep()
            return
        }
        syncValues()
    }

    private func settingHeader(
        title: String,
        valueLabel: NSTextField
    ) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        let row = NSStackView(views: [titleLabel, spacer, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return row
    }

    private func updateValueLabels() {
        heightValueLabel.stringValue = String(
            format: "%.0f%%",
            heightSlider.doubleValue
        )
        widthValueLabel.stringValue = String(
            format: "%.0f%%",
            widthSlider.doubleValue
        )
        opacityValueLabel.stringValue = String(
            format: "%.0f%%",
            opacitySlider.doubleValue
        )
        launcherValueLabel.stringValue = launcherPopup.titleOfSelectedItem ?? "Custom"
    }
}

@MainActor
final class DropCodeSettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(panelController: DropPanelController) {
        settingsViewController = SettingsViewController(
            panelController: panelController
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 368, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DropCode Settings"
        window.contentViewController = settingsViewController
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2
        )
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        settingsViewController.syncValues()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ModifierChordMonitor {
    private let panelController: DropPanelController
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var holdWorkItem: DispatchWorkItem?
    private var chordIsDown = false
    private var gestureIsValid = false
    private var holdWasTriggered = false
    private var openedForHold = false

    init(panelController: DropPanelController) {
        self.panelController = panelController
    }

    func start() -> Bool {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollKeyboardState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        guard CGPreflightListenEventAccess() else {
            return true
        }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func pollKeyboardState() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        receive(type: .flagsChanged, flags: flags)

        guard chordIsDown else { return }
        let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        let hasOtherKeyDown = (0 ... 127).contains { rawCode in
            let keyCode = CGKeyCode(rawCode)
            return !modifierKeyCodes.contains(keyCode)
                && CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
        if hasOtherKeyDown {
            cancelGesture()
        }
    }

    func receive(type: CGEventType, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        if type == .keyDown {
            if chordIsDown {
                cancelGesture()
            }
            return
        }

        guard type == .flagsChanged else { return }
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        let hasExtraModifier = flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
        let chordIsNowDown = hasControl && hasCommand

        if chordIsNowDown && !chordIsDown {
            chordIsDown = true
            if hasExtraModifier {
                gestureIsValid = false
            } else {
                beginGesture()
            }
        } else if chordIsNowDown && hasExtraModifier {
            cancelGesture()
        } else if !chordIsNowDown && chordIsDown {
            chordIsDown = false
            finishGesture()
        }
    }

    private func beginGesture() {
        gestureIsValid = true
        holdWasTriggered = false
        openedForHold = false

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.chordIsDown, self.gestureIsValid else { return }
            self.holdWasTriggered = true
            self.openedForHold = self.panelController.beginMomentary()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: workItem)
    }

    private func finishGesture() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        guard gestureIsValid else {
            resetGesture()
            return
        }

        if holdWasTriggered {
            panelController.endMomentary(openedByGesture: openedForHold)
        } else {
            panelController.toggleLatched()
        }
        resetGesture()
    }

    private func cancelGesture() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        gestureIsValid = false
        if holdWasTriggered {
            panelController.endMomentary(openedByGesture: openedForHold)
        }
    }

    private func resetGesture() {
        gestureIsValid = false
        holdWasTriggered = false
        openedForHold = false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: DropPanelController?
    private var settingsWindowController: DropCodeSettingsWindowController?
    private var chordMonitor: ModifierChordMonitor?
    private var toggleSignalSource: DispatchSourceSignal?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ryanvogel.dropcode"
        let hasAnotherInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !hasAnotherInstance else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let panelController = DropPanelController()
        self.panelController = panelController
        settingsWindowController = DropCodeSettingsWindowController(
            panelController: panelController
        )
        configureStatusItem()
        configureToggleSignal()

        let monitor = ModifierChordMonitor(panelController: panelController)
        chordMonitor = monitor
        if !monitor.start() {
            requestAccessibilityPermission()
        }
    }

    @objc private func togglePanel() {
        panelController?.toggleLatched()
    }

    @objc private func restartOpenCode() {
        panelController?.restartOpenCode()
    }

    @objc private func showSettings() {
        settingsWindowController?.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "DropCode"
        )

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Toggle DropCode", action: #selector(togglePanel)))
        menu.addItem(menuItem(title: "Restart OpenCode", action: #selector(restartOpenCode)))
        menu.addItem(
            menuItem(
                title: "Settings…",
                action: #selector(showSettings),
                key: ","
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit DropCode", action: #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(
        title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func configureToggleSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.panelController?.toggleLatched()
        }
        source.resume()
        toggleSignalSource = source
    }

    private func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow DropCode to monitor Control+Command"
        alert.informativeText = "Enable DropCode in System Settings > Privacy & Security > Accessibility, then relaunch it. The menu bar item still toggles the panel without this permission."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
