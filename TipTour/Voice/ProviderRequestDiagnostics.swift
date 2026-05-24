import Foundation

enum ProviderRequestDiagnostics {
    static func responsePreview(from data: Data, maxLength: Int = 700) -> String {
        guard !data.isEmpty else { return "" }

        let prefix = data.prefix(maxLength)
        var preview = String(decoding: prefix, as: UTF8.self)
        if data.count > maxLength {
            preview += "\n... truncated ..."
        }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validateHTTPResponse(
        _ response: URLResponse,
        data: Data,
        serviceName: String,
        errorDomain: String
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let preview = responsePreview(from: data)
            let message: String
            if preview.isEmpty {
                message = "\(serviceName) failed with HTTP \(httpResponse.statusCode)."
            } else {
                message = "\(serviceName) failed with HTTP \(httpResponse.statusCode). \(preview)"
            }
            throw NSError(
                domain: errorDomain,
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
