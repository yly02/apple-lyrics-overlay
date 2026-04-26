import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI
import Translation

private struct TrackKey: Hashable {
    let title: String
    let artist: String
}

private struct MusicSnapshot: Equatable {
    let trackKey: TrackKey
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
    let isFavorited: Bool
}

private struct LyricLine: Equatable {
    let timestamp: TimeInterval
    let text: String
}

private struct LRCLibResult: Decodable {
    let syncedLyrics: String?
}

private struct LyricsOVHResult: Decodable {
    let lyrics: String
}

private struct TencentTranslationResponse: Decodable {
    struct Payload: Decodable {
        struct APIError: Decodable {
            let code: String
            let message: String

            enum CodingKeys: String, CodingKey {
                case code = "Code"
                case message = "Message"
            }
        }

        let targetText: String?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case targetText = "TargetText"
            case error = "Error"
        }
    }

    let response: Payload

    enum CodingKeys: String, CodingKey {
        case response = "Response"
    }
}

private struct MyMemoryResponse: Decodable {
    let responseData: MyMemoryTranslationData
    let responseStatus: Int
}

private struct MyMemoryTranslationData: Decodable {
    let translatedText: String
}

private struct TencentTranslationCredentials: Codable {
    let secretId: String
    let secretKey: String
}

private struct LyricLookupQuery: Hashable {
    let title: String
    let artist: String
    let album: String

    init(title: String, artist: String, album: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(snapshot: MusicSnapshot) {
        self.init(
            title: snapshot.trackKey.title,
            artist: snapshot.trackKey.artist,
            album: snapshot.album
        )
    }

    var cacheKey: String {
        "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())"
    }

    func candidateQueries() -> [LyricLookupQuery] {
        var queries: [LyricLookupQuery] = []
        var seen: Set<String> = []

        func append(_ query: LyricLookupQuery) {
            let key = query.cacheKey
            guard !key.isEmpty, seen.insert(key).inserted else {
                return
            }

            queries.append(query)
        }

        append(self)

        let titleVariants = normalizedTitleVariants()
        let artistVariants = normalizedArtistVariants()
        let albumVariants = normalizedAlbumVariants()

        for title in titleVariants {
            append(LyricLookupQuery(title: title, artist: artist, album: album))
        }

        for artist in artistVariants {
            append(LyricLookupQuery(title: title, artist: artist, album: album))
        }

        for title in titleVariants {
            for artist in artistVariants {
                append(LyricLookupQuery(title: title, artist: artist, album: album))
            }
        }

        for album in albumVariants {
            append(LyricLookupQuery(title: title, artist: artist, album: album))
        }

        for title in titleVariants {
            for artist in artistVariants {
                for album in albumVariants {
                    append(LyricLookupQuery(title: title, artist: artist, album: album))
                }
            }
        }

        return queries
    }

    private func normalizedTitleVariants() -> [String] {
        var variants = [title]
        variants.append(cleanedTrackTitle(title))
        return deduplicatedNonEmpty(variants)
    }

    private func normalizedArtistVariants() -> [String] {
        var variants = [artist]
        variants.append(primaryArtistName(artist))
        return deduplicatedNonEmpty(variants)
    }

    private func normalizedAlbumVariants() -> [String] {
        var variants = [album]
        variants.append(cleanedAlbumName(album))
        variants.append("")
        return deduplicatedNonEmpty(variants)
    }

    private func deduplicatedNonEmpty(_ values: [String]) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            output.append(trimmed)
        }

        return output
    }

    private func cleanedTrackTitle(_ raw: String) -> String {
        var cleaned = raw
        let patterns = [
            #"\s*[\(\[](?:feat|ft|featuring|live|ver|version|remaster(?:ed)?|mono|stereo)[^)\]]*[\)\]]"#,
            #"\s*-\s*(?:feat|ft|featuring|live|ver|version|remaster(?:ed)?|mono|stereo).*$"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private func primaryArtistName(_ raw: String) -> String {
        let separators = [" feat. ", " ft. ", " featuring ", " & ", ", ", " / ", " x "]
        let lowered = raw.lowercased()

        for separator in separators {
            if let range = lowered.range(of: separator) {
                let distance = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                let index = raw.index(raw.startIndex, offsetBy: distance)
                return String(raw[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return raw
    }

    private func cleanedAlbumName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: #"\s*(?:-\s*)?(?:single|ep|deluxe|expanded|bonus track version).*$"#, with: "", options: .regularExpression)
        return cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}

private enum LyricsProviderKind: String, CaseIterable {
    case lrclib = "LRCLIB"
    case musicLocal = "Music"
    case lyricsOvh = "lyrics.ovh"
}

private enum LyricsPayload: Equatable {
    case synced([LyricLine])
    case plain([String])
    case none
}

private struct LyricFetchResult {
    let provider: LyricsProviderKind
    let payload: LyricsPayload
}

private struct PersistentLyricsCacheEntry: Codable {
    let providerRawValue: String
    let plainLines: [String]
}

private struct TranslationRequest: Equatable {
    let sourceText: String
    let queryText: String
}

private enum TranslationTimeoutError: Error {
    case exceeded
}

private let translationRequestTimeout: Duration = .milliseconds(2500)
private let translationRetryDelay: Duration = .milliseconds(180)

private func runWithTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw TranslationTimeoutError.exceeded
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func normalizedTranslationText(_ text: String) -> String {
    var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let bracketMap: [Character: Character] = [
        "(": "（",
        ")": "）",
        "﹙": "（",
        "﹚": "）",
        "❨": "（",
        "❩": "）",
    ]
    normalized = String(normalized.map { bracketMap[$0] ?? $0 })

    let quotePairs: [(Character, Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("“", "”"),
        ("‘", "’"),
        ("「", "」"),
        ("『", "』"),
        ("《", "》"),
    ]

    var removedWrappingQuotes = true
    while removedWrappingQuotes {
        removedWrappingQuotes = false
        guard let first = normalized.first, let last = normalized.last, normalized.count >= 2 else {
            break
        }

        if quotePairs.contains(where: { $0.0 == first && $0.1 == last }) {
            normalized.removeFirst()
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            removedWrappingQuotes = true
        }
    }

    normalized = normalized.replacingOccurrences(of: "（ ", with: "（")
    normalized = normalized.replacingOccurrences(of: " ）", with: "）")

    while let last = normalized.last, ["。", ".", "．", "｡"].contains(last) {
        normalized.removeLast()
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return normalized
}

@MainActor
private final class TranslationSettingsPanelModel: ObservableObject {
    enum StatusTone {
        case neutral
        case success
        case warning
    }

    @Published var secretId: String
    @Published var secretKey: String
    @Published var statusMessage: String
    @Published var statusTone: StatusTone
    @Published var isTesting = false

    init() {
        let credentials = TencentCredentialsStore.load()
        secretId = credentials?.secretId ?? ""
        secretKey = credentials?.secretKey ?? ""
        statusMessage = "可先测试接口，再决定是否保存。"
        statusTone = .neutral
    }

    func reloadFromStore() {
        let credentials = TencentCredentialsStore.load()
        secretId = credentials?.secretId ?? ""
        secretKey = credentials?.secretKey ?? ""
        statusMessage = "可先测试接口，再决定是否保存。"
        statusTone = .neutral
        isTesting = false
    }

    func save() {
        let secretId = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !secretId.isEmpty, !secretKey.isEmpty else {
            statusMessage = "Secret ID 和 Secret Key 需要同时填写。"
            statusTone = .warning
            return
        }

        TencentCredentialsStore.save(
            TencentTranslationCredentials(secretId: secretId, secretKey: secretKey)
        )
        statusMessage = "已保存，后续会直接使用这组配置。"
        statusTone = .success
    }

    func clear() {
        TencentCredentialsStore.clear()
        secretId = ""
        secretKey = ""
        statusMessage = "已清除配置，将回退到本地兜底翻译链路。"
        statusTone = .neutral
    }

    func test() {
        let secretId = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !secretId.isEmpty, !secretKey.isEmpty else {
            statusMessage = "测试前请先填写 Secret ID 和 Secret Key。"
            statusTone = .warning
            return
        }

        isTesting = true
        statusMessage = "正在测试翻译接口…"
        statusTone = .neutral

        let credentials = TencentTranslationCredentials(secretId: secretId, secretKey: secretKey)
        Task {
            let client = TencentTranslationClient()
            let translatedText = await client.translate(
                "Hello, this is a translation test",
                credentialsOverride: credentials
            )

            guard !Task.isCancelled else {
                return
            }

            isTesting = false
            if let translatedText, !translatedText.isEmpty {
                statusMessage = "测试成功：\(normalizedTranslationText(translatedText))"
                statusTone = .success
            } else {
                statusMessage = "测试失败：没有拿到有效翻译结果，请检查配置或稍后再试。"
                statusTone = .warning
            }
        }
    }
}

private actor LyricsPersistentCache {
    static let shared = LyricsPersistentCache()

    private let fileURL: URL
    private var cache: [String: PersistentLyricsCacheEntry]
    private let maxEntries = 2000

    init() {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheDirectory = baseDirectory
            .appendingPathComponent("AppleMusicLyrics", isDirectory: true)
        fileURL = cacheDirectory.appendingPathComponent("lyrics-cache.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            // Best effort cache directory creation.
        }

        if
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: PersistentLyricsCacheEntry].self, from: data)
        {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func plainLyrics(for cacheKey: String, provider: LyricsProviderKind) -> [String]? {
        guard
            let entry = cache[cacheKey],
            entry.providerRawValue == provider.rawValue,
            !entry.plainLines.isEmpty
        else {
            return nil
        }

        return entry.plainLines
    }

    func storePlainLyrics(_ lines: [String], for cacheKey: String, provider: LyricsProviderKind) {
        guard
            !cacheKey.isEmpty,
            !lines.isEmpty
        else {
            return
        }

        cache.removeValue(forKey: cacheKey)
        cache[cacheKey] = PersistentLyricsCacheEntry(
            providerRawValue: provider.rawValue,
            plainLines: lines
        )

        while cache.count > maxEntries, let oldestKey = cache.keys.first {
            cache.removeValue(forKey: oldestKey)
        }

        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}

private actor TranslationPersistentCache {
    static let shared = TranslationPersistentCache()

    private let fileURL: URL
    private var cache: [String: String]
    private let maxEntries = 4000

    init() {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheDirectory = baseDirectory
            .appendingPathComponent("AppleMusicLyrics", isDirectory: true)
        fileURL = cacheDirectory.appendingPathComponent("translation-cache.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            // Best effort cache directory creation.
        }

        if
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func translation(for text: String) -> String? {
        guard let cached = cache[key(for: text)] else {
            return nil
        }

        let normalized = normalizedTranslationText(cached)
        if normalized.isEmpty {
            return nil
        }

        return normalized
    }

    func store(_ translatedText: String, for text: String) {
        let normalized = normalizedTranslationText(translatedText)
        guard !normalized.isEmpty else {
            return
        }

        let cacheKey = key(for: text)
        cache.removeValue(forKey: cacheKey)
        cache[cacheKey] = normalized

        while cache.count > maxEntries, let oldestKey = cache.keys.first {
            cache.removeValue(forKey: oldestKey)
        }

        persist()
    }

    private func key(for text: String) -> String {
        "zh-Hans|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}

private actor TranslationFallbackClient {
    static let shared = TranslationFallbackClient()
    private let tencentClient = TencentTranslationClient()

    func translate(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let simplified = normalizeToSimplifiedChineseIfNeeded(trimmed) {
            return simplified
        }

        if let translated = await tencentClient.translate(trimmed) {
            return translated
        }

        guard let sourceLanguage = sourceLanguage(for: trimmed) else {
            return nil
        }

        return await translateWithMyMemory(trimmed, sourceLanguage: sourceLanguage)
    }

    private func normalizeToSimplifiedChineseIfNeeded(_ text: String) -> String? {
        guard text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else {
            return nil
        }

        guard
            let converted = text.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false),
            converted != text
        else {
            return nil
        }

        return converted
    }

    private func translateWithMyMemory(_ text: String, sourceLanguage: String) async -> String? {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(sourceLanguage)|zh-CN"),
        ]

        guard let url = components?.url else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else {
                return nil
            }

            let result = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
            let translatedText = result.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                result.responseStatus == 200,
                !translatedText.isEmpty,
                translatedText.caseInsensitiveCompare(text) != .orderedSame
            else {
                return nil
            }

            return translatedText
        } catch {
            return nil
        }
    }

    private func sourceLanguage(for text: String) -> String? {
        if text.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil {
            return "ja"
        }

        if text.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil {
            return "ko"
        }

        if text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            return "en"
        }

        return nil
    }
}

private enum KeychainHelper {
    static func string(forService service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard
            status == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }
}

private enum TencentCredentialsStore {
    private static let directoryName = "AppleMusicLyrics"
    private static let fileName = "tencent-credentials.json"

    static func load() -> TencentTranslationCredentials? {
        guard
            let data = try? Data(contentsOf: fileURL()),
            let credentials = try? JSONDecoder().decode(TencentTranslationCredentials.self, from: data),
            !credentials.secretId.isEmpty,
            !credentials.secretKey.isEmpty
        else {
            return nil
        }

        return credentials
    }

    static func save(_ credentials: TencentTranslationCredentials) {
        guard
            !credentials.secretId.isEmpty,
            !credentials.secretKey.isEmpty
        else {
            return
        }

        let url = fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(credentials)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Best effort local credential cache.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL())
    }

    private static func fileURL() -> URL {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

private actor TencentTranslationClient {
    private let decoder = JSONDecoder()
    private let host = "tmt.tencentcloudapi.com"
    private let service = "tmt"
    private let region = "ap-beijing"
    private let version = "2018-03-21"
    private let action = "TextTranslate"
    private let keychainService = "com.yaoly.applemusiclyrics.tencent.translate"

    nonisolated static func testTranslationSynchronously(
        _ text: String,
        credentials: TencentTranslationCredentials,
        timeout: TimeInterval = 8
    ) -> String? {
        final class ResultBox: @unchecked Sendable {
            var value: String?
        }

        let host = "tmt.tencentcloudapi.com"
        let service = "tmt"
        let region = "ap-beijing"
        let version = "2018-03-21"
        let action = "TextTranslate"
        let payloadObject: [String: Any] = [
            "SourceText": text,
            "Source": "auto",
            "Target": "zh",
            "ProjectId": 0,
        ]

        guard
            let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject, options: []),
            let payload = String(data: payloadData, encoding: .utf8)
        else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = Self.dateString(for: timestamp)
        let signedHeaders = "content-type;host"
        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            Self.sha256Hex(payload),
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            Self.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secretKey: credentials.secretKey, date: date, service: service)
        let signature = Self.hmacHex(key: signingKey, message: stringToSign)
        let authorization = "TC3-HMAC-SHA256 Credential=\(credentials.secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.timeoutInterval = timeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }

            guard
                let data,
                let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                let result = try? JSONDecoder().decode(TencentTranslationResponse.self, from: data),
                result.response.error == nil
            else {
                return
            }

            let translatedText = result.response.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard
                !translatedText.isEmpty,
                translatedText.caseInsensitiveCompare(text) != .orderedSame
            else {
                return
            }

            resultBox.value = translatedText
        }

        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + timeout + 1)
        if waitResult == .timedOut {
            task.cancel()
            return nil
        }

        return resultBox.value
    }

    func translate(_ text: String, credentialsOverride: TencentTranslationCredentials? = nil) async -> String? {
        guard let credentials = credentialsOverride ?? credentials() else {
            return nil
        }

        let payloadObject: [String: Any] = [
            "SourceText": text,
            "Source": "auto",
            "Target": "zh",
            "ProjectId": 0,
        ]

        guard
            let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject, options: []),
            let payload = String(data: payloadData, encoding: .utf8)
        else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = Self.dateString(for: timestamp)
        let signedHeaders = "content-type;host"
        let contentType = "application/json; charset=utf-8"

        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            Self.sha256Hex(payload),
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            Self.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secretKey: credentials.secretKey, date: date, service: service)
        let signature = Self.hmacHex(key: signingKey, message: stringToSign)
        let authorization = "TC3-HMAC-SHA256 Credential=\(credentials.secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            let result = try decoder.decode(TencentTranslationResponse.self, from: data)
            guard result.response.error == nil else {
                return nil
            }

            let translatedText = result.response.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard
                !translatedText.isEmpty,
                translatedText.caseInsensitiveCompare(text) != .orderedSame
            else {
                return nil
            }

            return translatedText
        } catch {
            return nil
        }
    }

    private func credentials() -> TencentTranslationCredentials? {
        if let storedCredentials = TencentCredentialsStore.load() {
            return storedCredentials
        }

        guard
            let secretId = KeychainHelper.string(forService: keychainService, account: "secretId"),
            let secretKey = KeychainHelper.string(forService: keychainService, account: "secretKey"),
            !secretId.isEmpty,
            !secretKey.isEmpty
        else {
            return nil
        }

        let credentials = TencentTranslationCredentials(secretId: secretId, secretKey: secretKey)
        TencentCredentialsStore.save(credentials)
        return credentials
    }

    private static func dateString(for timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, message: String) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature)
    }

    private static func hmacHex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey(secretKey: String, date: String, service: String) -> Data {
        let secretDate = hmacSHA256(key: Data(("TC3" + secretKey).utf8), message: date)
        let secretService = hmacSHA256(key: secretDate, message: service)
        return hmacSHA256(key: secretService, message: "tc3_request")
    }
}

private enum OverlayStyle {
    static let cornerRadius: CGFloat = 24
    static let activeBackgroundOpacity = 0.0
    static let inactiveBackgroundOpacity = 0.0
    static let borderOpacity = 0.0
    static let topFontSize: CGFloat = 25
    static let bottomFontSize: CGFloat = 16.5
    static let messageFontSize: CGFloat = 10
    static let lineSpacing: CGFloat = 1
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 4
    static let minimumContentWidth: CGFloat = 360
    static let contentWidth: CGFloat = 560
    static let contentHeight: CGFloat = 66
    static let outerPadding: CGFloat = 0
    static let windowBottomInset: CGFloat = 72
    static let glassFillOpacity: CGFloat = 0.085
    static let glassStrokeOpacity: CGFloat = 0.15
    static let ambientAuraOpacity: CGFloat = 0.04
    static let inactiveOverlayOpacity: CGFloat = 0.62
    static let lyricWidthAnimationDuration: TimeInterval = 0.2
}

private struct OverlayMetrics {
    let cornerRadius: CGFloat
    let topFontSize: CGFloat
    let bottomFontSize: CGFloat
    let messageFontSize: CGFloat
    let lineSpacing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minimumContentWidth: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let outerPadding: CGFloat

    func windowWidth(for contentWidth: CGFloat) -> CGFloat {
        clampedContentWidth(contentWidth) + (outerPadding * 2)
    }

    var maximumWindowWidth: CGFloat {
        contentWidth + (outerPadding * 2)
    }

    var minimumWindowWidth: CGFloat {
        minimumContentWidth + (outerPadding * 2)
    }

    var windowHeight: CGFloat {
        contentHeight + (outerPadding * 2)
    }

    var minimumWindowHeight: CGFloat {
        max(60, windowHeight)
    }

    var windowWidthStep: CGFloat {
        20 * max(0.92, min(1.08, topFontSize / OverlayStyle.topFontSize))
    }

    func clampedContentWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumContentWidth), contentWidth)
    }
}

private enum OverlaySizePreset: Int, CaseIterable {
    case small
    case medium
    case large

    var title: String {
        switch self {
        case .small:
            return "小"
        case .medium:
            return "中"
        case .large:
            return "大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:
            return 0.85
        case .medium:
            return 1.0
        case .large:
            return 1.18
        }
    }

    var metrics: OverlayMetrics {
        OverlayMetrics(
            cornerRadius: OverlayStyle.cornerRadius * scale,
            topFontSize: OverlayStyle.topFontSize * scale,
            bottomFontSize: OverlayStyle.bottomFontSize * scale,
            messageFontSize: OverlayStyle.messageFontSize * scale,
            lineSpacing: OverlayStyle.lineSpacing * scale,
            horizontalPadding: OverlayStyle.horizontalPadding * scale,
            verticalPadding: OverlayStyle.verticalPadding * scale,
            minimumContentWidth: OverlayStyle.minimumContentWidth * scale,
            contentWidth: OverlayStyle.contentWidth * scale,
            contentHeight: OverlayStyle.contentHeight * scale,
            outerPadding: OverlayStyle.outerPadding * scale
        )
    }
}

private enum OverlayAppearanceMode: Int, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "始终浅色"
        case .dark:
            return "始终深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

private enum ChineseDisplayMode: Int, CaseIterable {
    case simplified
    case traditional

    var title: String {
        switch self {
        case .simplified:
            return "简体中文"
        case .traditional:
            return "繁体中文"
        }
    }

    var transform: StringTransform {
        switch self {
        case .simplified:
            return StringTransform(rawValue: "Traditional-Simplified")
        case .traditional:
            return StringTransform(rawValue: "Simplified-Traditional")
        }
    }
}

private enum LyricBarDisplayMode: Int, CaseIterable {
    case bar
    case lyricsOnly

    var title: String {
        switch self {
        case .bar:
            return "显示歌词栏"
        case .lyricsOnly:
            return "仅显示歌词"
        }
    }

    var showsBackground: Bool {
        switch self {
        case .bar:
            return true
        case .lyricsOnly:
            return false
        }
    }
}

private enum LyricAnimationMode: Int, CaseIterable {
    case stable
    case jump
    case bounce
    case flash
    case blinds

    var title: String {
        switch self {
        case .stable:
            return "稳定"
        case .jump:
            return "跳入跳出"
        case .bounce:
            return "弹动"
        case .flash:
            return "闪现"
        case .blinds:
            return "百叶窗"
        }
    }

    func animation(for role: LyricContentRole) -> Animation {
        switch self {
        case .stable:
            switch role {
            case .primary:
                return .easeOut(duration: 0.2)
            case .secondary:
                return .easeOut(duration: 0.22).delay(0.04)
            }
        case .jump:
            return .easeInOut(duration: 0.16)
        case .bounce:
            return .interactiveSpring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.08)
        case .flash:
            return .easeInOut(duration: 0.1)
        case .blinds:
            return .easeInOut(duration: 0.16)
        }
    }

    func transition(for role: LyricContentRole) -> AnyTransition {
        switch self {
        case .stable:
            switch role {
            case .primary:
                return .modifier(
                    active: LyricMotionTransitionModifier(yOffset: 10, scale: 0.995, opacity: 0, blur: 1.1),
                    identity: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
                )
            case .secondary:
                return .modifier(
                    active: LyricMotionTransitionModifier(yOffset: 6, scale: 0.998, opacity: 0, blur: 0.8),
                    identity: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
                )
            }
        case .jump:
            return .modifier(
                active: LyricMotionTransitionModifier(yOffset: 8, scale: 0.985, opacity: 0, blur: 1.2),
                identity: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
            )
        case .bounce:
            return .modifier(
                active: LyricMotionTransitionModifier(yOffset: 4, scale: 0.96, opacity: 0, blur: 0.8),
                identity: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
            )
        case .flash:
            return .modifier(
                active: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 0, blur: 2),
                identity: LyricMotionTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
            )
        case .blinds:
            return .modifier(
                active: LyricBlindsTransitionModifier(progress: 0.78, opacity: 0),
                identity: LyricBlindsTransitionModifier(progress: 1, opacity: 1)
            )
        }
    }
}

private enum LyricContentRole {
    case primary
    case secondary
}

private struct StoredColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? NSColor.white
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    static let defaultBase = StoredColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let defaultGradient = StoredColor(red: 0.42, green: 0.84, blue: 1, alpha: 1)
}

private struct StoredWindowPosition: Codable, Equatable {
    let screenIdentifier: String?
    let relativeCenterX: Double
    let relativeMinY: Double
}

private struct LegacyStoredWindowPosition: Codable {
    let centerX: Double
    let minY: Double
}

@MainActor
private final class OverlaySettings: ObservableObject {
    private static let sizePresetKey = "overlay.sizePreset"
    private static let lyricBaseColorKey = "overlay.lyricBaseColor"
    private static let lyricGradientColorKey = "overlay.lyricGradientColor"
    private static let useGradientKey = "overlay.useGradient"
    private static let lyricFontNameKey = "overlay.lyricFontName"
    private static let positionLockedKey = "overlay.positionLocked"
    private static let windowPositionKey = "overlay.windowPosition"
    private static let appearanceModeKey = "overlay.appearanceMode"
    private static let chineseDisplayModeKey = "overlay.chineseDisplayMode"
    private static let translationEnabledKey = "overlay.translationEnabled"
    private static let launchAtLoginEnabledKey = "overlay.launchAtLoginEnabled"
    private static let lyricBarDisplayModeKey = "overlay.lyricBarDisplayMode"
    private static let lyricAnimationModeKey = "overlay.lyricAnimationMode"

    @Published var sizePreset: OverlaySizePreset {
        didSet {
            UserDefaults.standard.set(sizePreset.rawValue, forKey: Self.sizePresetKey)
        }
    }

    @Published var lyricBaseColor: StoredColor {
        didSet {
            saveColor(lyricBaseColor, key: Self.lyricBaseColorKey)
        }
    }

    @Published var lyricGradientColor: StoredColor {
        didSet {
            saveColor(lyricGradientColor, key: Self.lyricGradientColorKey)
        }
    }

    @Published var useGradient: Bool {
        didSet {
            UserDefaults.standard.set(useGradient, forKey: Self.useGradientKey)
        }
    }

    @Published var lyricFontName: String? {
        didSet {
            UserDefaults.standard.set(lyricFontName, forKey: Self.lyricFontNameKey)
        }
    }

    @Published var isPositionLocked: Bool {
        didSet {
            UserDefaults.standard.set(isPositionLocked, forKey: Self.positionLockedKey)
        }
    }

    @Published var appearanceMode: OverlayAppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        }
    }

    @Published var chineseDisplayMode: ChineseDisplayMode {
        didSet {
            UserDefaults.standard.set(chineseDisplayMode.rawValue, forKey: Self.chineseDisplayModeKey)
        }
    }

    @Published var isTranslationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTranslationEnabled, forKey: Self.translationEnabledKey)
        }
    }

    @Published var launchAtLoginEnabled: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: Self.launchAtLoginEnabledKey)
        }
    }

    @Published var lyricBarDisplayMode: LyricBarDisplayMode {
        didSet {
            UserDefaults.standard.set(lyricBarDisplayMode.rawValue, forKey: Self.lyricBarDisplayModeKey)
        }
    }

    @Published var lyricAnimationMode: LyricAnimationMode {
        didSet {
            UserDefaults.standard.set(lyricAnimationMode.rawValue, forKey: Self.lyricAnimationModeKey)
        }
    }

    init() {
        let rawValue = UserDefaults.standard.object(forKey: Self.sizePresetKey) as? Int
        sizePreset = OverlaySizePreset(rawValue: rawValue ?? OverlaySizePreset.medium.rawValue) ?? .medium
        lyricBaseColor = Self.loadColor(forKey: Self.lyricBaseColorKey) ?? .defaultBase
        lyricGradientColor = Self.loadColor(forKey: Self.lyricGradientColorKey) ?? .defaultGradient
        useGradient = UserDefaults.standard.object(forKey: Self.useGradientKey) as? Bool ?? false
        lyricFontName = UserDefaults.standard.string(forKey: Self.lyricFontNameKey)
        isPositionLocked = UserDefaults.standard.object(forKey: Self.positionLockedKey) as? Bool ?? false
        let appearanceRawValue = UserDefaults.standard.object(forKey: Self.appearanceModeKey) as? Int
        appearanceMode = OverlayAppearanceMode(rawValue: appearanceRawValue ?? OverlayAppearanceMode.system.rawValue) ?? .system
        let chineseDisplayRawValue = UserDefaults.standard.object(forKey: Self.chineseDisplayModeKey) as? Int
        chineseDisplayMode = ChineseDisplayMode(rawValue: chineseDisplayRawValue ?? ChineseDisplayMode.simplified.rawValue) ?? .simplified
        isTranslationEnabled = UserDefaults.standard.object(forKey: Self.translationEnabledKey) as? Bool ?? true
        launchAtLoginEnabled = UserDefaults.standard.object(forKey: Self.launchAtLoginEnabledKey) as? Bool ?? true
        let lyricBarDisplayRawValue = UserDefaults.standard.object(forKey: Self.lyricBarDisplayModeKey) as? Int
        lyricBarDisplayMode = LyricBarDisplayMode(rawValue: lyricBarDisplayRawValue ?? LyricBarDisplayMode.bar.rawValue) ?? .bar
        let lyricAnimationRawValue = UserDefaults.standard.object(forKey: Self.lyricAnimationModeKey) as? Int
        lyricAnimationMode = LyricAnimationMode(rawValue: lyricAnimationRawValue ?? LyricAnimationMode.stable.rawValue) ?? .stable
    }

    var metrics: OverlayMetrics {
        sizePreset.metrics
    }

    var primaryTextStyle: AnyShapeStyle {
        if useGradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [lyricBaseColor.color, lyricGradientColor.color],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }

        return AnyShapeStyle(lyricBaseColor.color)
    }

    var secondaryTextStyle: AnyShapeStyle {
        if useGradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [lyricBaseColor.color.opacity(0.94), lyricGradientColor.color.opacity(0.82)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }

        return AnyShapeStyle(lyricBaseColor.color.opacity(0.84))
    }

    var primaryGlowColor: Color {
        (useGradient ? lyricGradientColor : lyricBaseColor).color
    }

    var preferredColorScheme: ColorScheme? {
        appearanceMode.preferredColorScheme
    }

    var showsLyricBarBackground: Bool {
        lyricBarDisplayMode.showsBackground
    }

    func displayChineseText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
            let converted = trimmed.applyingTransform(chineseDisplayMode.transform, reverse: false)
        else {
            return text
        }

        return converted
    }

    func displayPrimaryLyric(_ text: String) -> String {
        displayChineseText(text)
    }

    func contentWidth(topLine: String, bottomLine: String) -> CGFloat {
        let metrics = metrics
        let measuredTopWidth = measuredLineWidth(topLine, font: nsTopFont(size: metrics.topFontSize))
        let measuredBottomWidth = measuredLineWidth(bottomLine, font: nsBottomFont(size: metrics.bottomFontSize))
        let rawWidth = max(measuredTopWidth, measuredBottomWidth) + (metrics.horizontalPadding * 2) + 28
        let steppedWidth = ceil(rawWidth / metrics.windowWidthStep) * metrics.windowWidthStep
        return metrics.clampedContentWidth(steppedWidth)
    }

    func resetColors() {
        lyricBaseColor = .defaultBase
        lyricGradientColor = .defaultGradient
        useGradient = false
    }

    func saveWindowPosition(screenIdentifier: String?, relativeCenterX: CGFloat, relativeMinY: CGFloat) {
        let position = StoredWindowPosition(
            screenIdentifier: screenIdentifier,
            relativeCenterX: Double(relativeCenterX),
            relativeMinY: Double(relativeMinY)
        )
        guard let data = try? JSONEncoder().encode(position) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.windowPositionKey)
    }

    func savedWindowPosition() -> StoredWindowPosition? {
        guard
            let data = UserDefaults.standard.data(forKey: Self.windowPositionKey)
        else {
            return nil
        }

        if let position = try? JSONDecoder().decode(StoredWindowPosition.self, from: data) {
            return position
        }

        if let legacyPosition = try? JSONDecoder().decode(LegacyStoredWindowPosition.self, from: data) {
            return StoredWindowPosition(
                screenIdentifier: nil,
                relativeCenterX: legacyPosition.centerX,
                relativeMinY: legacyPosition.minY
            )
        }

        return nil
    }

    func topFont(size: CGFloat) -> Font {
        customFont(size: size) ?? .system(size: size, weight: .medium, design: .default)
    }

    func bottomFont(size: CGFloat) -> Font {
        customFont(size: size) ?? .system(size: size, weight: .regular, design: .default)
    }

    func resetFont() {
        lyricFontName = nil
    }

    private func customFont(size: CGFloat) -> Font? {
        guard let lyricFontName, !lyricFontName.isEmpty else {
            return nil
        }

        return .custom(lyricFontName, size: size)
    }

    private func nsTopFont(size: CGFloat) -> NSFont {
        customNSFont(size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    private func nsBottomFont(size: CGFloat) -> NSFont {
        customNSFont(size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private func customNSFont(size: CGFloat) -> NSFont? {
        guard let lyricFontName, !lyricFontName.isEmpty else {
            return nil
        }

        return NSFont(name: lyricFontName, size: size)
    }

    private func measuredLineWidth(_ text: String, font: NSFont) -> CGFloat {
        let sample = text.isEmpty ? " " : text.replacingOccurrences(of: "\n", with: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = NSString(string: sample).size(withAttributes: attributes).width
        return measured
    }

    private func saveColor(_ color: StoredColor, key: String) {
        guard let data = try? JSONEncoder().encode(color) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadColor(forKey key: String) -> StoredColor? {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let color = try? JSONDecoder().decode(StoredColor.self, from: data)
        else {
            return nil
        }

        return color
    }
}

private enum LyricDisplayMode: Equatable {
    case chineseOnly
    case translated
    case originalOnly
}

private enum AppError: Error, LocalizedError {
    case emptyResponse
    case invalidMusicState

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "No response was returned."
        case .invalidMusicState:
            return "Unable to read the current Music playback state."
        }
    }
}

private final class AppleScriptRunner {
    func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AppleScriptRunner",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? output : error]
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AppInstanceLock {
    private static let lockFileName = "com.yaoly.applemusiclyrics.instance.lock"
    private static let relaunchNotificationName = Notification.Name("com.yaoly.applemusiclyrics.relaunch")

    static func acquire() -> Int32? {
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(lockFileName)
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return nil
        }

        return descriptor
    }

    static func signalExistingInstance() {
        DistributedNotificationCenter.default().post(
            name: relaunchNotificationName,
            object: nil,
            userInfo: nil
        )
    }

    static var relaunchNotification: Notification.Name {
        relaunchNotificationName
    }
}

private actor MusicClient {
    private let runner = AppleScriptRunner()

    func currentSnapshot() throws -> MusicSnapshot? {
        let script = """
        tell application "Music"
            if it is not running then
                return ""
            end if

            if not (exists current track) then
                return ""
            end if

            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set trackState to player state as text
            set trackFavorited to favorited of current track

            return trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration as text) & "||" & (trackPosition as text) & "||" & trackState & "||" & (trackFavorited as text)
        end tell
        """

        let output = try runner.run(script)
        guard !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "||")
        guard parts.count == 7, let position = TimeInterval(parts[4]) else {
            throw AppError.invalidMusicState
        }

        return MusicSnapshot(
            trackKey: TrackKey(title: parts[0], artist: parts[1]),
            album: parts[2],
            duration: TimeInterval(parts[3]) ?? 0,
            position: position,
            isPlaying: parts[5] == "playing",
            isFavorited: parts[6] == "true"
        )
    }

    func setCurrentTrackFavorited(_ favorited: Bool) throws {
        let script = """
        tell application "Music"
            if it is not running then
                return ""
            end if

            if not (exists current track) then
                return ""
            end if

            set favorited of current track to \(favorited ? "true" : "false")
            return "ok"
        end tell
        """

        _ = try runner.run(script)
    }

    func currentTrackLyrics() throws -> String? {
        let script = """
        tell application "Music"
            if it is not running then
                return ""
            end if

            if not (exists current track) then
                return ""
            end if

            set trackLyrics to lyrics of current track
            if trackLyrics is missing value then
                return ""
            end if

            return trackLyrics as text
        end tell
        """

        let output = try runner.run(script)
        return output.isEmpty ? nil : output
    }
}

private actor LyricsClient {
    private let decoder = JSONDecoder()
    private let providers = LyricsProviderKind.allCases
    private var cache: [String: LyricFetchResult] = [:]
    private let persistentCache = LyricsPersistentCache.shared

    func lyrics(for snapshot: MusicSnapshot, localLyrics: String?) async throws -> LyricsPayload {
        let localPlainLyrics = localLyrics.flatMap { lyrics in
            let parsed = parsePlainLyrics(lyrics)
            return parsed.isEmpty ? nil : parsed
        }

        for query in LyricLookupQuery(snapshot: snapshot).candidateQueries() {
            if let cached = cache[query.cacheKey] {
                return cached.payload
            }
        }

        for query in LyricLookupQuery(snapshot: snapshot).candidateQueries() {
            if let fetched = try await fetchLyrics(for: query, localPlainLyrics: localPlainLyrics) {
                cache[query.cacheKey] = fetched
                return fetched.payload
            }
        }

        return .none
    }

    private func fetchLyrics(for query: LyricLookupQuery, localPlainLyrics: [String]?) async throws -> LyricFetchResult? {
        for provider in providers {
            switch provider {
            case .lrclib:
                if let lines = try await fetchLRCLibLyrics(for: query) {
                    return LyricFetchResult(provider: provider, payload: .synced(lines))
                }
            case .musicLocal:
                if let localPlainLyrics {
                    await persistentCache.storePlainLyrics(localPlainLyrics, for: query.cacheKey, provider: provider)
                    return LyricFetchResult(provider: provider, payload: .plain(localPlainLyrics))
                }

                if let cachedLyrics = await persistentCache.plainLyrics(for: query.cacheKey, provider: provider) {
                    return LyricFetchResult(provider: provider, payload: .plain(cachedLyrics))
                }
            case .lyricsOvh:
                if let cachedLyrics = await persistentCache.plainLyrics(for: query.cacheKey, provider: provider) {
                    return LyricFetchResult(provider: provider, payload: .plain(cachedLyrics))
                }

                if let lines = try await fetchLyricsOVHPlainLyrics(for: query) {
                    await persistentCache.storePlainLyrics(lines, for: query.cacheKey, provider: provider)
                    return LyricFetchResult(provider: provider, payload: .plain(lines))
                }
            }
        }

        return nil
    }

    private func fetchLRCLibLyrics(for query: LyricLookupQuery) async throws -> [LyricLine]? {
        if let result = try await fetchLRCLibGet(query: query),
           let syncedLyrics = result.syncedLyrics,
           !syncedLyrics.isEmpty {
            return parseLRC(syncedLyrics)
        }

        if let result = try await fetchLRCLibSearch(query: query),
           let syncedLyrics = result.syncedLyrics,
           !syncedLyrics.isEmpty {
            return parseLRC(syncedLyrics)
        }

        return nil
    }

    private func fetchLyricsOVHPlainLyrics(for query: LyricLookupQuery) async throws -> [String]? {
        guard !query.title.isEmpty, !query.artist.isEmpty else {
            return nil
        }

        let baseURL = URL(string: "https://api.lyrics.ovh/v1")!
        let url = baseURL
            .appendingPathComponent(query.artist)
            .appendingPathComponent(query.title)

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                let result = try? decoder.decode(LyricsOVHResult.self, from: data)
            else {
                return nil
            }

            let lines = parsePlainLyrics(result.lyrics)
            return lines.isEmpty ? nil : lines
        } catch {
            return nil
        }
    }

    private func fetchLRCLibGet(query: LyricLookupQuery) async throws -> LRCLibResult? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album),
        ]

        guard let url = components?.url else {
            throw AppError.emptyResponse
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }

            guard http.statusCode == 200 else {
                return nil
            }

            return try decoder.decode(LRCLibResult.self, from: data)
        } catch {
            return nil
        }
    }

    private func fetchLRCLibSearch(query: LyricLookupQuery) async throws -> LRCLibResult? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]

        guard let url = components?.url else {
            throw AppError.emptyResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        let results = try decoder.decode([LRCLibResult].self, from: data)
        return results.first { ($0.syncedLyrics?.isEmpty == false) }
    }

    private func parseLRC(_ raw: String) -> [LyricLine] {
        let linePattern = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]"#)
        var parsed: [LyricLine] = []

        for row in raw.split(separator: "\n") {
            let line = String(row)
            guard let regex = linePattern else {
                continue
            }

            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard !matches.isEmpty else {
                continue
            }

            let text = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                continue
            }

            for match in matches {
                guard
                    let minuteRange = Range(match.range(at: 1), in: line),
                    let secondRange = Range(match.range(at: 2), in: line)
                else {
                    continue
                }

                let minute = Double(line[minuteRange]) ?? 0
                let second = Double(line[secondRange]) ?? 0

                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let fractionText = String(line[fractionRange])
                    if fractionText.count == 2 {
                        fraction = (Double(fractionText) ?? 0) / 100
                    } else {
                        fraction = (Double(fractionText) ?? 0) / 1000
                    }
                }

                parsed.append(
                    LyricLine(
                        timestamp: minute * 60 + second + fraction,
                        text: text
                    )
                )
            }
        }

        return parsed.sorted { $0.timestamp < $1.timestamp }
    }

    private func parsePlainLyrics(_ raw: String) -> [String] {
        let timeTagPattern = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]"#)
        var parsed: [String] = []

        for row in raw.split(whereSeparator: \.isNewline) {
            var line = String(row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            if let regex = timeTagPattern {
                line = regex
                    .stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !line.isEmpty else {
                continue
            }

            if line.range(of: #"^\[[^\]]+\]$"#, options: .regularExpression) != nil {
                continue
            }

            parsed.append(line)
        }

        return parsed
    }
}

@MainActor
private final class OverlayViewModel: ObservableObject {
    @Published var topLine = "Waiting for Apple Music..."
    @Published var bottomLine = "Original lyrics will appear on top, translation on the bottom."
    @Published var isActive = false
    @Published var primaryTranslationRequest: TranslationRequest?
    @Published var secondaryTranslationRequest: TranslationRequest?
    @Published var translationMessage = ""
    @Published var currentTrackTitle = "未在播放"
    @Published var currentTrackArtist = ""
    @Published var currentTrackFavorited = false

    private let musicClient = MusicClient()
    private let lyricClient = LyricsClient()
    private var pollingTask: Task<Void, Never>?
    private var lyricsLoadTask: Task<Void, Never>?
    private var currentTrackKey: TrackKey?
    private var currentLyricsPayload: LyricsPayload = .none
    private var translationCache: [String: String] = [:]
    private var inFlightTranslations: Set<String> = []
    private var pendingTranslationQueue: [TranslationRequest] = []
    private var currentSourceLineText = ""
    private var currentDisplayMode: LyricDisplayMode = .originalOnly
    private var currentSyncedLineIndex: Int?
    private var lastObservedPlaybackPosition: TimeInterval?
    private var isTranslationEnabled = true
    private let translationPrefetchLeadCount = 1
    private let lyricBackwardHoldTolerance: TimeInterval = 0.28
    private let lyricSeekJumpThreshold: TimeInterval = 1.2

    private func animateOverlayChange(_ updates: () -> Void) {
        withAnimation(.easeOut(duration: 0.18)) {
            updates()
        }
    }

    func start() {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .milliseconds(260))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lyricsLoadTask?.cancel()
        lyricsLoadTask = nil
    }

    func applyTranslation(_ translatedText: String, for originalText: String) {
        guard !originalText.isEmpty else {
            return
        }

        let normalizedText = normalizedTranslationText(translatedText)
        guard !normalizedText.isEmpty else {
            finishTranslationRequest(for: originalText)
            return
        }

        translationCache[originalText] = normalizedText
        Task {
            await TranslationPersistentCache.shared.store(normalizedText, for: originalText)
        }
        finishTranslationRequest(for: originalText)
        guard currentSourceLineText == originalText else {
            return
        }

        animateOverlayChange {
            translationMessage = ""

            switch currentDisplayMode {
            case .chineseOnly:
                if !normalizedText.isEmpty {
                    topLine = normalizedText
                    bottomLine = ""
                    logDisplay()
                }
            case .translated:
                if isTranslationEnabled, !normalizedText.isEmpty {
                    bottomLine = normalizedText
                    logDisplay()
                }
            case .originalOnly:
                break
            }
        }
    }

    func setTranslationEnabled(_ enabled: Bool) {
        guard isTranslationEnabled != enabled else {
            return
        }

        isTranslationEnabled = enabled

        if !enabled {
            pendingTranslationQueue.removeAll()
            primaryTranslationRequest = nil
            secondaryTranslationRequest = nil
            inFlightTranslations.removeAll()
            translationMessage = ""

            if currentDisplayMode == .translated {
                animateOverlayChange {
                    bottomLine = ""
                    logDisplay()
                }
            }

            return
        }

        guard !currentSourceLineText.isEmpty else {
            return
        }

        if displayMode(for: currentSourceLineText) == .translated {
            if let translated = translationCache[currentSourceLineText] {
                animateOverlayChange {
                    bottomLine = translated
                    logDisplay()
                }
            } else {
                enqueueTranslation(for: currentSourceLineText)
            }
        }
    }

    private func refresh() async {
        do {
            guard let snapshot = try await musicClient.currentSnapshot() else {
                showIdleState("Apple Music is not playing.")
                return
            }

            currentTrackTitle = snapshot.trackKey.title
            currentTrackArtist = snapshot.trackKey.artist
            currentTrackFavorited = snapshot.isFavorited

            if snapshot.trackKey != currentTrackKey {
                handleTrackChange(to: snapshot)
            }

            updateDisplay(for: snapshot)
        } catch {
            showIdleState(error.localizedDescription)
        }
    }

    private func updateDisplay(for snapshot: MusicSnapshot) {
        switch currentLyricsPayload {
        case .none:
            showTrackPlaceholder(for: snapshot)
            currentSourceLineText = ""
            currentDisplayMode = .originalOnly
        case .synced(let lines):
            updateSyncedDisplay(for: snapshot, lines: lines)
        case .plain(let lines):
            updatePlainDisplay(for: snapshot, lines: lines)
        }
    }

    private func updateSyncedDisplay(for snapshot: MusicSnapshot, lines: [LyricLine]) {
        guard let currentIndex = stableLineIndex(at: snapshot.position, in: lines) else {
            showTrackPlaceholder(for: snapshot)
            currentSourceLineText = ""
            currentDisplayMode = .originalOnly
            currentSyncedLineIndex = nil
            return
        }

        let currentLine = lines[currentIndex]
        prefetchTranslations(around: currentIndex, in: lines)
        updateDisplayedLine(currentLine.text)
    }

    private func updatePlainDisplay(for snapshot: MusicSnapshot, lines: [String]) {
        guard let currentIndex = plainLineIndex(for: snapshot, in: lines) else {
            showTrackPlaceholder(for: snapshot)
            currentSourceLineText = ""
            currentDisplayMode = .originalOnly
            return
        }

        let currentLine = lines[currentIndex]
        prefetchTranslations(around: currentIndex, in: lines)
        updateDisplayedLine(currentLine)
    }

    private func updateDisplayedLine(_ text: String) {
        let mode = displayMode(for: text)
        isActive = true

        if currentSourceLineText != text {
            currentSourceLineText = text
            currentDisplayMode = mode

            animateOverlayChange {
                switch currentDisplayMode {
                case .chineseOnly:
                    topLine = translationCache[text] ?? text
                    bottomLine = ""
                    logDisplay()
                    if isTranslationEnabled {
                        requestTranslationIfNeeded(for: text, mode: currentDisplayMode)
                    }
                case .translated:
                    topLine = text
                    bottomLine = isTranslationEnabled ? (translationCache[text] ?? "") : ""
                    logDisplay()
                    if isTranslationEnabled {
                        requestTranslationIfNeeded(for: text, mode: currentDisplayMode, priority: true)
                    }
                case .originalOnly:
                    topLine = text
                    bottomLine = ""
                    logDisplay()
                }
            }
        }
    }

    private func handleTrackChange(to snapshot: MusicSnapshot) {
        lyricsLoadTask?.cancel()
        currentTrackKey = snapshot.trackKey
        currentSourceLineText = ""
        currentDisplayMode = .originalOnly
        currentLyricsPayload = .none
        currentSyncedLineIndex = nil
        lastObservedPlaybackPosition = nil
        translationCache.removeAll()
        pendingTranslationQueue.removeAll()
        primaryTranslationRequest = nil
        secondaryTranslationRequest = nil
        inFlightTranslations.removeAll()
        showTrackPlaceholder(for: snapshot)

        let trackKey = snapshot.trackKey
        lyricsLoadTask = Task { [weak self, musicClient, lyricClient] in
            guard let self else { return }

            let localLyrics = try? await musicClient.currentTrackLyrics()
            let payload = (try? await lyricClient.lyrics(for: snapshot, localLyrics: localLyrics)) ?? .none

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard self.currentTrackKey == trackKey else {
                    return
                }

                self.currentLyricsPayload = payload
            }
        }
    }

    private func showTrackPlaceholder(for snapshot: MusicSnapshot) {
        animateOverlayChange {
            isActive = false
            topLine = snapshot.trackKey.title
            bottomLine = snapshot.trackKey.artist
            logDisplay()
        }
    }

    private func stableLineIndex(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard let rawIndex = lineIndex(at: position, in: lines) else {
            currentSyncedLineIndex = nil
            lastObservedPlaybackPosition = position
            return nil
        }

        defer {
            lastObservedPlaybackPosition = position
        }

        guard let currentIndex = currentSyncedLineIndex, currentIndex < lines.count else {
            currentSyncedLineIndex = rawIndex
            return rawIndex
        }

        let delta = position - (lastObservedPlaybackPosition ?? position)
        if abs(delta) >= lyricSeekJumpThreshold {
            currentSyncedLineIndex = rawIndex
            return rawIndex
        }

        if rawIndex >= currentIndex {
            currentSyncedLineIndex = rawIndex
            return rawIndex
        }

        let currentTimestamp = lines[currentIndex].timestamp
        if position >= currentTimestamp - lyricBackwardHoldTolerance {
            return currentIndex
        }

        currentSyncedLineIndex = rawIndex
        return rawIndex
    }

    private func lineIndex(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else {
            return nil
        }

        var low = 0
        var high = lines.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timestamp <= position {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }

    private func plainLineIndex(for snapshot: MusicSnapshot, in lines: [String]) -> Int? {
        guard !lines.isEmpty else {
            return nil
        }

        let effectiveDuration = max(snapshot.duration, snapshot.position + 1, 1)
        let progress = min(max(snapshot.position / effectiveDuration, 0), 0.999_999)
        return min(lines.count - 1, Int(progress * Double(lines.count)))
    }

    private func showIdleState(_ message: String) {
        lyricsLoadTask?.cancel()
        lyricsLoadTask = nil
        animateOverlayChange {
            isActive = false
            currentTrackKey = nil
            currentLyricsPayload = .none
            currentSyncedLineIndex = nil
            lastObservedPlaybackPosition = nil
            translationCache.removeAll()
            inFlightTranslations.removeAll()
            pendingTranslationQueue.removeAll()
            currentSourceLineText = ""
            currentDisplayMode = .originalOnly
            primaryTranslationRequest = nil
            secondaryTranslationRequest = nil
            translationMessage = ""
            currentTrackTitle = "未在播放"
            currentTrackArtist = ""
            currentTrackFavorited = false
            topLine = "Apple Music Desktop Lyrics"
            bottomLine = message
            logDisplay()
        }
    }

    func toggleCurrentTrackFavorited() {
        Task { [weak self] in
            guard let self else { return }

            do {
                guard let snapshot = try await musicClient.currentSnapshot() else {
                    return
                }

                try await musicClient.setCurrentTrackFavorited(!snapshot.isFavorited)
                await refresh()
            } catch {
                print("[overlay] favorite-toggle-error", error.localizedDescription)
                fflush(stdout)
            }
        }
    }

    private func requestTranslationIfNeeded(for text: String, mode: LyricDisplayMode, priority: Bool = false) {
        guard !text.isEmpty else {
            return
        }

        switch mode {
        case .chineseOnly:
            translationMessage = ""
            return
        case .translated:
            break
        case .originalOnly:
            translationMessage = ""
            return
        }

        enqueueTranslation(for: text, priority: priority)
    }

    private func displayMode(for text: String) -> LyricDisplayMode {
        if requiresSimplifiedChineseTranslation(for: text) {
            return .translated
        }

        if text.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return .chineseOnly
        }

        return .originalOnly
    }

    func handleTranslationUnavailable(for text: String, message: String) {
        finishTranslationRequest(for: text)
        guard currentSourceLineText == text else {
            return
        }

        animateOverlayChange {
            translationMessage = ""
            switch currentDisplayMode {
            case .chineseOnly:
                topLine = text
                bottomLine = ""
            case .translated, .originalOnly:
                bottomLine = ""
            }
            logDisplay()
        }
    }

    private func logDisplay() {
        let top = topLine.replacingOccurrences(of: "\n", with: " ")
        let bottom = bottomLine.replacingOccurrences(of: "\n", with: " ")
        print("[overlay]", top, "|||", bottom)
        fflush(stdout)
    }

    private func prefetchTranslations(around currentIndex: Int, in lines: [LyricLine]) {
        guard isTranslationEnabled, !lines.isEmpty else {
            return
        }

        let endIndex = min(lines.count - 1, currentIndex + translationPrefetchLeadCount)
        for index in currentIndex...endIndex {
            let text = lines[index].text
            if displayMode(for: text) == .translated {
                enqueueTranslation(for: text, priority: index == currentIndex)
            }
        }
    }

    private func prefetchTranslations(around currentIndex: Int, in lines: [String]) {
        guard isTranslationEnabled, !lines.isEmpty else {
            return
        }

        let endIndex = min(lines.count - 1, currentIndex + translationPrefetchLeadCount)
        for index in currentIndex...endIndex {
            let text = lines[index]
            if displayMode(for: text) == .translated {
                enqueueTranslation(for: text, priority: index == currentIndex)
            }
        }
    }

    private func enqueueTranslation(for text: String, priority: Bool = false) {
        guard
            isTranslationEnabled,
            !text.isEmpty,
            let queryText = translationInput(for: text)
        else {
            return
        }

        if translationCache[text] != nil {
            return
        }

        if let pendingIndex = pendingTranslationQueue.firstIndex(where: { $0.sourceText == text }) {
            if priority, pendingIndex != 0 {
                let request = pendingTranslationQueue.remove(at: pendingIndex)
                pendingTranslationQueue.insert(request, at: 0)
            }
            requestNextTranslationIfNeeded()
            return
        }

        if inFlightTranslations.contains(text) {
            return
        }

        let request = TranslationRequest(sourceText: text, queryText: queryText)
        inFlightTranslations.insert(text)
        if priority {
            pendingTranslationQueue.insert(request, at: 0)
        } else {
            pendingTranslationQueue.append(request)
        }
        requestNextTranslationIfNeeded()
    }

    private func requestNextTranslationIfNeeded() {
        while !pendingTranslationQueue.isEmpty {
            if primaryTranslationRequest == nil {
                primaryTranslationRequest = pendingTranslationQueue.removeFirst()
                continue
            }

            if secondaryTranslationRequest == nil {
                secondaryTranslationRequest = pendingTranslationQueue.removeFirst()
                continue
            }

            break
        }
    }

    private func finishTranslationRequest(for text: String) {
        inFlightTranslations.remove(text)
        if primaryTranslationRequest?.sourceText == text {
            primaryTranslationRequest = nil
        }
        if secondaryTranslationRequest?.sourceText == text {
            secondaryTranslationRequest = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.requestNextTranslationIfNeeded()
        }
    }

    private func translationInput(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard requiresSimplifiedChineseTranslation(for: trimmed) else {
            return nil
        }

        return trimmed
    }

    private func requiresSimplifiedChineseTranslation(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let containsHan = trimmed.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let containsForeignScript = trimmed.range(
            of: #"\p{Latin}|\p{Hangul}|[\p{Hiragana}\p{Katakana}]|\p{Cyrillic}|\p{Greek}|\p{Arabic}|\p{Hebrew}|\p{Thai}|\p{Devanagari}"#,
            options: .regularExpression
        ) != nil

        if containsForeignScript {
            return true
        }

        guard containsHan else {
            return false
        }

        guard
            let converted = trimmed.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false)
        else {
            return false
        }

        return converted != trimmed
    }
}

private struct OverlayRootView: View {
    @ObservedObject var model: OverlayViewModel
    @ObservedObject var settings: OverlaySettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var primaryTranslationTask: Task<Void, Never>?
    @State private var secondaryTranslationTask: Task<Void, Never>?
    @State private var displayedContentWidth: CGFloat = 0

    var body: some View {
        let metrics = settings.metrics
        let displayedTopLine = settings.displayPrimaryLyric(model.topLine)
        let displayedBottomLine = settings.displayChineseText(model.bottomLine)
        let targetContentWidth = settings.contentWidth(topLine: displayedTopLine, bottomLine: displayedBottomLine)
        let glassTopColor = colorScheme == .dark
            ? Color.white.opacity(model.isActive ? OverlayStyle.glassFillOpacity : OverlayStyle.glassFillOpacity * 0.5)
            : Color.white.opacity(model.isActive ? 0.22 : 0.14)
        let glassBottomColor = colorScheme == .dark
            ? Color.white.opacity(model.isActive ? OverlayStyle.glassFillOpacity * 0.24 : OverlayStyle.glassFillOpacity * 0.12)
            : Color.white.opacity(model.isActive ? 0.10 : 0.06)
        let glassStrokeTopColor = colorScheme == .dark
            ? Color.white.opacity(model.isActive ? OverlayStyle.glassStrokeOpacity : OverlayStyle.glassStrokeOpacity * 0.5)
            : Color.white.opacity(model.isActive ? 0.45 : 0.25)
        let glassStrokeBottomColor = colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.06)
        let cardShadowColor = colorScheme == .dark ? Color.black.opacity(0.10) : Color.black.opacity(0.14)
        let showsLyricBarBackground = settings.showsLyricBarBackground
        let lyricAnimationMode = settings.lyricAnimationMode

        ZStack {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(model.isActive ? OverlayStyle.activeBackgroundOpacity : OverlayStyle.inactiveBackgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(OverlayStyle.borderOpacity), lineWidth: 1)
                )

            VStack(spacing: metrics.lineSpacing) {
                AnimatedLyricContent(
                    identity: "top|\(displayedTopLine)",
                    mode: lyricAnimationMode,
                    role: .primary
                ) {
                    PrimaryFloatingLyricText(
                        text: displayedTopLine,
                        font: settings.topFont(size: metrics.topFontSize),
                        textStyle: settings.primaryTextStyle,
                        accentColor: settings.primaryGlowColor,
                        minHeight: metrics.topFontSize * 1.18
                    )
                }
                    .frame(maxWidth: .infinity, minHeight: metrics.topFontSize * 1.18)

                AnimatedLyricContent(
                    identity: "bottom|\(displayedBottomLine.isEmpty ? " " : displayedBottomLine)",
                    mode: lyricAnimationMode,
                    role: .secondary
                ) {
                    SecondaryFloatingLyricText(
                        text: displayedBottomLine,
                        font: settings.bottomFont(size: metrics.bottomFontSize),
                        minHeight: metrics.bottomFontSize * 1.08,
                        isVisible: !displayedBottomLine.isEmpty
                    )
                }
                    .frame(maxWidth: .infinity, minHeight: metrics.bottomFontSize * 1.08)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(width: displayedContentWidth)
            .background {
                if showsLyricBarBackground {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)

                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        glassTopColor,
                                        glassBottomColor
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Capsule(style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        glassStrokeTopColor,
                                        glassStrokeBottomColor
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )

                        Capsule(style: .continuous)
                            .fill(settings.primaryGlowColor.opacity(model.isActive ? OverlayStyle.ambientAuraOpacity : OverlayStyle.ambientAuraOpacity * 0.45))
                            .blur(radius: 12)
                            .padding(.horizontal, -6)
                            .padding(.vertical, -2)
                    }
                    .shadow(color: cardShadowColor, radius: 14, x: 0, y: 6)
                    .allowsHitTesting(false)
                }
            }
        }
        .preferredColorScheme(settings.preferredColorScheme)
        .frame(width: displayedContentWidth, height: metrics.contentHeight)
        .padding(metrics.outerPadding)
        .opacity(model.isActive ? 1 : OverlayStyle.inactiveOverlayOpacity)
        .animation(.easeInOut(duration: 0.18), value: model.isActive)
        .animation(.easeOut(duration: OverlayStyle.lyricWidthAnimationDuration), value: displayedContentWidth)
        .onAppear {
            displayedContentWidth = targetContentWidth
            model.start()
        }
        .onDisappear {
            model.stop()
            primaryTranslationTask?.cancel()
            secondaryTranslationTask?.cancel()
        }
        .onChange(of: targetContentWidth) { _, newValue in
            updateDisplayedContentWidth(target: newValue, step: metrics.windowWidthStep)
        }
        .onChange(of: model.primaryTranslationRequest) { _, newValue in
            primaryTranslationTask?.cancel()
            guard let request = newValue else {
                primaryTranslationTask = nil
                return
            }

            primaryTranslationTask = Task {
                await translate(request)
            }
        }
        .onChange(of: model.secondaryTranslationRequest) { _, newValue in
            secondaryTranslationTask?.cancel()
            guard let request = newValue else {
                secondaryTranslationTask = nil
                return
            }

            secondaryTranslationTask = Task {
                await translate(request)
            }
        }
    }

    private func updateDisplayedContentWidth(target: CGFloat, step: CGFloat) {
        if displayedContentWidth <= 0 {
            displayedContentWidth = target
            return
        }

        let delta = target - displayedContentWidth
        if delta > step * 0.6 {
            displayedContentWidth = target
        }
    }

    private func translate(_ request: TranslationRequest) async {
        if let cachedTranslation = await TranslationPersistentCache.shared.translation(for: request.sourceText) {
            await MainActor.run {
                model.applyTranslation(cachedTranslation, for: request.sourceText)
            }
            return
        }

        let translatedText = await translatedTextWithRetry(for: request)

        guard !Task.isCancelled else {
            return
        }

        if let translatedText, !translatedText.isEmpty {
            await MainActor.run {
                model.applyTranslation(translatedText, for: request.sourceText)
            }
        } else {
            await MainActor.run {
                model.handleTranslationUnavailable(for: request.sourceText, message: "")
            }
        }
    }

    private func translatedTextWithRetry(for request: TranslationRequest) async -> String? {
        for attempt in 0..<2 {
            guard !Task.isCancelled else {
                return nil
            }

            do {
                let translatedText: String? = try await runWithTimeout(translationRequestTimeout) {
                    if let fallbackText = await TranslationFallbackClient.shared.translate(request.queryText) {
                        return Optional(fallbackText)
                    }
                    return nil
                }

                if let translatedText, !translatedText.isEmpty {
                    return translatedText
                }
            } catch is TranslationTimeoutError {
                // Retry once before giving up so transient slow responses do not drop the translation.
            } catch {
                // Retry once before giving up so transient network errors do not drop the translation.
            }

            guard attempt == 0, !Task.isCancelled else {
                break
            }

            try? await Task.sleep(for: translationRetryDelay)
        }

        return nil
    }
}

private let contrastOutlineOffsets: [CGSize] = [
    CGSize(width: -0.72, height: 0),
    CGSize(width: 0.72, height: 0),
    CGSize(width: 0, height: -0.72),
    CGSize(width: 0, height: 0.72),
    CGSize(width: -0.56, height: -0.56),
    CGSize(width: 0.56, height: -0.56),
    CGSize(width: -0.56, height: 0.56),
    CGSize(width: 0.56, height: 0.56),
]

private struct ContrastOutlineTextLayer: View {
    let text: String
    let font: Font
    let color: Color
    let weight: Font.Weight
    let blur: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<contrastOutlineOffsets.count, id: \.self) { index in
                let offset = contrastOutlineOffsets[index]
                Text(text)
                    .font(font)
                    .fontWeight(weight)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .offset(x: offset.width, y: offset.height)
            }
        }
        .blur(radius: blur)
        .allowsHitTesting(false)
    }
}

private struct PrimaryFloatingLyricText: View {
    let text: String
    let font: Font
    let textStyle: AnyShapeStyle
    let accentColor: Color
    let minHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let displayText = text.isEmpty ? " " : text
        let highlightColor = colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.16)
        let outlineColor = Color.black.opacity(colorScheme == .dark ? 0.48 : 0.34)
        let primaryShadowColor = Color.black.opacity(colorScheme == .dark ? 0.48 : 0.26)
        let secondaryShadowColor = Color.black.opacity(colorScheme == .dark ? 0.13 : 0.06)

        ZStack {
            Text(displayText)
                .font(font)
                .foregroundStyle(accentColor.opacity(0.12))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .blur(radius: 5)
                .allowsHitTesting(false)

            ContrastOutlineTextLayer(
                text: displayText,
                font: font,
                color: outlineColor,
                weight: .medium,
                blur: 0.14
            )

            Text(displayText)
                .font(font)
                .foregroundStyle(highlightColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .offset(y: -0.4)
                .allowsHitTesting(false)

            Text(displayText)
                .font(font)
                .foregroundStyle(textStyle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .shadow(color: primaryShadowColor, radius: 3.1, x: 0, y: 1.7)
                .shadow(color: secondaryShadowColor, radius: 5.4, x: 0, y: 3.1)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

private struct AnimatedLyricContent<Content: View>: View {
    let identity: String
    let mode: LyricAnimationMode
    let role: LyricContentRole
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
                .id("\(mode.rawValue)|\(identity)")
                .transition(mode.transition(for: role))
        }
        .animation(mode.animation(for: role), value: identity)
        .animation(mode.animation(for: role), value: mode.rawValue)
    }
}

private struct LyricMotionTransitionModifier: ViewModifier {
    let yOffset: CGFloat
    let scale: CGFloat
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .center)
            .offset(y: yOffset)
    }
}

private struct LyricBlindsTransitionModifier: ViewModifier {
    let progress: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .mask {
                GeometryReader { proxy in
                    let stripeCount = 6
                    let stripeHeight = proxy.size.height / CGFloat(stripeCount)
                    VStack(spacing: 0) {
                        ForEach(0..<stripeCount, id: \.self) { _ in
                            Rectangle()
                                .frame(height: max(1, stripeHeight * progress))
                                .frame(maxWidth: .infinity)
                            if stripeCount > 1 {
                                Spacer(minLength: max(0, stripeHeight * (1 - progress)))
                            }
                        }
                    }
                }
            }
            .scaleEffect(x: 1, y: 0.94 + (0.06 * progress), anchor: .center)
    }
}

private struct SecondaryFloatingLyricText: View {
    let text: String
    let font: Font
    let minHeight: CGFloat
    let isVisible: Bool

    var body: some View {
        let displayText = text.isEmpty ? " " : text
        let textColor = Color.white.opacity(0.94)
        let outlineColor = Color.black.opacity(0.46)
        let primaryShadowColor = Color.black.opacity(0.34)
        let secondaryShadowColor = Color.black.opacity(0.10)

        ZStack {
            ContrastOutlineTextLayer(
                text: displayText,
                font: font,
                color: outlineColor,
                weight: .medium,
                blur: 0.12
            )

            Text(displayText)
                .font(font)
                .fontWeight(.medium)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .shadow(color: primaryShadowColor, radius: 2.0, x: 0, y: 1.1)
                .shadow(color: secondaryShadowColor, radius: 3.6, x: 0, y: 2.2)
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

private struct TranslationSettingsPanelView: View {
    @ObservedObject var model: TranslationSettingsPanelModel
    let onClose: () -> Void

    private var statusColor: Color {
        switch model.statusTone {
        case .neutral:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Secret ID")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("请输入 Secret ID", text: $model.secretId)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Secret Key")
                        .font(.system(size: 12, weight: .semibold))
                    SecureField("请输入 Secret Key", text: $model.secretKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text(model.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            HStack(spacing: 10) {
                Button("保存") {
                    model.save()
                }
                .keyboardShortcut(.defaultAction)

                Button(model.isTesting ? "测试中…" : "测试翻译") {
                    model.test()
                }
                .disabled(model.isTesting)

                Button("清除配置") {
                    model.clear()
                }

                Spacer()

                Button("关闭") {
                    onClose()
                }
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum ColorPanelTarget {
        case base
        case gradient
    }

    private var window: NSWindow?
    private var translationSettingsPanel: NSPanel?
    private var hostingView: OverlayHostingView<OverlayRootView>?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var currentTrackMenuItem: NSMenuItem?
    private var currentArtistMenuItem: NSMenuItem?
    private var favoriteMenuItem: NSMenuItem?
    private var positionLockMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var translationToggleMenuItem: NSMenuItem?
    private var sizeMenuItems: [OverlaySizePreset: NSMenuItem] = [:]
    private var appearanceMenuItems: [OverlayAppearanceMode: NSMenuItem] = [:]
    private var chineseDisplayMenuItems: [ChineseDisplayMode: NSMenuItem] = [:]
    private var lyricBarDisplayMenuItems: [LyricBarDisplayMode: NSMenuItem] = [:]
    private var lyricAnimationMenuItems: [LyricAnimationMode: NSMenuItem] = [:]
    private var currentFontMenuItem: NSMenuItem?
    private var resetFontMenuItem: NSMenuItem?
    private var gradientToggleMenuItem: NSMenuItem?
    private var colorPanelTarget: ColorPanelTarget = .base
    private var cancellables: Set<AnyCancellable> = []
    private var appliedContentWidth: CGFloat?
    private var statusItemMonitorTimer: Timer?
    private let model = OverlayViewModel()
    private let settings = OverlaySettings()
    private let translationSettingsModel = TranslationSettingsPanelModel()

    private func desiredContentWidth() -> CGFloat {
        settings.contentWidth(
            topLine: settings.displayPrimaryLyric(model.topLine),
            bottomLine: settings.displayChineseText(model.bottomLine)
        )
    }

    private func frame(for metrics: OverlayMetrics, contentWidth: CGFloat, preserving window: NSWindow? = nil) -> NSRect {
        let width = metrics.windowWidth(for: contentWidth)
        let height = metrics.minimumWindowHeight

        if let window {
            let currentFrame = window.frame
            let x = currentFrame.midX - (width / 2)
            return NSRect(x: x, y: currentFrame.minY, width: width, height: height)
        }

        guard let screenFrame = NSScreen.main?.visibleFrame else {
            return NSRect(x: 160, y: 80, width: width, height: height)
        }

        if let savedPosition = settings.savedWindowPosition() {
            if let savedFrame = restoredFrame(from: savedPosition, width: width, height: height) {
                return savedFrame
            }

            return defaultFrame(in: screenFrame, width: width, height: height)
        }

        return defaultFrame(in: screenFrame, width: width, height: height)
    }

    private func clampedFrame(_ frame: NSRect, inside visibleFrame: NSRect) -> NSRect {
        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visibleFrame.minX), visibleFrame.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visibleFrame.minY), visibleFrame.maxY - clamped.height)
        return clamped
    }

    private func defaultFrame(in visibleFrame: NSRect, width: CGFloat, height: CGFloat) -> NSRect {
        let x = visibleFrame.minX + ((visibleFrame.width - width) / 2)
        let y = visibleFrame.minY + OverlayStyle.windowBottomInset
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func restoredFrame(from position: StoredWindowPosition, width: CGFloat, height: CGFloat) -> NSRect? {
        if let screenIdentifier = position.screenIdentifier,
           let screen = screen(matching: screenIdentifier)
        {
            let visibleFrame = screen.visibleFrame
            let centerX = visibleFrame.minX + (visibleFrame.width * CGFloat(position.relativeCenterX))
            let minY = visibleFrame.minY + (visibleFrame.height * CGFloat(position.relativeMinY))
            let frame = NSRect(x: centerX - (width / 2), y: minY, width: width, height: height)
            return clampedFrame(frame, inside: visibleFrame)
        }

        if position.screenIdentifier == nil {
            // Backward compatibility for old absolute-position persistence.
            let legacyFrame = NSRect(
                x: CGFloat(position.relativeCenterX) - (width / 2),
                y: CGFloat(position.relativeMinY),
                width: width,
                height: height
            )
            if let bestScreen = bestScreen(for: legacyFrame) ?? NSScreen.main {
                return clampedFrame(legacyFrame, inside: bestScreen.visibleFrame)
            }
        }

        return nil
    }

    private func screen(matching identifier: String) -> NSScreen? {
        NSScreen.screens.first { screenIdentifier(for: $0) == identifier }
    }

    private func screenIdentifier(for screen: NSScreen) -> String? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return screenNumber.stringValue
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containingScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return containingScreen
        }

        return NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.visibleFrame, frame) < intersectionArea(rhs.visibleFrame, frame)
        }
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }

        return intersection.width * intersection.height
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRelaunchRequest),
            name: AppInstanceLock.relaunchNotification,
            object: nil
        )

        let contentView = OverlayRootView(model: model, settings: settings)
        let hostingView = OverlayHostingView(rootView: contentView)

        let initialContentWidth = desiredContentWidth()
        appliedContentWidth = initialContentWidth
        let frame = frame(for: settings.metrics, contentWidth: initialContentWidth)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.appearance = nil
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = !settings.isPositionLocked
        window.ignoresMouseEvents = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self

        self.window = window
        self.hostingView = hostingView
        hostingView.menuProvider = { [weak self] in
            self?.statusItem?.menu
        }
        applyWindowAppearance()
        window.makeKeyAndOrderFront(nil)
        model.start()
        ensureStatusItemVisible()
        startStatusItemMonitor()
        bindMenuState()
        resizeWindowToFitContent(animated: false, immediate: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStatusItemVisible()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistWindowPosition()
        statusItemMonitorTimer?.invalidate()
        statusItemMonitorTimer = nil
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: AppInstanceLock.relaunchNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            if
                let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("menubar-apple-music.png"),
                let icon = NSImage(contentsOf: resourceURL)
            {
                icon.isTemplate = true
                icon.size = NSSize(width: 15, height: 15)
                button.image = icon
                button.imageScaling = .scaleProportionallyDown
                button.imagePosition = .imageOnly
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
            } else {
                button.image = nil
                button.title = ""
                button.attributedTitle = NSAttributedString(
                    string: "♪",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                        .foregroundColor: NSColor.white,
                    ]
                )
                button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            }
            button.toolTip = "Apple Music Desktop Lyrics"
        }

        let menu = NSMenu()
        let trackItem = NSMenuItem(title: "未在播放", action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)

        let artistItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        artistItem.isEnabled = false
        menu.addItem(artistItem)

        let favoriteItem = NSMenuItem(title: "添加到我喜欢", action: #selector(toggleFavoriteCurrentTrack), keyEquivalent: "")
        favoriteItem.target = self
        menu.addItem(favoriteItem)

        menu.addItem(.separator())

        let positionLockItem = NSMenuItem(title: "固定歌词位置", action: #selector(togglePositionLock), keyEquivalent: "")
        positionLockItem.target = self
        menu.addItem(positionLockItem)

        let launchAtLoginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let translationToggleItem = NSMenuItem(title: "显示翻译", action: #selector(toggleTranslationEnabled), keyEquivalent: "")
        translationToggleItem.target = self
        menu.addItem(translationToggleItem)

        let translationSettingsItem = NSMenuItem(title: "翻译设置…", action: #selector(openTranslationSettings), keyEquivalent: "")
        translationSettingsItem.target = self
        menu.addItem(translationSettingsItem)

        menu.addItem(.separator())

        let sizeMenuItem = NSMenuItem(title: "歌词大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "歌词大小")
        for preset in OverlaySizePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectOverlaySize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            sizeMenu.addItem(item)
            sizeMenuItems[preset] = item
        }
        sizeMenuItem.submenu = sizeMenu
        menu.addItem(sizeMenuItem)

        let appearanceMenuItem = NSMenuItem(title: "外观模式", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "外观模式")
        for mode in OverlayAppearanceMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectAppearanceMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            appearanceMenu.addItem(item)
            appearanceMenuItems[mode] = item
        }
        appearanceMenuItem.submenu = appearanceMenu
        menu.addItem(appearanceMenuItem)

        let chineseDisplayMenuItem = NSMenuItem(title: "主体中文", action: nil, keyEquivalent: "")
        let chineseDisplayMenu = NSMenu(title: "主体中文")
        for mode in ChineseDisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectChineseDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            chineseDisplayMenu.addItem(item)
            chineseDisplayMenuItems[mode] = item
        }
        chineseDisplayMenuItem.submenu = chineseDisplayMenu
        menu.addItem(chineseDisplayMenuItem)

        let lyricBarDisplayMenuItem = NSMenuItem(title: "歌词栏样式", action: nil, keyEquivalent: "")
        let lyricBarDisplayMenu = NSMenu(title: "歌词栏样式")
        for mode in LyricBarDisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectLyricBarDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            lyricBarDisplayMenu.addItem(item)
            lyricBarDisplayMenuItems[mode] = item
        }
        lyricBarDisplayMenuItem.submenu = lyricBarDisplayMenu
        menu.addItem(lyricBarDisplayMenuItem)

        let lyricAnimationMenuItem = NSMenuItem(title: "歌词动效", action: nil, keyEquivalent: "")
        let lyricAnimationMenu = NSMenu(title: "歌词动效")
        for mode in LyricAnimationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectLyricAnimationMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            lyricAnimationMenu.addItem(item)
            lyricAnimationMenuItems[mode] = item
        }
        lyricAnimationMenuItem.submenu = lyricAnimationMenu
        menu.addItem(lyricAnimationMenuItem)

        let fontMenuItem = NSMenuItem(title: "歌词字体", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu(title: "歌词字体")

        let currentFontItem = NSMenuItem(title: "当前字体：系统默认", action: nil, keyEquivalent: "")
        currentFontItem.isEnabled = false
        fontMenu.addItem(currentFontItem)

        fontMenu.addItem(.separator())

        let selectFontItem = NSMenuItem(title: "选择字体…", action: #selector(openFontPanel), keyEquivalent: "")
        selectFontItem.target = self
        fontMenu.addItem(selectFontItem)

        let resetFontItem = NSMenuItem(title: "恢复系统字体", action: #selector(resetLyricFont), keyEquivalent: "")
        resetFontItem.target = self
        fontMenu.addItem(resetFontItem)

        fontMenuItem.submenu = fontMenu
        menu.addItem(fontMenuItem)

        menu.addItem(.separator())

        let colorMenuItem = NSMenuItem(title: "歌词颜色", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "歌词颜色")

        let gradientToggleItem = NSMenuItem(title: "使用渐变色", action: #selector(toggleGradientColor), keyEquivalent: "")
        gradientToggleItem.target = self
        colorMenu.addItem(gradientToggleItem)

        let baseColorItem = NSMenuItem(title: "基础色…", action: #selector(openBaseColorPanel), keyEquivalent: "")
        baseColorItem.target = self
        colorMenu.addItem(baseColorItem)

        let gradientColorItem = NSMenuItem(title: "渐变色…", action: #selector(openGradientColorPanel), keyEquivalent: "")
        gradientColorItem.target = self
        colorMenu.addItem(gradientColorItem)

        colorMenu.addItem(.separator())

        let resetColorItem = NSMenuItem(title: "恢复默认颜色", action: #selector(resetLyricColors), keyEquivalent: "")
        resetColorItem.target = self
        colorMenu.addItem(resetColorItem)

        colorMenuItem.submenu = colorMenu
        menu.addItem(colorMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitOverlay), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        self.statusMenu = menu
        self.currentTrackMenuItem = trackItem
        self.currentArtistMenuItem = artistItem
        self.favoriteMenuItem = favoriteItem
        self.positionLockMenuItem = positionLockItem
        self.launchAtLoginMenuItem = launchAtLoginItem
        self.translationToggleMenuItem = translationToggleItem
        self.currentFontMenuItem = currentFontItem
        self.resetFontMenuItem = resetFontItem
        self.gradientToggleMenuItem = gradientToggleItem
        syncTrackInfo()
        syncFavoriteMenuState()
        syncSizeMenuState()
        syncAppearanceMenuState()
        syncLaunchAtLoginMenuState()
        syncTranslationMenuState()
        syncChineseDisplayMenuState()
        syncLyricBarDisplayMenuState()
        syncLyricAnimationMenuState()
        syncPositionLockState()
        syncFontMenuState()
        syncColorMenuState()
    }

    private func ensureStatusItemVisible() {
        if statusItem == nil || statusItem?.button == nil || statusItem?.menu == nil {
            if let existingStatusItem = statusItem {
                NSStatusBar.system.removeStatusItem(existingStatusItem)
            }
            statusItem = nil
            configureStatusItem()
            return
        }

        statusItem?.isVisible = true

        if let button = statusItem?.button {
            button.isHidden = false
            if button.image == nil,
               let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("menubar-apple-music.png"),
               let icon = NSImage(contentsOf: resourceURL)
            {
                icon.isTemplate = true
                icon.size = NSSize(width: 15, height: 15)
                button.image = icon
                button.imageScaling = .scaleProportionallyDown
                button.imagePosition = .imageOnly
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
            }
        }
    }

    private func startStatusItemMonitor() {
        statusItemMonitorTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureStatusItemVisible()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        statusItemMonitorTimer = timer
    }

    private func applyLaunchAtLoginPreference(enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            return
        }

        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            print("[overlay] launch-at-login-error", error.localizedDescription)
            fflush(stdout)
        }
    }

    func windowDidMove(_ notification: Notification) {
        persistWindowPosition()
    }

    private func persistWindowPosition() {
        guard let window else {
            return
        }

        guard let screen = bestScreen(for: window.frame) ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let relativeCenterX = visibleFrame.width > 0
            ? (window.frame.midX - visibleFrame.minX) / visibleFrame.width
            : 0.5
        let relativeMinY = visibleFrame.height > 0
            ? (window.frame.minY - visibleFrame.minY) / visibleFrame.height
            : 0

        settings.saveWindowPosition(
            screenIdentifier: screenIdentifier(for: screen),
            relativeCenterX: min(max(relativeCenterX, 0), 1),
            relativeMinY: min(max(relativeMinY, 0), 1)
        )
    }

    private func bindMenuState() {
        model.$currentTrackTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncTrackInfo()
                self?.syncFavoriteMenuState()
            }
            .store(in: &cancellables)

        model.$currentTrackArtist
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncTrackInfo()
                self?.syncFavoriteMenuState()
            }
            .store(in: &cancellables)

        model.$currentTrackFavorited
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFavoriteMenuState()
            }
            .store(in: &cancellables)

        model.$topLine
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resizeWindowToFitContent(animated: true)
            }
            .store(in: &cancellables)

        model.$bottomLine
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resizeWindowToFitContent(animated: true)
            }
            .store(in: &cancellables)

        settings.$sizePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyOverlaySize(animated: true)
            }
            .store(in: &cancellables)

        settings.$useGradient
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncColorMenuState()
            }
            .store(in: &cancellables)

        settings.$appearanceMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAppearanceMenuState()
                self?.applyWindowAppearance()
            }
            .store(in: &cancellables)

        settings.$launchAtLoginEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.applyLaunchAtLoginPreference(enabled: isEnabled)
                self?.syncLaunchAtLoginMenuState()
            }
            .store(in: &cancellables)

        settings.$isTranslationEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.model.setTranslationEnabled(isEnabled)
                self?.syncTranslationMenuState()
                self?.resizeWindowToFitContent(animated: true)
            }
            .store(in: &cancellables)

        settings.$chineseDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncChineseDisplayMenuState()
                self?.resizeWindowToFitContent(animated: true)
            }
            .store(in: &cancellables)

        settings.$lyricBarDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncLyricBarDisplayMenuState()
            }
            .store(in: &cancellables)

        settings.$lyricAnimationMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncLyricAnimationMenuState()
            }
            .store(in: &cancellables)

        settings.$lyricFontName
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFontMenuState()
                self?.resizeWindowToFitContent(animated: true)
            }
            .store(in: &cancellables)

        settings.$isPositionLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPositionLockState()
            }
            .store(in: &cancellables)
    }

    private func syncTrackInfo() {
        currentTrackMenuItem?.title = model.currentTrackTitle
        currentArtistMenuItem?.title = model.currentTrackArtist.isEmpty ? "Apple Music Desktop Lyrics" : model.currentTrackArtist
        currentArtistMenuItem?.isHidden = model.currentTrackArtist.isEmpty

        if let button = statusItem?.button {
            if model.currentTrackArtist.isEmpty {
                button.toolTip = model.currentTrackTitle
            } else {
                button.toolTip = "\(model.currentTrackTitle) - \(model.currentTrackArtist)"
            }
        }
    }

    private func syncFavoriteMenuState() {
        let hasTrack = !model.currentTrackArtist.isEmpty || model.currentTrackTitle != "未在播放"
        favoriteMenuItem?.isEnabled = hasTrack
        favoriteMenuItem?.title = model.currentTrackFavorited ? "取消我喜欢" : "添加到我喜欢"
        favoriteMenuItem?.state = model.currentTrackFavorited ? .on : .off
    }

    private func abbreviatedStatusTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "未在播放" else {
            return "词"
        }

        let maxCount = 6
        if trimmed.count <= maxCount {
            return trimmed
        }

        return String(trimmed.prefix(maxCount)) + "…"
    }

    private func syncSizeMenuState() {
        for (preset, item) in sizeMenuItems {
            item.state = preset == settings.sizePreset ? .on : .off
        }
    }

    private func syncAppearanceMenuState() {
        for (mode, item) in appearanceMenuItems {
            item.state = mode == settings.appearanceMode ? .on : .off
        }
    }

    private func syncLaunchAtLoginMenuState() {
        if #available(macOS 13.0, *) {
            launchAtLoginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginMenuItem?.state = settings.launchAtLoginEnabled ? .on : .off
        }
    }

    private func syncTranslationMenuState() {
        translationToggleMenuItem?.state = settings.isTranslationEnabled ? .on : .off
    }

    private func syncChineseDisplayMenuState() {
        for (mode, item) in chineseDisplayMenuItems {
            item.state = mode == settings.chineseDisplayMode ? .on : .off
        }
    }

    private func syncLyricBarDisplayMenuState() {
        for (mode, item) in lyricBarDisplayMenuItems {
            item.state = mode == settings.lyricBarDisplayMode ? .on : .off
        }
    }

    private func syncLyricAnimationMenuState() {
        for (mode, item) in lyricAnimationMenuItems {
            item.state = mode == settings.lyricAnimationMode ? .on : .off
        }
    }

    private func syncPositionLockState() {
        positionLockMenuItem?.state = settings.isPositionLocked ? .on : .off
        window?.isMovableByWindowBackground = !settings.isPositionLocked
    }

    private func syncFontMenuState() {
        if
            let fontName = settings.lyricFontName,
            !fontName.isEmpty,
            let font = NSFont(name: fontName, size: settings.metrics.topFontSize)
        {
            currentFontMenuItem?.title = "当前字体：\(font.displayName ?? fontName)"
            resetFontMenuItem?.isEnabled = true
        } else {
            currentFontMenuItem?.title = "当前字体：系统默认"
            resetFontMenuItem?.isEnabled = false
        }
    }

    private func syncColorMenuState() {
        gradientToggleMenuItem?.state = settings.useGradient ? .on : .off
    }

    private func applyWindowAppearance() {
        window?.appearance = settings.appearanceMode.nsAppearance
    }

    private func applyOverlaySize(animated: Bool) {
        syncSizeMenuState()
        resizeWindowToFitContent(animated: animated)
    }

    private func resizeWindowToFitContent(animated: Bool = true, immediate: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let window = self.window
            else {
                return
            }

            let metrics = self.settings.metrics
            let targetContentWidth = self.desiredContentWidth()
            let currentContentWidth = self.appliedContentWidth ?? targetContentWidth

            let applyFrameChange: (CGFloat, Bool) -> Void = { width, shouldAnimate in
                self.appliedContentWidth = width
                let newFrame = self.frame(for: metrics, contentWidth: width, preserving: window)
                window.setFrame(newFrame, display: true, animate: shouldAnimate)
            }

            if immediate || !animated || self.appliedContentWidth == nil {
                applyFrameChange(targetContentWidth, animated)
                return
            }

            let delta = targetContentWidth - currentContentWidth
            if delta > metrics.windowWidthStep * 0.6 {
                applyFrameChange(targetContentWidth, true)
            }
        }
    }

    @objc
    private func togglePositionLock() {
        settings.isPositionLocked.toggle()
    }

    @objc
    private func toggleLaunchAtLogin() {
        settings.launchAtLoginEnabled.toggle()
    }

    @objc
    private func toggleTranslationEnabled() {
        settings.isTranslationEnabled.toggle()
    }

    @objc
    private func openTranslationSettings() {
        if translationSettingsPanel == nil {
            translationSettingsModel.reloadFromStore()
        }

        if translationSettingsPanel == nil {
            let rootView = TranslationSettingsPanelView(
                model: translationSettingsModel,
                onClose: { [weak self] in
                    self?.translationSettingsPanel?.orderOut(nil)
                }
            )
            let hostingView = NSHostingView(rootView: rootView)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "翻译设置"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.contentView = hostingView
            panel.contentMinSize = NSSize(width: 420, height: 220)
            translationSettingsPanel = panel
        } else if translationSettingsPanel?.isVisible == false {
            translationSettingsModel.reloadFromStore()
        }

        translationSettingsPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func selectOverlaySize(_ sender: NSMenuItem) {
        guard let preset = OverlaySizePreset(rawValue: sender.tag) else {
            return
        }

        settings.sizePreset = preset
    }

    @objc
    private func selectAppearanceMode(_ sender: NSMenuItem) {
        guard let mode = OverlayAppearanceMode(rawValue: sender.tag) else {
            return
        }

        settings.appearanceMode = mode
    }

    @objc
    private func selectChineseDisplayMode(_ sender: NSMenuItem) {
        guard let mode = ChineseDisplayMode(rawValue: sender.tag) else {
            return
        }

        settings.chineseDisplayMode = mode
    }

    @objc
    private func selectLyricBarDisplayMode(_ sender: NSMenuItem) {
        guard let mode = LyricBarDisplayMode(rawValue: sender.tag) else {
            return
        }

        settings.lyricBarDisplayMode = mode
    }

    @objc
    private func selectLyricAnimationMode(_ sender: NSMenuItem) {
        guard let mode = LyricAnimationMode(rawValue: sender.tag) else {
            return
        }

        settings.lyricAnimationMode = mode
    }

    @objc
    private func toggleGradientColor() {
        settings.useGradient.toggle()
    }

    @objc
    private func toggleFavoriteCurrentTrack() {
        model.toggleCurrentTrackFavorited()
    }

    @objc
    private func openFontPanel() {
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(changeLyricFont(_:))

        let panel = NSFontPanel.shared
        panel.setPanelFont(currentNSFont(size: settings.metrics.topFontSize), isMultiple: false)
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func changeLyricFont(_ sender: NSFontManager) {
        let selectedFont = sender.convert(currentNSFont(size: settings.metrics.topFontSize))
        settings.lyricFontName = selectedFont.fontName
    }

    @objc
    private func resetLyricFont() {
        settings.resetFont()
    }

    @objc
    private func openBaseColorPanel() {
        presentColorPanel(for: .base)
    }

    @objc
    private func openGradientColorPanel() {
        presentColorPanel(for: .gradient)
    }

    @objc
    private func resetLyricColors() {
        settings.resetColors()
        syncColorMenuState()
    }

    private func presentColorPanel(for target: ColorPanelTarget) {
        colorPanelTarget = target

        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        panel.showsAlpha = true
        panel.color = switch target {
        case .base:
            settings.lyricBaseColor.nsColor
        case .gradient:
            settings.lyricGradientColor.nsColor
        }
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func colorPanelDidChange(_ sender: NSColorPanel) {
        let color = StoredColor(sender.color)
        switch colorPanelTarget {
        case .base:
            settings.lyricBaseColor = color
        case .gradient:
            settings.lyricGradientColor = color
            if !settings.useGradient {
                settings.useGradient = true
            }
        }
    }

    private func currentNSFont(size: CGFloat) -> NSFont {
        guard
            let fontName = settings.lyricFontName,
            !fontName.isEmpty,
            let font = NSFont(name: fontName, size: size)
        else {
            return NSFont.systemFont(ofSize: size, weight: .bold)
        }

        return font
    }

    @objc
    private func handleRelaunchRequest() {
        bringOverlayToFront()
    }

    private func bringOverlayToFront() {
        ensureStatusItemVisible()
        resizeWindowToFitContent(animated: false, immediate: true)
        syncTrackInfo()
        syncFavoriteMenuState()
        applyWindowAppearance()

        guard let window else {
            return
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quitOverlay() {
        NSApp.terminate(nil)
    }
}

@MainActor
@main
struct AppleLyricsOverlayMain {
    private static let instanceLock = AppInstanceLock.acquire()
    private static let appDelegate = AppDelegate()

    static func main() {
        guard instanceLock != nil else {
            AppInstanceLock.signalExistingInstance()
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = appDelegate
        application.run()
    }
}
