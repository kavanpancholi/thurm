import Foundation

/// A file reference from the clicked terminal cell.
enum TerminalFileReference: Equatable {
    case path(String)
    case fileURL(URL)

    private static let tokens = try! NSRegularExpression(
        pattern: #""[^"\r\n]+"|'[^'\r\n]+'|`[^`\r\n]+`|(?:\\[^\r\n]|[^\s<>"'`])+"#)
    private static let locationSuffix = try! NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)

    private static func withoutLocationSuffix(_ path: String) -> String {
        locationSuffix.stringByReplacingMatches(in: path,
            range: NSRange(location: 0, length: (path as NSString).length), withTemplate: "")
    }

    /// The column map uses UTF-16 offsets, as does the terminal row text.
    static func at(text: String, columns: [Int], column: Int, link: URL?) -> Self? {
        if let link { return link.isFileURL ? .fileURL(link) : nil }
        let ns = text as NSString
        for match in tokens.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            guard range.location + range.length <= columns.count,
                  column >= columns[range.location],
                  column <= columns[range.location + range.length - 1] else { continue }
            var token = ns.substring(with: range)
            let quoted = token.first == "\"" || token.first == "'" || token.first == "`"
            if quoted {
                token = String(token.dropFirst().dropLast())
            } else {
                while let first = token.first, ["(", "[", "{"].contains(first) { token.removeFirst() }
                while let last = token.last {
                    if ".,;:!?".contains(last) { token.removeLast(); continue }
                    let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
                    if let opening = pairs[last],
                       token.filter({ $0 == last }).count > token.filter({ $0 == opening }).count {
                        token.removeLast()
                        continue
                    }
                    break
                }
                // Remove shell escapes without evaluating shell input.
                var decoded = ""
                var escaped = false
                for character in token {
                    if escaped { decoded.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else { decoded.append(character) }
                }
                if escaped { decoded.append("\\") }
                token = decoded
            }
            if token.lowercased().hasPrefix("file:"), let url = URL(string: token) {
                return .fileURL(url)
            }
            guard !token.isEmpty,
                  token.contains("/") || token.hasPrefix(".") || !(token as NSString).pathExtension.isEmpty else {
                return nil
            }
            return .path(token)
        }
        return nil
    }

    /// Resolve against the clicked pane, never the app's working directory.
    func resolve(cwd: String?, isRemote: Bool,
                 home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                 localHostName: String = ProcessInfo.processInfo.hostName) throws -> URL {
        guard !isRemote else { throw FilePreviewError.remote }
        let path: String
        switch self {
        case .fileURL(let url):
            guard url.isFileURL,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.query == nil, parts.fragment == nil else { throw FilePreviewError.invalid }
            let host = (parts.host ?? "").lowercased()
            guard host.isEmpty || host == "localhost" || host == localHostName.lowercased() else {
                throw FilePreviewError.remote
            }
            path = parts.path
            guard path.hasPrefix("/") else { throw FilePreviewError.invalid }
        case .path(let value):
            guard !value.contains("://") else { throw FilePreviewError.remote }
            // A colon before the first slash identifies an SCP host, unless it is a
            // diagnostic suffix. Use ./ or an absolute path for a local colon filename.
            let base = Self.withoutLocationSuffix(value)
            if let colon = base.firstIndex(of: ":"), !base[..<colon].contains("/") {
                throw FilePreviewError.remote
            }
            if value.hasPrefix("~/") {
                path = home + "/" + value.dropFirst(2)
            } else if value.hasPrefix("~") {
                throw FilePreviewError.invalid
            } else if value.hasPrefix("/") {
                path = value
            } else {
                guard let cwd, cwd.hasPrefix("/"), !cwd.hasPrefix("//"), !cwd.contains("\0") else {
                    throw FilePreviewError.noDirectory
                }
                path = cwd + "/" + value
            }
        }
        guard !path.contains("\0"), !path.hasPrefix("//") else { throw FilePreviewError.invalid }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Keep a literal filename if it exists. Otherwise remove a diagnostic line suffix.
    func localFile(cwd: String?, isRemote: Bool) throws -> URL {
        var url = try resolve(cwd: cwd, isRemote: isRemote)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Resolve and validate the host before changing the decoded local path.
            let path = url.path
            let stripped = Self.withoutLocationSuffix(path)
            if stripped != path {
                url = URL(fileURLWithPath: stripped).standardizedFileURL
            }
        }
        guard fm.fileExists(atPath: url.path) else { throw FilePreviewError.missing }
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FilePreviewError.unsupported }
        guard fm.isReadableFile(atPath: url.path) else { throw FilePreviewError.unreadable }
        return url
    }
}

enum FilePreviewError: Error, LocalizedError {
    case remote, invalid, noDirectory, missing, unsupported, unreadable

    var errorDescription: String? {
        switch self {
        case .remote: return "Quick Look is available only for files on this Mac. Copy the file to this Mac first."
        case .invalid: return "Quick Look cannot use this file path."
        case .noDirectory: return "The terminal directory is unknown. Use an absolute file path."
        case .missing: return "The file was not found. Relative paths use the pane's current directory."
        case .unsupported: return "Quick Look requires a regular file. Folders and special files are not supported."
        case .unreadable: return "The file cannot be read. Check its access permissions."
        }
    }
}
