import Foundation
import AppKit

private final class FakeCiscoState: CiscoStateReading {
    var available = true
    var link = VPNLinkState.connected
    var issue: IssueCode?
    var holdForCancellation = false
    private let lock = NSLock()
    private var count = 0
    let started = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func readState(cancellation: ObservationCancellation) throws -> VPNLinkState {
        lock.lock(); count += 1; lock.unlock(); started.signal()
        if holdForCancellation {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        if cancellation.cancelled { throw IssueCode.cancelled }
        if let issue = issue { throw issue }
        return link
    }
}

func observerTests() throws {
    let paste = applicationMenu().item(at: 1)?.submenu?.items.first(where: { $0.keyEquivalent == "v" })
    assert(paste?.action == #selector(NSText.paste(_:)) && paste?.target == nil && paste?.keyEquivalentModifierMask == .command)
    assert(CiscoStateClient.arguments == ["-s", "state"])
    for (text, expected) in [("Connected", VPNLinkState.connected), ("Подключено", .connected), ("Отключено", .disconnected),
                             ("Connecting", .connecting), ("Reconnecting", .reconnecting), ("повторное подключение", .reconnecting)] {
        assert(VPNLinkState.parse(">> state: \(text)\n") == expected)
    }
    assert(VPNLinkState.parse(">> state: Unknown\n>> state: Connected") == .connected)
    assert(VPNLinkState.parse(">> state: Connected\n>> state: Unknown") == .unknown)
    assert(VPNLinkState.parse("error: state: Connected\nPassword:") == .unknown)
    assert(VPNLinkState.parse(">> state: future-state") == .unknown)
    assert(VPNLinkState.parse(">> state: Connected\n>> error: Local IPC unavailable") == .unknown)
    assert(VPNLinkState.parse(">> ошибка: недоступно\n>> state: Подключено") == .unknown)
    assert(parseNativeRecovery(Data("<P><ClientInitialization><AutoReconnect>true</AutoReconnect></ClientInitialization></P>".utf8)) == .enabled)
    assert(parseNativeRecovery(Data("<a:P xmlns:a=\"http://schemas.xmlsoap.org/encoding/\"><a:ClientInitialization><a:AutoReconnect>true</a:AutoReconnect></a:ClientInitialization></a:P>".utf8)) == .enabled)
    assert(parseNativeRecovery(Data("<a:P xmlns:a=\"http://schemas.xmlsoap.org/encoding/\"><a:ClientInitialization><a:AutoReconnect>true<a:AutoReconnectBehavior>ReconnectAfterResume</a:AutoReconnectBehavior></a:AutoReconnect></a:ClientInitialization></a:P>".utf8)) == .enabled)
    assert(parseNativeRecovery(Data("<P><ClientInitialization><AutoReconnect>false</AutoReconnect></ClientInitialization></P>".utf8)) == .disabled)
    assert(parseNativeRecovery(Data("<P><AutoReconnect>true</AutoReconnect></P>".utf8)) == .unknown)
    assert(parseNativeRecovery(Data("<P><ClientInitialization><AutoReconnect>true</AutoReconnect><AutoReconnect>false</AutoReconnect></ClientInitialization></P>".utf8)) == .unknown)
    assert(parseNativeRecovery(Data("<not-valid".utf8)) == .unknown)
    assert(parseNativeRecovery(Data(repeating: 65, count: 1_048_577)) == .unknown)
    var policy = ObservationPolicy(); policy.enabled = true
    assert(!policy.allowsRead(available: true, online: false, at: 0))
    assert(!policy.allowsRead(available: false, online: true, at: 0))
    assert(!policy.allowsRead(available: true, online: nil, at: 0))
    assert(policy.allowsRead(available: true, online: true, at: 0))
    policy.begin(at: 0)
    assert(!policy.allowsRead(available: true, online: true, at: 59))
    assert(policy.allowsRead(available: true, online: true, at: 60))
    policy.finish(.commandFailed)
    for time in 1..<10000 { assert(!policy.allowsRead(available: true, online: true, at: Double(time * 60))) }
    policy.paused = false; policy.enabled = false
    assert(!policy.allowsRead(available: true, online: true, at: 100000))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSleep-observer-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DiagnosticStore(root: root)
    for issue in [IssueCode.commandTimeout, .commandFailed, .unsupportedState, .untrustedClient, .outputLimit] {
        let suite = "NoSleep-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeCiscoState(); fake.issue = issue
        let observer = CiscoObserver(diagnostics: store, reader: fake, defaults: defaults)
        var last = CiscoObservation(); observer.changed = { last = $0 }
        observer.checkOnceForTesting(online: true)
        for _ in 0..<100 { observer.checkOnceForTesting(online: true) }
        assert(fake.calls == 1 && last.issue == issue && last.link == .unknown, "Unknown failure must pause all automatic status work")
        observer.stop()
        let restarted = CiscoObserver(diagnostics: store, reader: fake, defaults: defaults)
        restarted.checkOnceForTesting(online: true); restarted.stop()
        assert(fake.calls == 1, "Restart cleared the persisted failure pause")
    }
    let suite = "NoSleep-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeCiscoState(); let observer = CiscoObserver(diagnostics: store, reader: fake, defaults: defaults)
    var last = CiscoObservation(); observer.changed = { last = $0 }
    observer.checkOnceForTesting(online: false); assert(fake.calls == 0)
    observer.checkOnceForTesting(online: true); assert(fake.calls == 1 && last.link == .connected)
    for _ in 0..<20 {
        observer.setEnabled(false); observer.checkOnceForTesting(online: true)
        observer.setEnabled(true); observer.checkOnceForTesting(online: true)
    }
    assert(fake.calls == 1, "Rapid switching bypassed 60-second cooldown")
    observer.setEnabled(false); observer.checkOnceForTesting(online: true); observer.stop()
    assert(!last.enabled && defaults.bool(forKey: "CiscoObservationEnabled") == false)
    let reopened = CiscoObserver(diagnostics: store, reader: fake, defaults: defaults)
    reopened.checkOnceForTesting(online: true); reopened.stop(); assert(fake.calls == 1, "Explicit off did not survive reopening")

    let cancellationSuite = "NoSleep-test-\(UUID().uuidString)"; let cancellationDefaults = UserDefaults(suiteName: cancellationSuite)!
    defer { cancellationDefaults.removePersistentDomain(forName: cancellationSuite) }
    let blocked = FakeCiscoState(); blocked.holdForCancellation = true
    let cancellationObserver = CiscoObserver(diagnostics: store, reader: blocked, defaults: cancellationDefaults)
    let complete = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { cancellationObserver.checkOnceForTesting(online: true); complete.signal() }
    assert(blocked.started.wait(timeout: .now() + 2) == .success)
    let start = ProcessInfo.processInfo.systemUptime; cancellationObserver.stop()
    assert(ProcessInfo.processInfo.systemUptime - start < 1 && complete.wait(timeout: .now() + 1) == .success, "Shutdown failed to cancel its owned read")
    store.flush()
    print("PASS: state-only contract, RU/EN states, policy parsing, offline/missing/unknown failures, no retry loop, cooldown, persistent off, cancellation")
}
