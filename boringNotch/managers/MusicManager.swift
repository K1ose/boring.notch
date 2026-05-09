//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

private enum ChineseMusicPlatform: String {
    case netEase
    case qqMusic

    init?(bundleIdentifier: String?) {
        guard let normalized = bundleIdentifier?.lowercased(), !normalized.isEmpty else { return nil }

        if normalized.contains("netease") || normalized.contains("163music") {
            self = .netEase
            return
        }

        if normalized.contains("qqmusic") || normalized.contains("tencent.qqmusic") {
            self = .qqMusic
            return
        }

        return nil
    }

    var accessTokenEnvironmentKey: String {
        switch self {
        case .netEase:
            return "BORING_NOTCH_NETEASE_TOKEN"
        case .qqMusic:
            return "BORING_NOTCH_QQMUSIC_TOKEN"
        }
    }

    var cookieEnvironmentKey: String {
        switch self {
        case .netEase:
            return "BORING_NOTCH_NETEASE_COOKIE"
        case .qqMusic:
            return "BORING_NOTCH_QQMUSIC_COOKIE"
        }
    }

    var displayName: String {
        switch self {
        case .netEase:
            return "NetEase Cloud Music"
        case .qqMusic:
            return "QQ Music"
        }
    }
}

private struct LyricsFetchResult {
    let plainLyrics: String
    let syncedLyrics: String?
    let chorusMarkers: [Double]
}

struct ActiveLyricLine: Equatable {
    let text: String
    let startTime: Double?
    let nextStartTime: Double?

    var availableDuration: Double? {
        guard let startTime, let nextStartTime, nextStartTime > startTime else { return nil }
        return nextStartTime - startTime
    }
}

private struct ChineseMusicLyricsProvider {
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func fetchLyrics(platform: ChineseMusicPlatform, title: String, artist: String) async -> LyricsFetchResult? {
        switch platform {
        case .netEase:
            return await fetchNetEaseLyrics(title: title, artist: artist)
        case .qqMusic:
            return await fetchQQLyrics(title: title, artist: artist)
        }
    }

    private func fetchNetEaseLyrics(title: String, artist: String) async -> LyricsFetchResult? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encodedQuery = encode(query),
              let searchURL = URL(string: "https://music.163.com/api/search/get/web?csrf_token=&s=\(encodedQuery)&type=1&offset=0&total=true&limit=5") else {
            return nil
        }

        var searchRequest = request(url: searchURL, platform: .netEase)
        searchRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let searchJSON = await jsonObject(for: searchRequest) as? [String: Any],
              let result = searchJSON["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              let song = bestMatch(from: songs, titleKey: "name", artistKey: "artists", title: title, artist: artist),
              let songID = intValue(song["id"]) else {
            return nil
        }

        guard let lyricResponse = await fetchNetEaseLyricResponse(songID: songID) else { return nil }

        let lyricJSON = lyricResponse.json
        let lyric = lyricResponse.lyric
        let translated = ((lyricJSON?["tlyric"] as? [String: Any])?["lyric"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = plainText(from: translated?.isEmpty == false ? translated! : lyric)
        return LyricsFetchResult(
            plainLyrics: plain,
            syncedLyrics: lyric,
            chorusMarkers: lyricJSON.map(extractChorusMarkers(from:)) ?? []
        )
    }

    private func fetchNetEaseLyricResponse(songID: Int) async -> (lyric: String, json: [String: Any]?)? {
        let urlStrings = [
            "https://music.163.com/api/song/lyric?id=\(songID)&lv=-1&kv=-1&tv=-1",
            "https://music.163.com/api/song/media?id=\(songID)",
        ]

        for urlString in urlStrings {
            guard let lyricURL = URL(string: urlString) else { continue }

            var lyricRequest = request(url: lyricURL, platform: .netEase)
            lyricRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

            guard let lyricJSON = await jsonObject(for: lyricRequest) as? [String: Any] else {
                continue
            }

            if let lyric = netEaseLyricText(from: lyricJSON) {
                return (lyric, lyricJSON)
            }
        }

        return nil
    }

    private func netEaseLyricText(from lyricJSON: [String: Any]) -> String? {
        let lyric = firstString(
            (lyricJSON["lrc"] as? [String: Any])?["lyric"],
            lyricJSON["lyric"]
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let lyric, !lyric.isEmpty else { return nil }
        return lyric
    }

    private func fetchQQLyrics(title: String, artist: String) async -> LyricsFetchResult? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encodedQuery = encode(query),
              let searchURL = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(encodedQuery)&format=json&p=1&n=5&cr=1") else {
            return nil
        }

        var searchRequest = request(url: searchURL, platform: .qqMusic)
        searchRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        guard let searchJSON = await jsonObject(for: searchRequest) as? [String: Any],
              let data = searchJSON["data"] as? [String: Any],
              let song = data["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]],
              let match = bestMatch(from: list, titleKey: "songname", artistKey: "singer", title: title, artist: artist),
              let songMID = firstString(match["songmid"], match["mid"]),
              !songMID.isEmpty,
              let encodedMID = encode(songMID),
              let lyricURL = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(encodedMID)&format=json&nobase64=1") else {
            return nil
        }

        var lyricRequest = request(url: lyricURL, platform: .qqMusic)
        lyricRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        guard let lyricJSON = await jsonObject(for: lyricRequest) as? [String: Any],
              let lyric = firstString(lyricJSON["lyric"], lyricJSON["trans"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lyric.isEmpty else {
            return nil
        }

        let decoded = htmlDecoded(lyric)
        let translated = (lyricJSON["trans"] as? String).map(htmlDecoded)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySource = translated?.isEmpty == false ? translated! : decoded
        return LyricsFetchResult(
            plainLyrics: plainText(from: displaySource),
            syncedLyrics: decoded,
            chorusMarkers: extractChorusMarkers(from: lyricJSON)
        )
    }

    private func request(url: URL, platform: ChineseMusicPlatform) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        // Tokens must be provided by the user/app registration flow. We intentionally do not read
        // local desktop client login data or membership sessions from NetEase/QQ Music.
        let environment = ProcessInfo.processInfo.environment
        if let token = environment[platform.accessTokenEnvironmentKey], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = environment[platform.cookieEnvironmentKey], !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        return request
    }

    private func jsonObject(for request: URLRequest) async -> Any? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: normalizedJSONData(data))
        } catch {
            return nil
        }
    }

    private func normalizedJSONData(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return data
        }

        if let firstParen = text.firstIndex(of: "("), text.hasSuffix(")") {
            let start = text.index(after: firstParen)
            let end = text.index(before: text.endIndex)
            text = String(text[start..<end])
        }

        return text.data(using: .utf8) ?? data
    }

    private func bestMatch(
        from songs: [[String: Any]],
        titleKey: String,
        artistKey: String,
        title: String,
        artist: String
    ) -> [String: Any]? {
        let normalizedTitle = comparable(title)
        let normalizedArtist = comparable(artist)

        return songs.first { song in
            guard let candidateTitle = song[titleKey] as? String else { return false }
            let titleMatches = comparable(candidateTitle).contains(normalizedTitle) || normalizedTitle.contains(comparable(candidateTitle))
            let artists = artistNames(from: song[artistKey])
            let artistMatches = normalizedArtist.isEmpty || artists.contains { comparable($0).contains(normalizedArtist) || normalizedArtist.contains(comparable($0)) }
            return titleMatches && artistMatches
        } ?? songs.first
    }

    private func artistNames(from value: Any?) -> [String] {
        if let artists = value as? [[String: Any]] {
            return artists.compactMap { firstString($0["name"], $0["title"]) }
        }

        if let artists = value as? [String] {
            return artists
        }

        if let artist = value as? String {
            return [artist]
        }

        return []
    }

    private func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func firstString(_ values: Any?...) -> String? {
        values.compactMap { value in
            if let string = value as? String, !string.isEmpty {
                return string
            }
            return nil
        }.first
    }

    private func plainText(from lrc: String) -> String {
        let timestampPattern = #"\[(?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d{1,3})?\]|\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]"#
        let metadataPattern = #"\[[a-zA-Z]+:[^\]]*\]"#
        let withoutTimestamps = lrc.replacingOccurrences(of: timestampPattern, with: "", options: .regularExpression)
        let withoutMetadata = withoutTimestamps.replacingOccurrences(of: metadataPattern, with: "", options: .regularExpression)
        return withoutMetadata
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func comparable(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func htmlDecoded(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else {
            return value
        }
        return attributed.string
    }

    private func extractChorusMarkers(from object: Any) -> [Double] {
        var markers: [Double] = []
        collectChorusMarkers(from: object, keyPath: [], into: &markers)
        return Array(Set(markers.map { ($0 * 100).rounded() / 100 }))
            .filter { $0 >= 0 }
            .sorted()
    }

    private func collectChorusMarkers(from object: Any, keyPath: [String], into markers: inout [Double]) {
        let pathMentionsChorus = keyPath.contains { key in
            let normalized = key.lowercased()
            return normalized.contains("chorus")
                || normalized.contains("refrain")
                || normalized.contains("hook")
                || normalized.contains("副歌")
        }

        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                collectChorusMarkers(from: value, keyPath: keyPath + [key], into: &markers)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                collectChorusMarkers(from: value, keyPath: keyPath, into: &markers)
            }
            return
        }

        guard pathMentionsChorus else { return }

        if let value = object as? Double {
            markers.append(normalizedMarkerTime(value))
        } else if let value = object as? Int {
            markers.append(normalizedMarkerTime(Double(value)))
        } else if let value = object as? String {
            markers.append(contentsOf: markerTimes(from: value))
        }
    }

    private func normalizedMarkerTime(_ value: Double) -> Double {
        value > 1000 ? value / 1000 : value
    }

    private func markerTimes(from string: String) -> [Double] {
        var result: [Double] = []
        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)

        if let lrcRegex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#) {
            for match in lrcRegex.matches(in: string, range: range) {
                let minutes = Double(nsString.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsString.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction: Double
                if fractionRange.location != NSNotFound {
                    let value = nsString.substring(with: fractionRange)
                    fraction = (Double(value) ?? 0) / pow(10, Double(value.count))
                } else {
                    fraction = 0
                }
                result.append(minutes * 60 + seconds + fraction)
            }
        }

        if let colonRegex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?(?!\d)"#) {
            for match in colonRegex.matches(in: string, range: range) {
                let minutes = Double(nsString.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsString.substring(with: match.range(at: 2))) ?? 0
                result.append(minutes * 60 + seconds)
            }
        }

        if result.isEmpty, let numeric = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result.append(normalizedMarkerTime(numeric))
        }

        return result
    }
}

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    private let chineseMusicLyricsProvider = ChineseMusicLyricsProvider()

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false
    @Published var detectedMusicAppName: String = "Unknown"
    @Published var lyricsProviderName: String = "Generic lyrics provider"
    @Published var chorusMarkers: [Double] = []

    private var artworkData: Data? = nil
    private var lyricsRequestID = UUID()

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .sink { [weak self] change in
                guard let self else { return }

                if change.newValue {
                    self.refreshLyrics()
                } else if !Defaults[.showLyricsBelowMusicLive] {
                    self.clearLyrics()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.showLyricsBelowMusicLive)
            .sink { [weak self] change in
                guard let self else { return }

                if change.newValue {
                    self.refreshLyrics()
                } else if !Defaults[.enableLyrics] {
                    self.clearLyrics()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .combineLatest(Defaults.publisher(.showLyricsBelowMusicLive))
            .sink { [weak self] enableLyricsChange, showLyricsBelowMusicLiveChange in
                guard let self else { return }

                if !enableLyricsChange.newValue && !showLyricsBelowMusicLiveChange.newValue {
                    self.clearLyrics()
                }
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    private func clearLyrics() {
        lyricsRequestID = UUID()
        DispatchQueue.main.async {
            self.isFetchingLyrics = false
            self.currentLyrics = ""
            self.syncedLyrics = []
            self.chorusMarkers = []
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            self.updateDetectedMusicApp(bundleIdentifier: state.bundleIdentifier)
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    private func updateDetectedMusicApp(bundleIdentifier: String?) {
        if let platform = ChineseMusicPlatform(bundleIdentifier: bundleIdentifier) {
            detectedMusicAppName = platform.displayName
            lyricsProviderName = "\(platform.displayName) lyrics"
        } else if let bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            detectedMusicAppName = "Apple Music"
            lyricsProviderName = "Apple Music lyrics"
        } else if let bundleIdentifier, !bundleIdentifier.isEmpty {
            detectedMusicAppName = bundleIdentifier
            lyricsProviderName = "Generic lyrics provider"
        } else {
            detectedMusicAppName = "Unknown"
            lyricsProviderName = "Generic lyrics provider"
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    func refreshLyrics() {
        fetchLyricsIfAvailable(
            bundleIdentifier: bundleIdentifier,
            title: songTitle,
            artist: artistName
        )
    }

    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String) {
        guard (Defaults[.enableLyrics] || Defaults[.showLyricsBelowMusicLive]), !title.isEmpty else {
            clearLyrics()
            return
        }

        let requestID = UUID()
        lyricsRequestID = requestID

        if let platform = ChineseMusicPlatform(bundleIdentifier: bundleIdentifier) {
            Task { @MainActor in
                self.isFetchingLyrics = true
                self.currentLyrics = ""
                self.chorusMarkers = []
                if await self.fetchLyricsFromChineseMusicPlatform(platform: platform, title: title, artist: artist, requestID: requestID) {
                    return
                }
                await self.fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
            }
            return
        }

        // Prefer native Apple Music lyrics when available
        if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            Task { @MainActor in
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                guard !runningApps.isEmpty else {
                    await self.fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
                    return
                }

                self.isFetchingLyrics = true
                self.currentLyrics = ""
                self.chorusMarkers = []
                do {
                    let script = """
                    tell application \"Music\"
                        if it is running then
                            if player state is playing or player state is paused then
                                try
                                    set l to lyrics of current track
                                    if l is missing value then
                                        return \"\"
                                    else
                                        return l
                                    end if
                                on error
                                    return \"\"
                                end try
                            else
                                return \"\"
                            end if
                        else
                            return \"\"
                        end if
                    end tell
                    """
                    if let result = try await AppleScriptHelper.execute(script), let lyricsString = result.stringValue, !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard self.lyricsRequestID == requestID else { return }
                        self.currentLyrics = lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.isFetchingLyrics = false
                        self.syncedLyrics = []
                        self.chorusMarkers = []
                        return
                    }
                } catch {
                    // fall through to web lookup
                }
                await self.fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
            }
        } else {
            Task { @MainActor in
                self.isFetchingLyrics = true
                self.currentLyrics = ""
                self.chorusMarkers = []
                await self.fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
            }
        }
    }

    @MainActor
    private func fetchLyricsFromChineseMusicPlatform(platform: ChineseMusicPlatform, title: String, artist: String, requestID: UUID) async -> Bool {
        guard let result = await chineseMusicLyricsProvider.fetchLyrics(platform: platform, title: title, artist: artist),
              !result.plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard lyricsRequestID == requestID else { return true }

        self.currentLyrics = result.plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if let synced = result.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.syncedLyrics = self.parseLRC(synced)
        } else {
            self.syncedLyrics = []
        }
        self.chorusMarkers = result.chorusMarkers
        self.isFetchingLyrics = false
        return true
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    @MainActor
    private func fetchLyricsFromWeb(title: String, artist: String, requestID: UUID) async {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            guard lyricsRequestID == requestID else { return }
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            self.chorusMarkers = []
            return
        }

        // LRCLIB simple search (no auth): https://lrclib.net/api/search?track_name=...&artist_name=...
        let urlString = "https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        guard let url = URL(string: urlString) else {
            guard lyricsRequestID == requestID else { return }
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            self.chorusMarkers = []
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard lyricsRequestID == requestID else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.currentLyrics = ""
                self.isFetchingLyrics = false
                self.chorusMarkers = []
                return
            }
            if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = jsonArray.first {
                // Prefer plain lyrics (syncedLyrics may also be present)
                let plain = (first["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let synced = (first["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolved = plain.isEmpty ? synced : plain
                self.currentLyrics = resolved
                self.isFetchingLyrics = false
                if !synced.isEmpty {
                    self.syncedLyrics = self.parseLRC(synced)
                } else {
                    self.syncedLyrics = []
                }
                self.chorusMarkers = []
            } else {
                self.currentLyrics = ""
                self.isFetchingLyrics = false
                self.syncedLyrics = []
                self.chorusMarkers = []
            }
        } catch {
            guard lyricsRequestID == requestID else { return }
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            self.syncedLyrics = []
            self.chorusMarkers = []
        }
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        let timestampPattern = #"\[(?:(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?|(\d{1,8}),\d{1,8})\]"#
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return [] }

        lrc.split(separator: "\n").forEach { lineSub in
            let line = String(lineSub)
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { return }

            for (index, match) in matches.enumerated() {
                let textStart = match.range.location + match.range.length
                let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : nsLine.length
                guard nextStart >= textStart else { continue }

                let rawText = nsLine.substring(with: NSRange(location: textStart, length: nextStart - textStart))
                let text = cleanLyricText(rawText)
                if !text.isEmpty {
                    result.append((timeFromTimedLyricMatch(match, in: nsLine), text))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private func timeFromTimedLyricMatch(_ match: NSTextCheckingResult, in line: NSString) -> Double {
        let millisecondRange = match.range(at: 4)
        if millisecondRange.location != NSNotFound {
            return (Double(line.substring(with: millisecondRange)) ?? 0) / 1000
        }

        let minutesRange = match.range(at: 1)
        let secondsRange = match.range(at: 2)
        guard minutesRange.location != NSNotFound, secondsRange.location != NSNotFound else {
            return 0
        }

        let minutes = Double(line.substring(with: minutesRange)) ?? 0
        let seconds = Double(line.substring(with: secondsRange)) ?? 0
        let fractionRange = match.range(at: 3)
        let fraction: Double

        if fractionRange.location != NSNotFound {
            let value = line.substring(with: fractionRange)
            let divisor = pow(10.0, Double(value.count))
            fraction = (Double(value) ?? 0) / divisor
        } else {
            fraction = 0
        }

        return minutes * 60 + seconds + fraction
    }

    private func cleanLyricText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[(?:(?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d{1,3})?|\d{1,8},\d{1,8})\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<\d{1,8},\d{1,8}(?:,\d+)?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[a-zA-Z]+:[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lyricLine(at elapsed: Double) -> String {
        activeLyricLine(at: elapsed).text
    }

    func activeLyricLine(at elapsed: Double) -> ActiveLyricLine {
        guard !syncedLyrics.isEmpty else {
            return ActiveLyricLine(
                text: plainLyricLine(at: elapsed),
                startTime: nil,
                nextStartTime: nil
            )
        }

        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return ActiveLyricLine(
            text: syncedLyrics[idx].text,
            startTime: syncedLyrics[idx].time,
            nextStartTime: idx + 1 < syncedLyrics.count ? syncedLyrics[idx + 1].time : nil
        )
    }

    func plainLyricLine(at elapsed: Double) -> String {
        let lines = currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "No lyrics found" }
        guard songDuration > 0 else { return lines[0] }

        let progress = min(max(elapsed / songDuration, 0), 1)
        let index = min(Int(progress * Double(lines.count)), lines.count - 1)
        return lines[index]
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
