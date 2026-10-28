import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Hosts `PlayerScreen` for one launch and, for a series episode, carries playback on to the next
/// episode: it works out which episode follows, preloads that episode's best source once playback
/// passes the halfway mark, and when the player asks for the next episode (the Up Next card, the
/// top-bar Next button, or the episode ending) swaps in a fresh `PlayerScreen` for it without leaving
/// the cover. The iOS/Mac twin of the tvOS player's `playNext` / `preloadNextIfNeeded`. Movies and
/// paste-a-link plays pass straight through (no next episode, progress saved only with a meta).
struct iOSEpisodePlayer: View {
    let onClose: () -> Void

    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount

    @State private var launch: iOSPlayerLaunch
    @State private var episodes: [CoreVideo] = []          // the series' videos, for working out the next one
    @State private var binge: String?                      // bingeGroup of the playing stream, carried episode to episode
    @State private var preloaded: Preloaded?
    @State private var preloadingID: String?
    @State private var warmedID: String?
    @State private var advancing: CoreVideo?               // next episode being resolved → overlay over the player
    @State private var advanceFailed = false
    @State private var onScreen = false
    @State private var torrentPrime: Task<Void, Never>?

    /// The next episode's best stream, fetched in the background before it is needed.
    private struct Preloaded { let episodeID: String; let stream: CoreStream }

    init(launch: iOSPlayerLaunch, onClose: @escaping () -> Void) {
        _launch = State(initialValue: launch)
        _binge = State(initialValue: launch.bingeGroup)
        self.onClose = onClose
    }

    var body: some View {
        let meta = launch.meta
        let next = nextEpisode
        ZStack {
            PlayerScreen(
                url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                hasNext: next != nil,
                nextLabel: next.map(label(for:)),
                nextThumbnail: next?.thumbnail.flatMap(URL.init(string:)),
                recordMeta: meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                onProgress: { pos, dur in save(meta, pos, dur); prepareNext(position: pos, duration: dur) },
                onSeek: { pos, dur in save(meta, pos, dur) },
                onNext: playNext,
                onClose: onClose
            )
            // A new launch is a new PlayerScreen (fresh mpv, resume, tracks, skip spans), not a
            // reuse of the old one's per-episode state.
            .id(launch.id)

            if let advancing { advanceOverlay(advancing) }
        }
        .onAppear { onScreen = true; loadEpisodes() }
        .onDisappear { onScreen = false; torrentPrime?.cancel() }
    }

    // MARK: - Which episode is next

    private var nextEpisode: CoreVideo? {
        guard let m = launch.meta, m.type == "series" else { return nil }
        return Self.episode(after: m.videoId, in: episodes)
    }

    /// The episode after `id` in season/episode order. Specials (season 0) only lead on to other
    /// specials, and an episode that hasn't aired yet isn't offered.
    static func episode(after id: String, in videos: [CoreVideo]) -> CoreVideo? {
        guard let current = videos.first(where: { $0.id == id }) else { return nil }
        let inSpecials = current.season == 0
        let ordered = videos
            .filter { ($0.season == 0) == inSpecials }
            .sorted { ($0.season ?? 1, $0.episodeNumber) < ($1.season ?? 1, $1.episodeNumber) }
        guard let i = ordered.firstIndex(where: { $0.id == id }), i + 1 < ordered.count else { return nil }
        let next = ordered[i + 1]
        if let aired = next.releasedDate, aired > Date() { return nil }
        return next
    }

    private func label(for v: CoreVideo) -> String {
        "S\(v.season ?? 1) · E\(v.episodeNumber) · \(v.episodeTitle)"
    }

    /// Use the series' episode list when the engine already holds it (launched from the episode
    /// page). A Continue-Watching resume launches with no meta loaded, so fetch it behind playback,
    /// with this episode's streams so the in-player Sources panel lists them (as tvOS does).
    private func loadEpisodes() {
        guard let m = launch.meta, m.type == "series", episodes.isEmpty else { return }
        if let vids = loadedVideos(for: m.libraryId) { episodes = vids; return }
        core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: m.videoId)
        Task { @MainActor in
            for _ in 0..<40 {
                if let vids = loadedVideos(for: m.libraryId) { episodes = vids; return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func loadedVideos(for libraryId: String) -> [CoreVideo]? {
        guard let meta = core.metaDetails?.meta, meta.id == libraryId,
              let vids = meta.videos, !vids.isEmpty else { return nil }
        return vids
    }

    // MARK: - Progress + preload

    private func save(_ meta: PlaybackMeta?, _ pos: Double, _ dur: Double) {
        guard let meta else { return }
        Task { [weak account] in await account?.saveProgress(for: meta, positionSeconds: pos, durationSeconds: dur) }
    }

    /// Halfway through → resolve the next episode's best source; near the end → wake it up.
    private func prepareNext(position pos: Double, duration dur: Double) {
        guard dur > 0, let next = nextEpisode else { return }
        if pos / dur >= 0.5 { preload(next) }
        if dur - pos <= 100 { warmPreloaded() }
    }

    private func preload(_ v: CoreVideo) {
        guard preloaded?.episodeID != v.id, preloadingID != v.id else { return }
        preloadingID = v.id
        let sources = account.streamSources
        let hint = launch.qualityText, binge = binge
        Task { @MainActor in
            let groups = playable(await NextEpisodeStreams.fetch(episodeId: v.id, from: sources))
            if let best = StreamRanking.best(groups, continuity: hint, binge: binge) {
                preloaded = Preloaded(episodeID: v.id, stream: best)
            }
            if preloadingID == v.id { preloadingID = nil }
        }
    }

    /// One ranged read of the preloaded source (and the torrent's peer search) shortly before the
    /// credits, so the provider has the file hot when the next episode opens.
    private func warmPreloaded() {
        guard let pre = preloaded, warmedID != pre.episodeID, let url = pre.stream.playableURL else { return }
        warmedID = pre.episodeID
        torrentPrime?.cancel()
        torrentPrime = prepareTorrentStream(pre.stream)
        var request = URLRequest(url: url)
        request.setValue("bytes=0-16777215", forHTTPHeaderField: "Range")   // first 16 MB
        request.timeoutInterval = 60
        Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: request) }
    }

    /// Direct-links-only drops torrents, as the source lists do.
    private func playable(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            return streams.isEmpty ? nil : CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    // MARK: - Advancing

    private func playNext() {
        guard advancing == nil, let v = nextEpisode, let m = launch.meta else { return }
        advanceFailed = false
        withAnimation(.easeInOut(duration: 0.2)) { advancing = v }
        Task { @MainActor in
            // Point the engine at the next episode: its streams back the in-player Sources panel and
            // the engine Player that keeps Continue Watching on this series.
            core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
            let stream: CoreStream?
            if let pre = preloaded, pre.episodeID == v.id {
                stream = pre.stream
            } else {
                stream = await resolveFromEngine(v)
            }
            guard advancing?.id == v.id else { return }   // closed while resolving
            guard let stream, let url = stream.playableURL else {
                withAnimation { advanceFailed = true }
                return
            }
            if warmedID != v.id {
                torrentPrime?.cancel()
                torrentPrime = prepareTorrentStream(stream)
            }
            let pm = PlaybackMeta(libraryId: m.libraryId, videoId: v.id, type: "series", name: m.name,
                                  poster: v.thumbnail ?? m.poster, season: v.season, episode: v.episode)
            let resume: Double
            if let engine = core.engineResumeSeconds(for: pm) { resume = engine } else { resume = await account.resumeOffset(for: pm) }
            binge = stream.behaviorHints?.bingeGroup
            preloaded = nil; warmedID = nil
            launch = iOSPlayerLaunch(url: url, title: "\(m.name)  ·  S\(v.season ?? 1)E\(v.episodeNumber)",
                                     headers: stream.requestHeaders, resume: resume, meta: pm,
                                     qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent,
                                     bingeGroup: binge)
            withAnimation(.easeInOut(duration: 0.2)) { advancing = nil }
            keepScreenAwake()
            // Hand the stream to the engine Player once meta_details lists this episode's streams;
            // harmless if it never does.
            for _ in 0..<60 {
                if !core.streamGroups(forStreamId: v.id).isEmpty { core.loadEnginePlayer(for: stream); break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// No preload: wait for the engine's streams for this episode, then take the ranked best once every
    /// add-on answered or a few seconds after the first playable one landed (the tvOS fallback path).
    private func resolveFromEngine(_ v: CoreVideo) async -> CoreStream? {
        var firstPlayableAt: Date?
        for _ in 0..<150 {                                          // ~15s
            guard advancing?.id == v.id else { return nil }
            let groups = playable(core.streamGroups(forStreamId: v.id))
            let progress = core.streamLoadProgress(forStreamId: v.id)
            let hasPlayable = groups.contains { $0.streams.contains { $0.playableURL != nil } }
            if hasPlayable, firstPlayableAt == nil { firstPlayableAt = Date() }
            let settled = progress.total > 0 && progress.loaded == progress.total
            let waitedEnough = firstPlayableAt.map { Date().timeIntervalSince($0) > 4 } ?? false
            if settled || waitedEnough { return StreamRanking.best(groups, continuity: launch.qualityText, binge: binge) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The outgoing PlayerScreen's onDisappear releases the idle timer, and SwiftUI may run it after
    /// the incoming one's onAppear took it, so take it again once the swap has settled.
    private func keepScreenAwake() {
        #if os(iOS)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if onScreen { UIApplication.shared.isIdleTimerDisabled = true }
        }
        #endif
    }

    private func advanceOverlay(_ v: CoreVideo) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 14) {
                if advanceFailed {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(.yellow)
                    Text("No playable source for the next episode")
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("UP NEXT").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Theme.Palette.accent)
                }
                Text(label(for: v)).font(.callout).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).frame(maxWidth: 480)
                HStack(spacing: 16) {
                    if advanceFailed {
                        Button {
                            advancing = nil
                            playNext()
                        } label: { Label("Try again", systemImage: "arrow.clockwise").padding(6) }
                    }
                    Button {
                        advancing = nil
                        onClose()
                    } label: { Label("Close player", systemImage: "xmark").padding(6) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.accent).foregroundStyle(.white)
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .transition(.opacity)
    }
}
