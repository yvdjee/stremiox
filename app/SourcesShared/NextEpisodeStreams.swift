import Foundation

/// A series episode's streams fetched straight from each stream add-on over the Stremio add-on
/// protocol, for the players' next-episode preload. Going around the engine keeps its `meta_details`
/// (which the screen behind the player still shows, and which backs the in-player Sources panel) on
/// the episode that is playing. Shared by the tvOS and iOS/Mac players.
enum NextEpisodeStreams {
    /// Every add-on's streams for episode `id`, in the user's add-on order so ranking ties keep it.
    static func fetch(episodeId id: String, from sources: [StreamSource]) async -> [CoreStreamSourceGroup] {
        var groups: [CoreStreamSourceGroup] = []
        await withTaskGroup(of: CoreStreamSourceGroup?.self) { tasks in
            for source in sources {
                tasks.addTask { await fetch(base: source.base, addon: source.name, id: id) }
            }
            for await group in tasks { if let group { groups.append(group) } }
        }
        // Bases can REPEAT in the add-on list, so this must unique (uniqueKeysWithValues: traps on duplicates).
        let order = Dictionary(sources.enumerated().map { ($1.base, $0) },
                               uniquingKeysWith: { first, _ in first })
        groups.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        return groups
    }

    /// One add-on's streams for an episode.
    private static func fetch(base: String, addon: String, id: String) async -> CoreStreamSourceGroup? {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(base)/stream/series/\(escaped).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        struct Response: Decodable { let streams: [CoreStream]? }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let streams = response.streams, !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: base, addon: addon, streams: streams)
    }
}
