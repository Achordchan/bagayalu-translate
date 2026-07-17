import Foundation

enum OpenAIEndpointValidationError: LocalizedError, Equatable {
    case empty
    case malformed
    case missingHost
    case unsupportedScheme(String)
    case insecureRemoteHTTP
    case containsUserInfo
    case containsFragment

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Base URL 不能为空"
        case .malformed:
            return "Base URL 无效"
        case .missingHost:
            return "Base URL 缺少主机名"
        case .unsupportedScheme(let scheme):
            return "不支持的协议：\(scheme)"
        case .insecureRemoteHTTP:
            return "远端 Base URL 仅允许 HTTPS；本地调试可用 http://localhost"
        case .containsUserInfo:
            return "Base URL 不能包含用户名或密码"
        case .containsFragment:
            return "Base URL 不能包含 #fragment"
        }
    }
}

enum OpenAIEndpointValidator {
    static let localHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
        "[::1]"
    ]

    static func validatedBaseURL(from raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIEndpointValidationError.empty
        }

        guard let url = URL(string: trimmed) else {
            throw OpenAIEndpointValidationError.malformed
        }

        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw OpenAIEndpointValidationError.malformed
        }

        guard scheme == "https" || scheme == "http" else {
            throw OpenAIEndpointValidationError.unsupportedScheme(scheme)
        }

        if let user = url.user, !user.isEmpty {
            throw OpenAIEndpointValidationError.containsUserInfo
        }
        if let password = url.password, !password.isEmpty {
            throw OpenAIEndpointValidationError.containsUserInfo
        }

        if let fragment = url.fragment, !fragment.isEmpty {
            throw OpenAIEndpointValidationError.containsFragment
        }

        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw OpenAIEndpointValidationError.missingHost
        }

        if scheme == "http" {
            let normalizedHost = host.lowercased()
            guard localHosts.contains(normalizedHost) else {
                throw OpenAIEndpointValidationError.insecureRemoteHTTP
            }
        }

        return url
    }
}
