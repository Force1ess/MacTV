import Foundation
import Testing

@testable import MTVCore

struct LibraryTests {
  @Test func contextualPaddedEpisodesRequireCorroborationAndRespectMovieNFO() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let show = root.appendingPathComponent("Example Show (1994) 4K Restoration")
    try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = show.appendingPathComponent("Example Show 01 Part One Pilot.mp4")
    try Data().write(to: first)
    let lone = try LibraryScanner.scanResult(root: root)
    #expect(lone.items.first?.localMetadata?.episode == nil)
    let second = show.appendingPathComponent("Example Show 02 Part One Return.mp4")
    try Data().write(to: second)
    let confirmed = try LibraryScanner.scanResult(root: root, previous: lone.incremental)
    #expect(confirmed.items.compactMap { $0.localMetadata?.episode }.sorted() == [1, 2])
    #expect(confirmed.items.allSatisfy { $0.localMetadata?.seriesTitle == "Example Show" && $0.localMetadata?.year == 1994 })
    #expect(LibraryCatalog.build(confirmed.items).root.count == 1)
    try Data("<movie><title>Explicit Movie</title><year>1994</year></movie>".utf8)
      .write(to: first.deletingPathExtension().appendingPathExtension("nfo"))
    let explicit = try LibraryScanner.scanResult(root: root, previous: confirmed.incremental)
    #expect(explicit.items.first { $0.id == first.path }?.localMetadata?.episode == nil)
    #expect(explicit.items.first { $0.id == first.path }?.title == "Explicit Movie")
    try FileManager.default.removeItem(at: second)
    let reduced = try LibraryScanner.scanResult(root: root, previous: confirmed.incremental)
    #expect(reduced.items.allSatisfy { $0.localMetadata?.episode == nil })
    let rejected = MediaRecognition.numberedEpisodes(in: show, filenames: [
      "Other Show 01 Pilot.mp4", "Other Show 02 Return.mp4", "Example Show 1994 Film.mp4",
      "Example Show 1080 Resolution.mp4", "Example Show 2 Sequel.mp4"])
    #expect(rejected.isEmpty)
    #expect(MediaRecognition.numberedEpisodes(in: show, filenames: [first.lastPathComponent, second.lastPathComponent, "movie.nfo"]).isEmpty)
  }

  @Test func fansubEpisodesAndTransportStreamsAreDiscoverable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-discovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let episodes = ["[Nekomoe kissaten][Toaru Anbu no Item][01][1080p][JPTC].mp4", "[Sakurato] Some Show [02][HEVC-10bit 1080P AAC][CHS&CHT].mkv"]
    for name in episodes { try Data().write(to: root.appendingPathComponent(name)) }
    try Data().write(to: root.appendingPathComponent("Film (1998).m2ts"))
    let checksum = MediaRecognition.filename(URL(fileURLWithPath: "[Group][Watamote][02][GB_CN][720p](BC8C2B6B).mp4"))
    #expect(checksum.seriesTitle == "Watamote" && checksum.episode == 2)
    let dashed = MediaRecognition.filename(URL(fileURLWithPath: "[Group] Show - 03 [1080p][HEVC].mkv"))
    #expect(dashed.seriesTitle == "Show" && dashed.episode == 3)
    let files = try LibraryScanner.scan(root: root)
    #expect(files.count == 3)
    #expect(files.filter { $0.localMetadata?.episode != nil }.count == 2)
    #expect(LibraryCatalog.build(files).root.filter { $0.kind == .series }.count == 2)
    #expect(MediaRecognition.filename(URL(fileURLWithPath: "Movie [2026][1080p].mkv")).episode == nil)
  }

  @Test func filenameRecognitionPreservesNumericMovieTitlesAndEpisodeNumbers() {
    let examples: [(String, String, Int?)] = [
      ("Blade.Runner.2049.2017.2160p.HDR.HEVC.mkv", "Blade Runner 2049", 2017),
      ("1917.2019.1080p.BluRay.mkv", "1917", 2019),
      ("2001.A.Space.Odyssey.1968.2160p.mkv", "2001 A Space Odyssey", 1968),
      ("年会不能停 (2023) 4K.mkv", "年会不能停", 2023),
    ]
    for (name, title, year) in examples {
      let value = MediaRecognition.filename(URL(fileURLWithPath: name))
      #expect(value.title == title)
      #expect(value.year == year)
      #expect(value.episode == nil)
    }
    let episode = MediaRecognition.filename(URL(fileURLWithPath: "Family_Guy_S23E04-E05_1080p.mkv"))
    #expect(episode.seriesTitle == "Family Guy")
    #expect(episode.season == 23 && episode.episode == 4 && episode.episodeEnd == 5)
    let other = MediaRecognition.filename(URL(fileURLWithPath: "Show.Name.2x03.Pilot.WEB-DL.mkv"))
    #expect(other.seriesTitle == "Show Name" && other.season == 2 && other.episode == 3)
    #expect(other.title == "Pilot")
    #expect(MediaRecognition.filename(URL(fileURLWithPath: "A.Film.1920x1080.mp4")).episode == nil)
  }

  @Test func independentScanGroupsSeasonsAndPrioritizesSidecarMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-library-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ relative: String, _ content: String = "") throws {
      let file = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: file)
    }
    try write("Movies/A.Film.2020.1080p.mkv")
    try write("Show/Season 1/Show.S01E10.Finale.mp4")
    try write("Show/Season 1/Show.S01E02.Pilot.mp4")
    try write("Show/Season 2/S02E01.mp4")
    try write("Show/tvshow.nfo", "<tvshow><title>剧集正式名称</title><plot>系列简介</plot></tvshow>")
    let sidecar =
      "<episodedetails><title>元数据集名</title><showtitle>剧集正式名称</showtitle><season>2</season><episode>1</episode><plot>本集简介</plot></episodedetails>"
    try write("Show/Season 2/S02E01.nfo", sidecar)
    let files = try LibraryScanner.scan(root: root)
    #expect(files.count == 4)
    #expect(files.first { $0.url?.contains("A.Film") == true }?.title == "A Film")
    let catalog = LibraryCatalog.build(files)
    #expect(catalog.root.count == 2)
    let series = try #require(catalog.root.first { $0.kind == .series })
    #expect(series.title == "剧集正式名称")
    let seasons = try #require(catalog.children[series.id])
    try #require(seasons.count == 2)
    #expect(seasons.map(\.title) == ["第 1 季", "第 2 季"])
    #expect(catalog.children[seasons[0].id]?.map { $0.localMetadata?.episode } == [2, 10])
    #expect(catalog.children[seasons[1].id]?.first?.title == "元数据集名")
    #expect(
      try String(
        contentsOf: root.appendingPathComponent("Show/Season 2/S02E01.nfo"), encoding: .utf8)
        == sidecar)
    #expect(try LibraryScanner.scan(root: root, limit: 0).isEmpty)
  }

  @Test func movieNFOAndSameNamedShowsInDifferentRootsStaySeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-library-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["Movie", "CutA", "CutB"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("Movie/file.mp4"))
    try Data("<movie><title>文件夹元数据电影</title><year>2024</year></movie>".utf8).write(
      to: root.appendingPathComponent("Movie/movie.nfo"))
    for directory in ["CutA", "CutB"] {
      try Data().write(to: root.appendingPathComponent(directory + "/Same.Show.S01E01.mp4"))
    }
    let files = try LibraryScanner.scan(root: root)
    #expect(files.first { $0.title == "文件夹元数据电影" }?.localMetadata?.year == 2024)
    #expect(LibraryCatalog.build(files).root.filter { $0.kind == .series }.count == 2)
  }
}

struct LibraryLinkedMetadataTests {
  @Test func physicalSourceRetainsLinkedSidecarDescriptionWithoutChangingURLs() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-linked-" + UUID().uuidString)
    let disk = base.appendingPathComponent("disk"), links = base.appendingPathComponent("old")
    try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let video = disk.appendingPathComponent("show/Raw.S01E01.mkv")
    try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: video)
    let link = links.appendingPathComponent("Show/Season 01/S01E01.mkv")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: video)
    var old = try LibraryScanner.scan(root: links)[0]
    old.title = "Episode from NFO"; old.poster = "file:///old/poster.jpg"
    old.localMetadata?.hasSidecar = true; old.localMetadata?.seriesTitle = "Show"
    let result = LibraryLinkedMetadata.apply(try LibraryScanner.scanResult(root: disk), companions: [old], root: disk)
    #expect(result.items[0].id == video.path)
    #expect(result.items[0].url == video.absoluteString)
    #expect(result.items[0].title == "Episode from NFO")
    #expect(result.items[0].poster == old.poster)
    #expect(result.items[0].localMetadata?.seriesTitle == "Show")
    let outside = LibraryLinkedMetadata.apply(try LibraryScanner.scanResult(root: disk), companions: [old], root: links)
    #expect(outside.items[0].title != "Episode from NFO")
  }
}
