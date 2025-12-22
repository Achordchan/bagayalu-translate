import Foundation

struct HTTPClient {
    enum HTTPError: LocalizedError {
        case invalidResponse
        case badStatus(code: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "网络响应无效"
            case .badStatus(let code, let body):
                if body.isEmpty { return "请求失败（HTTP \(code)）" }
                return "请求失败（HTTP \(code)）：\(body)"
            }
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        if (200...299).contains(http.statusCode) {
            return data
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        throw HTTPError.badStatus(code: http.statusCode, body: body)
    }
}
