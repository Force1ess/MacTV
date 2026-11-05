import AppKit
import MTVCore
import SwiftUI

/// Reads only notices shipped inside this application. No account or media paths.
@MainActor final class AboutMacTV: ObservableObject {
  struct Notice: Identifiable {
    let id: String
    let title: String
    let file: URL
  }
  enum Page: String { case credits, licenses, document }
  @Published var isPresented = false
  @Published var page: Page = .credits
  @Published var selection = 0
  @Published private(set) var notices: [Notice] = []
  @Published private(set) var document = ""
  weak var scrollView: NSScrollView?
  var activeNotice: Notice? { notices.indices.contains(selection) ? notices[selection] : nil }
  var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return info["MacTVReleaseVersion"] as? String ?? info["CFBundleShortVersionString"] as? String ?? ""
  }
  var logo: NSImage? {
    Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Attribution/tmdb.svg")) }
  }
  func present() {
    notices = Self.bundledNotices(); page = .credits; selection = 0; isPresented = true
  }
  func handle(_ action: InputAction) {
    if page == .document {
      switch action {
      case .up, .left: scroll(-1)
      case .down, .right: scroll(1)
      case .back, .menu: document = ""; page = .licenses
      case .home: close()
      default: break
      }
      return
    }
    let count = page == .credits ? 4 : notices.count
    switch action {
    case .up, .left: selection = max(0, selection - 1)
    case .down, .right: selection = min(max(0, count - 1), selection + 1)
    case .select: activate()
    case .back, .menu:
      if page == .licenses { page = .credits; selection = 2 } else { close() }
    case .home: close()
    default: break
    }
  }
  func activate() {
    if page == .credits {
      if selection == 2 { page = .licenses; selection = 0; return }
      let addresses = [0: "https://www.themoviedb.org", 1: "https://www.tvmaze.com", 3: "https://github.com/Force1ess/MacTV"]
      if let address = addresses[selection], let url = URL(string: address) { NSWorkspace.shared.open(url) }
    } else if page == .licenses, let notice = activeNotice {
      // Refuse linked paths and oversized/missing notices instead of reading arbitrary files.
      if Self.isBundledRegularFile(notice.file),
        let size = try? notice.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
        let data = try? Data(contentsOf: notice.file),
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
        document = text
      } else { document = L("This notice could not be opened. Reinstall MacTV to restore its bundled notices.") }
      page = .document
    }
  }
  func close() { isPresented = false; page = .credits; document = ""; scrollView = nil }
  private func scroll(_ direction: CGFloat) {
    guard let scrollView, let view = scrollView.documentView else { return }
    let clip = scrollView.contentView
    let offset = max(0, min(view.bounds.height - clip.bounds.height,
      clip.bounds.origin.y + direction * max(80, clip.bounds.height * 0.75)))
    clip.scroll(to: NSPoint(x: 0, y: offset)); scrollView.reflectScrolledClipView(clip)
  }
  private static func isBundledRegularFile(_ file: URL) -> Bool {
    guard let root = Bundle.main.resourceURL?.standardizedFileURL,
      file.standardizedFileURL.path.hasPrefix(root.path + "/"),
      let realRoot = try? root.resourceValues(forKeys: [.isDirectoryKey]), realRoot.isDirectory == true else { return false }
    var current = file.standardizedFileURL
    while current.path != root.path {
      guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return false }
      current.deleteLastPathComponent()
    }
    return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
  private static func bundledNotices() -> [Notice] {
    guard let root = Bundle.main.resourceURL else { return [] }
    var files: [URL] = [root.appendingPathComponent("MacTV-LICENSE.txt"),
      root.appendingPathComponent("Attribution/DEPENDENCY-NOTICES.txt")]
    for directory in ["MPVNativeEngine/licenses", "RimeEngine/licenses", "SubtitleTool/licenses", "VLCEngine/licenses"] {
      let base = root.appendingPathComponent(directory)
      guard let iterator = FileManager.default.enumerator(at: base,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
      for case let file as URL in iterator {
        if files.count >= 512 { break }
        if isBundledRegularFile(file) { files.append(file) }
      }
    }
    return files.filter(isBundledRegularFile).map { file in
      let relative = String(file.path.dropFirst(root.path.count + 1))
      return Notice(id: relative, title: relative == "MacTV-LICENSE.txt" ? "MacTV · GPL-3.0" : relative == "Attribution/DEPENDENCY-NOTICES.txt" ? L("Third-party Acknowledgements") :
        relative.replacingOccurrences(of: "/licenses/", with: " · ").replacingOccurrences(of: "/", with: " · "), file: file)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
}

struct AboutMacTVPanel: View {
  @ObservedObject var controller: AboutMacTV
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text(controller.page == .credits ? L("About MacTV") : controller.page == .licenses ? L("Open-source licenses") : controller.activeNotice?.title ?? "")
            .font(.system(size: 36, weight: .bold)).lineLimit(2)
          Spacer()
          if controller.page == .credits { Text(controller.version).font(.title3).foregroundStyle(.secondary) }
        }
        if controller.page == .credits {
          Text(L("A home for your films, music and photos on the big screen.")).font(.title3).foregroundStyle(.secondary)
          row(0) {
            VStack(alignment: .leading, spacing: 14) {
              if let logo = controller.logo { Image(nsImage: logo).resizable().scaledToFit().frame(width: 180, height: 24) }
              else { Text("TMDB").font(.title3.bold()) }
              Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
            }
          }
          row(1) { VStack(alignment: .leading, spacing: 7) {
            Text("TVmaze").font(.title3.bold())
            Text(L("TV information from TVmaze, licensed under CC BY-SA. Open TVmaze →")).font(.system(size: 17))
          } }
          row(2) { Label(L("Open-source licenses"), systemImage: "doc.text").font(.title3) }
          row(3) { Label(L("MacTV on GitHub"), systemImage: "arrow.up.right.square").font(.title3) }
        } else if controller.page == .licenses {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(spacing: 6) {
                ForEach(Array(controller.notices.enumerated()), id: \.element.id) { index, notice in
                  row(index) { Text(notice.title).font(.system(size: 19)).lineLimit(2) }.id(index)
                }
              }
            }.onChange(of: controller.selection) { _, index in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) } }
          }
        } else { NoticeText(controller: controller).frame(maxHeight: .infinity) }
        Text(controller.page == .document ? L("↑ ↓ Scroll · Esc / Backspace Back") : L("↑ ↓ Move · Return Open · Esc / Backspace Back"))
          .font(.system(size: 16)).foregroundStyle(.secondary)
      }.padding(32).frame(width: 880, height: 650).tvPopupSurface(radius: 28)
    }.foregroundStyle(.primary)
  }
  private func row<Content: View>(_ index: Int, @ViewBuilder content: @escaping () -> Content) -> some View {
    TVButton(selected: controller.selection == index, action: { controller.selection = index; controller.activate() },
      hover: { controller.selection = index }) {
        HStack { content(); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
          .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      }
  }
}

private struct NoticeText: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var controller: AboutMacTV
  final class Coordinator {
    weak var controller: AboutMacTV?
    init(_ controller: AboutMacTV) { self.controller = controller }
  }
  func makeCoordinator() -> Coordinator { Coordinator(controller) }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    if coordinator.controller?.scrollView === scroll { coordinator.controller?.scrollView = nil }
  }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    let text = NSTextView(); text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
    text.font = .systemFont(ofSize: 18); text.textColor = .white; text.textContainerInset = NSSize(width: 16, height: 16)
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
    scroll.documentView = text; controller.scrollView = scroll
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    text.textColor = colorScheme == .dark ? .white : .black
    guard text.string != controller.document else { return }
    text.string = controller.document; text.setFrameSize(NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height))
    text.sizeToFit(); scroll.contentView.scroll(to: .zero)
  }
}
