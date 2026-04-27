import AppKit
import Darwin
import Foundation

private enum HelperBridge {
    static let commandNotification = Notification.Name("com.yly02.applemusiclyricsoverlay.helper.command")
    static let snapshotNotification = Notification.Name("com.yly02.applemusiclyricsoverlay.helper.snapshot")
    static let quitHelperNotification = Notification.Name("com.yly02.applemusiclyricsoverlay.helper.quit")

    static let commandKey = "command"
    static let trackTitleKey = "trackTitle"
    static let trackArtistKey = "trackArtist"
    static let translationEnabledKey = "translationEnabled"
    static let positionLockedKey = "positionLocked"

    enum Command: String {
        case requestSnapshot
        case showOverlay
        case togglePositionLock
        case toggleTranslation
        case openTranslationSettings
        case quitMainApp
    }
}

private enum HelperInstanceLock {
    private static let lockFileName = "com.yly02.applemusiclyricsoverlay.helper.lock"

    static func acquire() -> Int32? {
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(lockFileName)
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return nil
        }

        return descriptor
    }
}

private struct HelperState {
    var trackTitle = "Apple Music Lyrics"
    var trackArtist = "未在播放"
    var translationEnabled = true
    var positionLocked = false
}

@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var trackItem: NSMenuItem?
    private var artistItem: NSMenuItem?
    private var positionLockItem: NSMenuItem?
    private var translationItem: NSMenuItem?
    private var state = HelperState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSnapshot(_:)),
            name: HelperBridge.snapshotNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleQuitHelper),
            name: HelperBridge.quitHelperNotification,
            object: nil
        )

        configureStatusItem()
        requestSnapshot()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Apple Music Lyrics") {
                let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                button.image = symbol.withSymbolConfiguration(configuration)
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "歌词"
                button.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            }
            button.toolTip = "Apple Music Lyrics"
        }

        let menu = NSMenu()

        let trackItem = NSMenuItem(title: state.trackTitle, action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)

        let artistItem = NSMenuItem(title: state.trackArtist, action: nil, keyEquivalent: "")
        artistItem.isEnabled = false
        menu.addItem(artistItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "打开歌词窗口", action: #selector(showOverlay), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let positionLockItem = NSMenuItem(title: "固定歌词位置", action: #selector(togglePositionLock), keyEquivalent: "")
        positionLockItem.target = self
        menu.addItem(positionLockItem)

        let translationItem = NSMenuItem(title: "显示翻译", action: #selector(toggleTranslation), keyEquivalent: "")
        translationItem.target = self
        menu.addItem(translationItem)

        let translationSettingsItem = NSMenuItem(title: "翻译设置…", action: #selector(openTranslationSettings), keyEquivalent: "")
        translationSettingsItem.target = self
        menu.addItem(translationSettingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitMainApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
        self.trackItem = trackItem
        self.artistItem = artistItem
        self.positionLockItem = positionLockItem
        self.translationItem = translationItem
        applyState()
    }

    private func requestSnapshot() {
        postCommand(.requestSnapshot)
    }

    private func postCommand(_ command: HelperBridge.Command) {
        DistributedNotificationCenter.default().post(
            name: HelperBridge.commandNotification,
            object: nil,
            userInfo: [HelperBridge.commandKey: command.rawValue]
        )
    }

    private func applyState() {
        trackItem?.title = state.trackTitle
        artistItem?.title = state.trackArtist
        artistItem?.isHidden = state.trackArtist.isEmpty
        positionLockItem?.state = state.positionLocked ? .on : .off
        translationItem?.state = state.translationEnabled ? .on : .off
    }

    @objc
    private func handleSnapshot(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        if let title = userInfo[HelperBridge.trackTitleKey] as? String, !title.isEmpty {
            state.trackTitle = title
        }
        if let artist = userInfo[HelperBridge.trackArtistKey] as? String {
            state.trackArtist = artist
        }
        if let translationEnabled = userInfo[HelperBridge.translationEnabledKey] as? Bool {
            state.translationEnabled = translationEnabled
        }
        if let positionLocked = userInfo[HelperBridge.positionLockedKey] as? Bool {
            state.positionLocked = positionLocked
        }
        applyState()
    }

    @objc
    private func handleQuitHelper() {
        NSApp.terminate(nil)
    }

    @objc
    private func showOverlay() {
        postCommand(.showOverlay)
    }

    @objc
    private func togglePositionLock() {
        postCommand(.togglePositionLock)
    }

    @objc
    private func toggleTranslation() {
        postCommand(.toggleTranslation)
    }

    @objc
    private func openTranslationSettings() {
        postCommand(.openTranslationSettings)
    }

    @objc
    private func quitMainApp() {
        postCommand(.quitMainApp)
    }
}

@MainActor
@main
struct LyricsMenuBarHelperMain {
    private static let instanceLock = HelperInstanceLock.acquire()
    private static let delegate = HelperDelegate()

    static func main() {
        guard instanceLock != nil else {
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
