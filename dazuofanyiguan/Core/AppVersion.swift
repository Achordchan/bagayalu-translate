import Foundation

/// 应用版本号。
///
/// 读 Info.plist 是一次字典查找，放在 SwiftUI 的 body 里意味着每次重新求值都要查一遍；
/// 版本号在进程生命周期内不会变，这里缓存一次。
enum AppVersion {
    static let current: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.5"
}
