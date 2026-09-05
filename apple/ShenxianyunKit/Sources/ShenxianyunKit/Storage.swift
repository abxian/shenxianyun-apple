import Foundation

/// 本地状态（契约 G）。
///
/// **必须用 App Group 共享容器，不能用 `UserDefaults.standard`**——
/// Network Extension 是独立进程，它要读设备凭据才能上报心跳与流量。
/// 旧 sing-box 线用的是 `UserDefaults.standard`，Extension 根本读不到，
/// 这也是它一直没有遥测能力的原因之一。
public protocol ShenxianyunStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// App Group 支持的实现。`suiteName` 传 `group.<bundle base>`。
///
/// `@unchecked Sendable`：`UserDefaults` 没有标注 `Sendable`，但 Apple 文档明确
/// 它是线程安全的，且本类型只做 get/set 不持有其它可变状态。跨进程（App ↔ Extension）
/// 的一致性由 App Group 的 CFPreferences 后端保证，不由这里的锁保证。
public final class AppGroupStore: ShenxianyunStore, @unchecked Sendable {
    private let defaults: UserDefaults

    /// suiteName 不可用时（App Group 没配对、或在纯单测环境里）返回 nil，
    /// 让调用方显式决定怎么办，而不是静默退回 standard 造成"Extension 读不到"的隐性 bug。
    public init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// 内存实现，供单元测试与预览使用。
public final class InMemoryStore: ShenxianyunStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key] as? Data
    }
    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key] as? String
    }
    public func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}

/// 客户端的持久状态。
public struct ShenxianyunState: Sendable {
    private enum Key {
        static let code = "shenxianyun.access_code"
        static let clientID = "shenxianyun.client_id"
        static let activation = "shenxianyun.activation"
        static let endpoints = "shenxianyun.endpoints"
    }

    private let store: ShenxianyunStore

    public init(store: ShenxianyunStore) {
        self.store = store
    }

    public var accessCode: String? {
        get { store.string(forKey: Key.code) }
        nonmutating set { store.set(newValue, forKey: Key.code) }
    }

    /// **稳定设备 id**：一旦生成就不再变，重置配置也不能改——
    /// 后台的设备数统计与风控都挂在它上面。族内 PC/Android 是同一语义。
    public func clientID() -> String {
        if let existing = store.string(forKey: Key.clientID), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        store.set(generated, forKey: Key.clientID)
        return generated
    }

    public var activation: ShenxianyunActivation? {
        get {
            guard let data = store.data(forKey: Key.activation) else { return nil }
            return try? JSONDecoder().decode(ShenxianyunActivation.self, from: data)
        }
        nonmutating set {
            store.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.activation)
        }
    }

    /// 缓存上次成功拿到的地址表。冷启动没网时先用它，比退回引导地址强。
    public var cachedEndpoints: ShenxianyunEndpoints? {
        get {
            guard let data = store.data(forKey: Key.endpoints) else { return nil }
            return try? JSONDecoder().decode(ShenxianyunEndpoints.self, from: data)
        }
        nonmutating set {
            store.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.endpoints)
        }
    }

    /// 退出登录 / 重置：清掉提取码与激活凭据，**但保留 clientID**。
    public func clearActivation() {
        store.set(nil as String?, forKey: Key.code)
        store.set(nil as Data?, forKey: Key.activation)
    }
}
