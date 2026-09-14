import AppKit
import CoreAudio
import UserNotifications


struct Configuration: Decodable {
    let preferredInput: String
    let aliases: [String: String]
}
let configuration: Configuration = {
    guard let url = Bundle.main.url(forResource: "config", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let value = try? JSONDecoder().decode(Configuration.self, from: data),
          !value.preferredInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("无法读取 Resources/config.json，请检查配置后重新构建。\n", stderr)
        exit(1)
    }
    return value
}()
let preferredInput = configuration.preferredInput

struct Input: Equatable {
    let uid: String
    let name: String
    var label: String { name }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func currentInput() -> Input? {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr else { return nil }
    if device == kAudioObjectUnknown { return Input(uid: "none", name: "无可用输入") }
    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
    guard let name = string(kAudioObjectPropertyName), let uid = string(kAudioDevicePropertyDeviceUID) else { return nil }
    return Input(uid: uid, name: name)
}

let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MicInputGuard")
let configURL = configDirectory.appendingPathComponent("fixed-input.json")
func isFixed() -> Bool {
    guard let data = try? Data(contentsOf: configURL), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return false }
    return obj["fixed"] == true
}
func setFixed(_ fixed: Bool) throws {
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["fixed": fixed]).write(to: configURL, options: .atomic)
}
func audio(_ arguments: [String]) -> String {
    let task = Process();
    let candidates = ["/opt/homebrew/bin/SwitchAudioSource", "/usr/local/bin/SwitchAudioSource"]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return "执行失败：请先安装 switchaudio-osx（SwitchAudioSource）"
    }
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
    do { try task.run() } catch { return "执行失败：\(error.localizedDescription)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
let args = CommandLine.arguments
if args.count > 1 {
    if args[1] == "--help" {
        print("Usage: MicInputGuard --status | --list | --select <preferred|alias|device name>")
        exit(0)
    }
    if args[1] == "--list" { print(audio(["-a", "-t", "input"])); exit(0) }

    if args[1] == "--status" {
        print("当前输入：\(currentInput()?.label ?? "无法读取")｜\(isFixed() ? "首选麦克风 已固定" : "未固定")")
        print("无需切换时，按 Esc 关闭。")
        exit(0)
    }
    if args[1] == "--select", args.count == 3 {
        let name = args[2] == "preferred" ? preferredInput : (configuration.aliases[args[2]] ?? args[2])
        let result = audio(["-t", "input", "-s", name])
        guard currentInput()?.name == name else {
            fputs("切换失败：\(result)\n", stderr); exit(1)
        }
        print(result)
        do { try setFixed(name == preferredInput) } catch { fputs("无法保存固定状态\n", stderr); exit(1) }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.MicInputGuard.changed"), object: nil, deliverImmediately: true)
        // Ensure the service is running even if it was manually quit.
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path]; try? open.run()
        exit(0)
    }
    exit(2)
}

final class Monitor: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    let center = UNUserNotificationCenter.current()
    var item: NSStatusItem!
    var previous: Input?
    var pending: DispatchWorkItem?
    var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var timer: Timer?
    var problem = ""
    var attempts = 0
    var corrections = 0
    var auth = "checking"
    var latest = ""
    var notice = ""
    var delivered = ""
    var listenerError = ""
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MicInputGuard")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one instance may observe or notify, including manual reopen.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 {
            NSApp.terminate(nil); return
        }
        center.delegate = self
        previous = currentInput()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "麦克风提醒")
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        updateMenu()
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
            let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
            if result == noErr { listeners.append((a, block)) }
            else { listenerError += "监听失败：\(result) " }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error { self?.notice = error.localizedDescription }
                self?.refreshAuthorization()
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: ["input-change"])
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(wake), name: Notification.Name("local.MicInputGuard.changed"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.settle() }
        settle()
    }
    @objc func wake() { schedule() }
    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    func settle() {
        guard let next = currentInput() else { return }
        defer { previous = currentInput(); updateMenu(); saveStatus() }
        if let old = previous, old.uid != next.uid { latest = "\(old.label) → \(next.label)" }
        guard isFixed() else { attempts = 0; problem = ""; return }
        if next.name == preferredInput { attempts = 0; problem = ""; return }
        let available = audio(["-a", "-t", "input"]).components(separatedBy: "\n")
        guard available.contains(preferredInput) else {
            if problem != "disconnected" { send(title: "首选麦克风 已断开", body: "暂用其他输入；首选麦克风 重新连接后会自动恢复固定。") }
            problem = "disconnected"; attempts = 0; return
        }
        _ = audio(["-t", "input", "-s", preferredInput])
        if currentInput()?.name == preferredInput {
            corrections += 1; attempts = 0; problem = ""
        } else {
            attempts += 1
            if attempts >= 3 && problem != "failed" {
                problem = "failed"; send(title: "无法恢复 首选麦克风 输入", body: "请检查 首选麦克风 连接；程序会继续重试。")
            }
        }
    }
    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        // One identifier replaces stale banners rather than accumulating a history.
        center.add(UNNotificationRequest(identifier: "input-change", content: content, trigger: nil)) { [weak self] error in
            DispatchQueue.main.async {
                self?.notice = error.map { "发送失败：\($0.localizedDescription)" } ?? "已提交：\(body)"
                self?.saveStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.center.getDeliveredNotifications { notifications in
                        DispatchQueue.main.async {
                            self?.delivered = notifications.first(where: { $0.request.identifier == "input-change" })?.request.content.body ?? ""
                            self?.saveStatus()
                        }
                    }
                }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.auth = settings.authorizationStatus == .authorized ? "allowed" : (settings.authorizationStatus == .denied ? "denied" : "notDetermined")
                self?.updateMenu(); self?.saveStatus()
            }
        }
    }
    func menuWillOpen(_ menu: NSMenu) { refreshAuthorization(); updateMenu() }
    func updateMenu() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        let name = currentInput()?.label ?? "无法读取"
        item.button?.toolTip = "当前输入：\(name) · \(isFixed() ? "首选麦克风 已固定" : "未固定")"
        let heading = NSMenuItem(title: "当前输入：\(name)", action: nil, keyEquivalent: ""); menu.addItem(heading)
        if !listenerError.isEmpty { menu.addItem(NSMenuItem(title: listenerError, action: nil, keyEquivalent: "")) }
        if auth == "denied" { menu.addItem(NSMenuItem(title: "通知未获允许，请在系统设置中开启", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        add(isFixed() ? "解除 首选麦克风 固定" : "开启 首选麦克风 固定", #selector(toggle))
        add("打开通知设置", #selector(settings))
        menu.addItem(.separator())
        add("退出", #selector(quit))
    }
    func add(_ title: String, _ action: Selector) { let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; item.menu?.addItem(entry) }
    @objc func toggle() {
        do { try setFixed(!isFixed()) } catch { send(title: "无法保存固定状态", body: error.localizedDescription); return }
        pending?.cancel(); settle()
    }
    @objc func testNotice() { send(title: "麦克风提醒 · 测试", body: "当前输入：\(currentInput()?.label ?? "无法读取")") }
    @objc func settings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func saveStatus() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state: [String: Any] = ["current": currentInput()?.label ?? "unknown", "fixedInput": isFixed(), "problem": problem, "corrections": corrections, "authorization": auth, "lastChange": latest, "notification": notice, "delivered": delivered, "listenerCount": listeners.count, "error": listenerError, "updated": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Monitor()
app.delegate = delegate
app.run()
