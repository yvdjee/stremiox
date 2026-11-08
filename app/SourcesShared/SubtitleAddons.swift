import Foundation

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on).
struct AddonSubtitle: Identifiable, Equatable {
    let id: String
    let url: String
    let lang: String
    let addonName: String
}

/// A subtitles-capable add-on to query: its base URL (transportUrl minus /manifest.json) and name.
struct SubtitleSource: Hashable {
    let baseUrl: String
    let name: String
}

/// Fetches external subtitles from every installed add-on that declares the `subtitles`
/// resource, the way the official clients do. The player lists these next to the file's
/// embedded tracks; picking one hands the URL to mpv (`sub-add`).
enum SubtitleAddonService {
    private struct SubtitlesResponse: Decodable {
        let subtitles: [Sub]
        enum CodingKeys: String, CodingKey { case subtitles }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Decode entry by entry so one odd item never drops the add-on's whole list.
            var list = (try? c.nestedUnkeyedContainer(forKey: .subtitles))
            var out: [Sub] = []
            while var l = list, !l.isAtEnd {
                if let s = try? l.decode(Sub.self) { out.append(s) }
                else if (try? l.decode(Skip.self)) == nil { break }   // non-object entry: stop, keep what we have
                list = l
            }
            subtitles = out
        }
    }
    private struct Skip: Decodable {}
    private struct Sub: Decodable {
        let id: String?
        let url: String
        let lang: String?
        enum CodingKeys: String, CodingKey { case id, url, lang }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            lang = try? c.decode(String.self, forKey: .lang)
            // Add-ons send the id as a string or a number.
            if let s = try? c.decode(String.self, forKey: .id) { id = s }
            else if let n = try? c.decode(Int64.self, forKey: .id) { id = String(n) }
            else { id = nil }
        }
    }

    /// Subtitle add-ons from the engine's installed list (the source of truth the rest of the app
    /// uses), merged with the legacy account list, deduplicated by base URL, engine order first.
    static func sources(core: [CoreDescriptor], account: [AddonDescriptor]) -> [SubtitleSource] {
        let fromCore = core.filter(\.providesSubtitles).map {
            SubtitleSource(baseUrl: baseUrl($0.transportUrl), name: $0.manifest.name)
        }
        let fromAccount = account.filter { d in d.manifest.resources.contains { $0.name == "subtitles" } }
            .map { SubtitleSource(baseUrl: $0.baseUrl, name: $0.manifest.name) }
        var seen = Set<String>()
        return (fromCore + fromAccount).filter { seen.insert($0.baseUrl).inserted }
    }

    private static func baseUrl(_ transportUrl: String) -> String {
        var s = transportUrl
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        return s
    }

    /// Legacy entry point: account add-ons only.
    static func fetch(addons: [AddonDescriptor], type: String, videoId: String) async -> [AddonSubtitle] {
        await fetch(sources: sources(core: [], account: addons), type: type, videoId: videoId)
    }

    /// All subtitles for `type/videoId` across the given subtitle add-ons, in add-on
    /// order, deduplicated by URL. videoId is a movie id or `id:season:episode`.
    static func fetch(sources: [SubtitleSource], type: String, videoId: String) async -> [AddonSubtitle] {
        DiagnosticsLog.log("subs", "fetch \(type)/\(videoId) from \(sources.count) add-on(s): \(sources.map(\.name).joined(separator: ", "))")
        guard !sources.isEmpty else { return [] }
        let safeId = videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoId

        let collected: [[AddonSubtitle]] = await withTaskGroup(of: (Int, [AddonSubtitle]).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    guard let url = URL(string: "\(source.baseUrl)/subtitles/\(type)/\(safeId).json") else {
                        DiagnosticsLog.log("subs", "\(source.name): bad URL")
                        return (i, [])
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    do {
                        let (data, resp) = try await URLSession.shared.data(for: req)
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(status) else {
                            DiagnosticsLog.log("subs", "\(source.name): HTTP \(status)")
                            return (i, [])
                        }
                        let decoded = try JSONDecoder().decode(SubtitlesResponse.self, from: data)
                        let subs = decoded.subtitles.map {
                            AddonSubtitle(id: $0.id ?? $0.url, url: $0.url,
                                          lang: $0.lang ?? "und", addonName: source.name)
                        }
                        DiagnosticsLog.log("subs", "\(source.name): \(subs.count) subtitle(s)")
                        return (i, subs)
                    } catch {
                        DiagnosticsLog.log("subs", "\(source.name): \(error.localizedDescription)")
                        return (i, [])
                    }
                }
            }
            var buckets = [[AddonSubtitle]](repeating: [], count: sources.count)
            for await (i, chunk) in group { buckets[i] = chunk }
            return buckets
        }

        var seen = Set<String>()
        return collected.flatMap { $0 }.filter { seen.insert($0.url).inserted }
    }
}
