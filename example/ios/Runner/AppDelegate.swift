import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CsesDeviceId") else {
      return
    }
    // cses.common 的 DeviceUtils 通过宿主通道读取 Keychain 中的稳定设备标识。
    let channel = FlutterMethodChannel(
      name: "com.yundiz/common", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "getDeviceId" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        result(try DeviceIdentifierStore().identifier())
      } catch {
        let error = error as NSError
        result(FlutterError(
          code: "DEVICE_ID_KEYCHAIN_ERROR",
          message: error.localizedDescription,
          details: ["status": error.code]))
      }
    }
  }
}

/// 使用系统 Keychain 保存设备 ID，兼容历史 SAMKeychain 数据，不执行删除或覆盖迁移。
///
/// service/account、Generic Password 类型和 UTF-8 编码均保持不变，已有条目的访问组、
/// 可访问性和同步属性不作修改。启动恢复、登录和设备鉴权仍获得同一个持久化标识。
private struct DeviceIdentifierStore {
    private let read: ([String: Any]) -> (OSStatus, Data?)
    private let add: ([String: Any]) -> OSStatus
    private let makeIdentifier: () -> String

    /// 使用系统 Security API；查询范围与旧 SAMKeychain 默认查询一致。
    init() {
        self.init(
            read: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) }
        )
    }

    /// 为无设备、无签名的单元测试注入系统操作，测试不会读写真实钥匙串。
    init(read: @escaping ([String: Any]) -> (OSStatus, Data?),
         add: @escaping ([String: Any]) -> OSStatus,
         makeIdentifier: @escaping () -> String = {
             UUID().uuidString.replacingOccurrences(of: "-", with: "")
         }) {
        self.read = read
        self.add = add
        self.makeIdentifier = makeIdentifier
    }

    /// 返回已持久化的设备 ID，仅在系统明确返回「条目不存在」时创建。
    ///
    /// 锁屏、访问受限、数据损坏和保存失败均抛出带 OSStatus 的 NSError，由插件向 Dart
    /// 报错；绝不以一个临时 UUID 冒充持久化 ID，以免登录恢复误判为另一台设备。
    func identifier() throws -> String {
        if let existing = try existingIdentifier() {
            return existing
        }

        let identifier = makeIdentifier()
        var attributes = identityAttributes
        attributes[kSecValueData as String] = Data(identifier.utf8)
        // 新条目沿用系统默认可访问性和默认访问组；SynchronizableAny 仅用于读取，
        // 不能作为新增条目的属性，也不在迁移时主动启用 iCloud 同步。
        let status = add(attributes)
        if status == errSecSuccess {
            return identifier
        }
        if status == errSecDuplicateItem {
            // 另一个调用可能已先创建成功。只重读一次，采用落盘值，不覆盖竞争赢家。
            guard let existing = try existingIdentifier() else {
                throw keychainError(errSecItemNotFound)
            }
            return existing
        }
        throw keychainError(status)
    }

    /// 保留发布版本使用的存储键；更改任何一项都会导致旧用户的设备标识丢失。
    private var identityAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "wehanyu.app",
            kSecAttrAccount as String: "deviceId",
        ]
    }

    /// nil 仅表示条目不存在，其他错误不具备生成新 ID 的条件。
    private func existingIdentifier() throws -> String? {
        var query = identityAttributes
        // SAMKeychainQuery 的默认同步模式是 Any，必须同时覆盖旧的非同步/同步条目。
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = read(query)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        guard let data, let identifier = String(data: data, encoding: .utf8) else {
            throw keychainError(errSecDecode)
        }
        return identifier
    }

    /// 保留系统错误码供上层诊断，不把设备标识或钥匙串数据写入错误信息。
    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Unable to access the persisted device identifier (Keychain status: \(status)).",
        ])
    }
}
