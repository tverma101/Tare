import Foundation

public final class MKVDiscoveryService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(in rootDirectories: [URL], limit: Int = 1_000) async -> [URL] {
        await Task.detached(priority: .utility) { [fileManager] in
            discoverSynchronously(
                in: rootDirectories,
                limit: limit,
                fileManager: fileManager
            )
        }.value
    }
}

private func discoverSynchronously(
    in rootDirectories: [URL],
    limit: Int,
    fileManager: FileManager
) -> [URL] {
    let roots = uniqueURLs(rootDirectories.map(\.standardizedFileURL))
    let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isPackageKey
    ]
    var discovered: [URL] = []
    var seen = Set<String>()

    for root in roots {
        if root.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame,
           fileManager.fileExists(atPath: root.path) {
            appendIfNeeded(root, to: &discovered, seen: &seen, limit: limit)
            continue
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            continue
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            continue
        }

        for case let url as URL in enumerator {
            if discovered.count >= limit {
                break
            }

            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            if values?.isDirectory == true {
                if shouldSkipDirectory(url) || values?.isPackage == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile != false else {
                continue
            }

            guard url.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame else {
                continue
            }

            appendIfNeeded(url.standardizedFileURL, to: &discovered, seen: &seen, limit: limit)
        }
    }

    return discovered.sorted {
        $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
}

private func shouldSkipDirectory(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    let skippedNames: Set<String> = [
        ".build",
        ".git",
        "node_modules",
        "Original Video Backups"
    ]
    return skippedNames.contains(name)
}

private func appendIfNeeded(
    _ url: URL,
    to discovered: inout [URL],
    seen: inout Set<String>,
    limit: Int
) {
    guard discovered.count < limit else {
        return
    }

    let key = url.standardizedFileURL.path
    guard seen.insert(key).inserted else {
        return
    }

    discovered.append(url.standardizedFileURL)
}

private func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { url in
        seen.insert(url.path).inserted
    }
}
