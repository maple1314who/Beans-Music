import Foundation

// MARK: - WebDAV 备份服务

/// WebDAV 配置：服务器地址 + Basic Auth 凭据 + 远端文件名。
/// 自用场景跟随项目惯例（登录态 token 同样存于 UserDefaults）持久化，密码为明文存储。
struct WebDAVConfig: Codable, Equatable {
    var baseURL: String = ""       // 例如 https://dav.example.com/beans，结尾可带或不带 /
    var username: String = ""
    var password: String = ""
    var filename: String = "beans-backup.json"
}

/// WebDAV 目录项（目录浏览用）
struct WebDAVItem: Identifiable {
    let id = UUID()
    let name: String      // 显示名（目录名）
    let fullPath: String  // 完整地址（scheme://host + path），可直接作为新的 baseURL
    let isDirectory: Bool
}

/// WebDAV 客户端 + 配置存储：上传 / 下载 / 目录浏览 / 远端版本。
final class WebDAVBackupStore: ObservableObject {
    static let shared = WebDAVBackupStore()
    private static let configKey = "beans.webdav.config.v1"
    private static let lastSyncKey = "beans.webdav.lastSyncDate"

    @Published private(set) var config: WebDAVConfig

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(WebDAVConfig.self, from: data) {
            config = decoded
        } else {
            config = WebDAVConfig()
        }
    }

    func save(_ newConfig: WebDAVConfig) {
        config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    /// 上次成功同步时间（双向同步的锚点）
    var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.lastSyncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
            }
        }
    }

    // MARK: - 上传 / 下载

    /// 上传备份数据到 WebDAV（PUT）。
    func upload(_ data: Data) async throws {
        _ = try await request(method: "PUT", body: data, contentType: "application/json")
    }

    /// 从 WebDAV 下载备份数据（GET）。
    func download() async throws -> Data {
        try await request(method: "GET", body: nil, contentType: nil)
    }

    /// 拉取远端备份；文件不存在（404）时返回 nil，其余错误抛出。
    func fetchRemoteBackup() async throws -> Data? {
        do {
            return try await request(method: "GET", body: nil, contentType: nil)
        } catch let WebDAVError.httpStatus(code) where code == 404 {
            return nil
        }
    }

    /// 解析备份数据中的远端版本时间（beans.backup.meta.created）。
    func remoteBackupDate(_ data: Data) -> Date? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["beans.backup.meta"] as? [String: Any],
              let created = meta["created"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: created)
    }

    // MARK: - 目录浏览

    /// PROPFIND 列出指定路径下的子目录（Depth 1）。默认使用当前配置的 baseURL。
    func listDirectories(at path: String? = nil) async throws -> [WebDAVItem] {
        let base = (path ?? config.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw WebDAVError.noServer }
        guard var components = URLComponents(string: base) else { throw WebDAVError.invalidURL }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 30
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("BeansMusic-WebDAV/1.0", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // 用当前请求的 scheme/host 拼出可点选的完整地址；currentPath 用于过滤“当前目录自己”
        let scheme = url.scheme ?? "https"
        let host = url.host ?? ""
        let currentPath = components.path
        return WebDAVParser.parseDirectories(xml: data, scheme: scheme, host: host, currentPath: currentPath)
    }

    /// 新建目录（MKCOL）。
    func createDirectory(named name: String, at path: String? = nil) async throws {
        let base = (path ?? config.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw WebDAVError.noServer }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebDAVError.invalidURL }
        guard var components = URLComponents(string: base) else { throw WebDAVError.invalidURL }
        var p = components.path
        if !p.hasSuffix("/") { p += "/" }
        p += trimmed + "/"
        components.path = p
        guard let url = components.url else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        request.timeoutInterval = 30
        request.setValue("BeansMusic-WebDAV/1.0", forHTTPHeaderField: "User-Agent")
        applyAuth(to: &request)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 405 { throw WebDAVError.directoryExists }
            throw WebDAVError.httpStatus(code)
        }
    }

    // MARK: - 内部

    private func request(method: String, body: Data?, contentType: String?) async throws -> Data {
        let url = try resolvedURL()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("BeansMusic-WebDAV/1.0", forHTTPHeaderField: "User-Agent")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }
        applyAuth(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.badResponse }
        // PUT 成功常见 200/201/204；GET 成功 200
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
        return data
    }

    private func resolvedURL() throws -> URL {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw WebDAVError.noServer }
        // 用 URLComponents 处理含中文等非 ASCII 的路径（自动 percent-encode）
        guard var components = URLComponents(string: base) else { throw WebDAVError.invalidURL }
        var path = components.path
        if !path.hasSuffix("/") { path += "/" }
        path += config.filename
        components.path = path
        guard let url = components.url else { throw WebDAVError.invalidURL }
        return url
    }

    private func applyAuth(to request: inout URLRequest) {
        let credential = "\(config.username):\(config.password)"
        if let authData = credential.data(using: .utf8) {
            request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }
}

enum WebDAVError: LocalizedError {
    case noServer
    case invalidURL
    case badResponse
    case directoryExists
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noServer: return "请先填写 WebDAV 服务器地址"
        case .invalidURL: return "服务器地址无效"
        case .badResponse: return "服务器响应异常"
        case .directoryExists: return "该目录已存在"
        case .httpStatus(let code):
            if code == 404 {
                return "找不到该路径（HTTP 404）。坚果云 WebDAV 根目录不可写，请把地址填到可写子目录，如 https://dav.jianguoyun.com/dav/我的坚果云/"
            }
            if code == 401 || code == 403 {
                return "认证失败或无权限（HTTP \(code)），请检查用户名与应用密码"
            }
            return "服务器返回错误（HTTP \(code)）"
        }
    }
}

// MARK: - WebDAV PROPFIND XML 解析

private final class WebDAVParser: NSObject, XMLParserDelegate {
    private var items: [WebDAVItem] = []
    private var currentHref: String?
    private var currentIsCollection = false
    private var inHref = false
    private var inResponse = false
    private let scheme: String
    private let host: String

    private let currentPath: String

    private init(scheme: String, host: String, currentPath: String) {
        self.scheme = scheme
        self.host = host
        self.currentPath = currentPath
    }

    static func parseDirectories(xml: Data, scheme: String, host: String, currentPath: String) -> [WebDAVItem] {
        let delegate = WebDAVParser(scheme: scheme, host: host, currentPath: currentPath)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "response":
            inResponse = true
            currentHref = nil
            currentIsCollection = false
        case "href":
            inHref = true
        case "collection":
            currentIsCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inHref, inResponse else { return }
        currentHref = (currentHref ?? "") + string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "href":
            inHref = false
        case "response":
            inResponse = false
            guard currentIsCollection, let href = currentHref else { break }
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            // 过滤掉“当前目录自己”（PROPFIND 会把请求的目录本身也作为第一个 response 返回）
            let normHref = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            let normCurrent = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
            if normHref == normCurrent { break }
            let name = Self.displayName(from: trimmed)
            guard !name.isEmpty else { break }
            let fullPath = "\(scheme)://\(host)\(trimmed)"
            items.append(WebDAVItem(name: name, fullPath: fullPath, isDirectory: true))
        default:
            break
        }
    }

    /// 从 href（如 /dav/我的坚果云/）提取最后一段作为显示名
    private static func displayName(from href: String) -> String {
        let parts = href.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return "" }
        return last.removingPercentEncoding ?? String(last)
    }
}
