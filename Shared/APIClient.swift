import Foundation

enum APIError: Error, LocalizedError {
    case badStatus(Int)
    var errorDescription: String? {
        switch self { case .badStatus(let c): return "Server returned \(c)" }
    }
}

struct AmtrakerClient {
    static let base = "https://api-v3.amtraker.com/v3/trains/"

    static func runs(trainNumber: String) async throws -> [Train] {
        let num = trainNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let enc = num.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + enc) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 { return [] }
            guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }
        }
        return try decodeRuns(data, trainNumber: num)
    }

    static func decodeRuns(_ data: Data, trainNumber: String) throws -> [Train] {
        let r = try JSONDecoder().decode(TrainsResponse.self, from: data)
        return r.runs[trainNumber] ?? r.runs.values.first ?? []
    }
}
