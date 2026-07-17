import Foundation

struct HTTPClient {
    enum HTTPError: LocalizedError {
        case invalidResponse
        case responseTooLarge(maxBytes: Int)
        case badStatus(code: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "网络响应无效"
            case .responseTooLarge(let maxBytes):
                return "响应内容过大（超过 \(maxBytes) 字节）"
            case .badStatus(let code, let body):
                if body.isEmpty { return "请求失败（HTTP \(code)）" }
                return "请求失败（HTTP \(code)）：\(body)"
            }
        }
    }

    private static let maxResponseBytes = 2_000_000
    private static let maxErrorBodyCharacters = 500

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func data(for request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        var data = Data()
        data.reserveCapacity(min(64_000, Self.maxResponseBytes))
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxResponseBytes {
                bytes.task.cancel()
                throw HTTPError.responseTooLarge(maxBytes: Self.maxResponseBytes)
            }
        }

        if (200...299).contains(http.statusCode) {
            return data
        }

        let body = Self.sanitizedErrorBody(from: data)
        throw HTTPError.badStatus(code: http.statusCode, body: body)
    }

    static func sanitizedErrorBody(from data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "" }

        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= maxErrorBodyCharacters {
            return collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxErrorBodyCharacters)
        return String(collapsed[..<end]) + "…"
    }

    /// 测试与调试可见：当前错误体字符上限。
    static var errorBodyCharacterLimit: Int { maxErrorBodyCharacters }

    /// 测试与调试可见：响应体字节上限。
    static var responseByteLimit: Int { maxResponseBytes }
}
