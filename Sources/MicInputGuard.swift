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

struct Input: Equatable, Codable {
    let uid: String
    let name: String
    var label: String { name }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func deviceInput(_ device: AudioDeviceID) -> Input? {
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
func currentInput() -> Input? {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
    return deviceInput(device)
}
func inputDevices() -> [(AudioDeviceID, Input)] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = address(kAudioDevicePropertyStreams)
        streams.mScope = kAudioDevicePropertyScopeInput
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0, let input = deviceInput(id) else { return nil }
        return (id, input)
    }
}
let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MicInputGuard")
let configURL = configDirectory.appendingPathComponent("fixed-input.json")
struct FixedState: Codable { var target: Input? }
func fixedInput() -> Input? {
    if let data = try? Data(contentsOf: configURL), let state = try? JSONDecoder().decode(FixedState.self, from: data) { return state.target }
    // Migrate the previous boolean lock to the configured preferred device.
    if let data = try? Data(contentsOf: configURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Bool], state["fixed"] == true {
        return inputDevices().first { $0.1.name == preferredInput }?.1 ?? Input(uid: "legacy-preferred", name: preferredInput)
    }
    return nil
}
func isFixed() -> Bool { fixedInput() != nil }
func setFixed(_ target: Input?) throws {
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(FixedState(target: target)).write(to: configURL, options: .atomic)
}
func matches(_ input: Input, _ target: Input) -> Bool {
    input.uid == target.uid || (target.uid == "legacy-preferred" && input.name == target.name)
}
func switchInput(_ target: Input) -> Bool {
    guard let device = inputDevices().first(where: { matches($0.1, target) }) else { return false }
    var id = device.0
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
}
func selectInput(_ target: Input) throws -> Bool {
    guard inputDevices().contains(where: { matches($0.1, target) }) else { return false }
    let previousLock = fixedInput()
    try setFixed(nil)
    guard switchInput(target) else { try setFixed(previousLock); return false }
    return true
}
let args = CommandLine.arguments
if args.count > 1 {
    if args[1] == "--help" {
        print("Usage: MicInputGuard --status | --list | --select <preferred|alias|device name> | --fix-current | --unfix")
        exit(0)
    }
    if args[1] == "--list" { print(inputDevices().map { $0.1.name }.joined(separator: "\n")); exit(0) }

    if args[1] == "--fix-current" || args[1] == "--unfix" {
        if args[1] == "--fix-current" && currentInput() == nil { exit(1) }
        do { try setFixed(args[1] == "--fix-current" ? currentInput() : nil) } catch { exit(1) }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.MicInputGuard.changed"), object: nil, deliverImmediately: true)
        exit(0)
    }

    if args[1] == "--status" {
        print("当前输入：\(currentInput()?.label ?? "无法读取")｜\(isFixed() ? "已固定：\(fixedInput()!.label)" : "未固定")")
        print("无需切换时，按 Esc 关闭。")
        exit(0)
    }
    if args[1] == "--select", args.count == 3 {
        let name = args[2] == "preferred" ? preferredInput : (configuration.aliases[args[2]] ?? args[2])
        guard let target = inputDevices().first(where: { $0.1.name == name })?.1 else { fputs("设备未连接\n", stderr); exit(1) }
        do { guard try selectInput(target) else { exit(1) } } catch { fputs("无法切换输入\n", stderr); exit(1) }
        print("当前输入：\(target.label)")
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
    var menuOpen = false
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
        guard let target = fixedInput() else { attempts = 0; problem = ""; return }
        if matches(next, target) { attempts = 0; problem = ""; return }
        guard inputDevices().contains(where: { matches($0.1, target) }) else {
            if problem != "disconnected" { send(title: "\(target.label) 已断开", body: "暂用其他输入；设备重新连接后会自动恢复固定。") }
            problem = "disconnected"; attempts = 0; return
        }
        if switchInput(target), let current = currentInput(), matches(current, target) {
            corrections += 1; attempts = 0; problem = ""
        } else {
            attempts += 1
            if attempts >= 3 && problem != "failed" {
                problem = "failed"; send(title: "无法恢复 \(target.label) 输入", body: "请检查设备连接；程序会继续重试。")
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
    func menuWillOpen(_ menu: NSMenu) { updateMenu(); menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func updateMenu() {
        guard !menuOpen, let menu = item?.menu else { return }
        menu.removeAllItems()
        let name = currentInput()?.label ?? "无法读取"
        item.button?.toolTip = "当前输入：\(name) · \(isFixed() ? "已固定：\(fixedInput()!.label)" : "未固定")"
        let heading = NSMenuItem(title: "当前输入：\(name)", action: nil, keyEquivalent: ""); menu.addItem(heading)
        if !listenerError.isEmpty { menu.addItem(NSMenuItem(title: listenerError, action: nil, keyEquivalent: "")) }
        if auth == "denied" { menu.addItem(NSMenuItem(title: "通知未获允许，请在系统设置中开启", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        for (_, input) in inputDevices() {
            let entry = NSMenuItem(title: input.label, action: #selector(selectDevice(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = input.uid
            entry.state = input.uid == currentInput()?.uid ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let lock = NSMenuItem(title: "固定当前", action: #selector(toggle), keyEquivalent: "")
        lock.target = self; lock.state = isFixed() ? .on : .off
        lock.isEnabled = isFixed() || currentInput() != nil
        menu.addItem(lock)
        if let target = fixedInput() { menu.addItem(NSMenuItem(title: "已固定：\(target.label)", action: nil, keyEquivalent: "")) }
        add("打开通知设置", #selector(settings))
        menu.addItem(.separator())
        add("退出", #selector(quit))
    }
    func add(_ title: String, _ action: Selector) { let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; item.menu?.addItem(entry) }
    @objc func toggle() {
        do { try setFixed(isFixed() ? nil : currentInput()) } catch { send(title: "无法保存固定状态", body: error.localizedDescription); return }
        pending?.cancel(); settle()
    }
    @objc func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String, let target = inputDevices().first(where: { $0.1.uid == uid })?.1 else { return }
        do {
            if try !selectInput(target) { send(title: "切换失败", body: "请检查 \(target.label) 的连接。") }
        } catch { send(title: "切换失败", body: error.localizedDescription) }
        pending?.cancel(); settle()
    }
    @objc func testNotice() { send(title: "麦克风提醒 · 测试", body: "当前输入：\(currentInput()?.label ?? "无法读取")") }
    @objc func settings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func saveStatus() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state: [String: Any] = ["current": currentInput()?.label ?? "unknown", "fixed": isFixed(), "fixedTarget": fixedInput()?.label ?? "", "problem": problem, "corrections": corrections, "authorization": auth, "lastChange": latest, "notification": notice, "delivered": delivered, "listenerCount": listeners.count, "error": listenerError, "updated": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Monitor()
app.delegate = delegate
app.run()
