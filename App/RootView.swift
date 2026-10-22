import SwiftUI
import PoddleKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PoddleStore.self) private var store
    @Environment(PushCoordinator.self) private var push
    @Environment(\.player) private var player
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var app = app
        Group {
            #if os(iOS)
            if sizeClass == .compact { PhoneRoot() } else { SidebarRoot() }
            #else
            SidebarRoot()
            #endif
        }
        .sheet(item: $app.sheet) { SheetHost(route: $0) }
        .modifier(MobileDownloadPrompt())
        // Up Next changed: download what's coming, clean up what's done.
        .onChange(of: store.snapshot.queue.map(\.episodeId)) { _, queue in
            // First launch with no cache: the queue arrives after the player was set up.
            if player.currentEpisodeId == nil, let head = queue.first { player.load(head) }
            AppServices.current?.runHousekeeping()
        }
        // Ask for notifications after the first subscribe, not on first launch (when the library
        // arriving from Convex also bumps the count from zero).
        .onChange(of: store.library.count) { old, new in if old > 0, new > old { push.requestAuthorizationIfNeeded() } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .poddleDeviceShaken)) { _ in player.extendSleepTimer() }
        .fullScreenCover(isPresented: $app.showNowPlaying) { NowPlayingView().preferredColorScheme(.dark) }
        .fullScreenCover(isPresented: $app.showYearInReview) { YearInReviewView().preferredColorScheme(.dark) }
        #else
        .sheet(isPresented: $app.showNowPlaying) { NowPlayingView().frame(width: 430, height: 860) }
        .sheet(isPresented: $app.showYearInReview) { YearInReviewView().frame(width: 460, height: 860) }
        #endif
    }
}

/// iPhone: custom paper tab bar with the mini player above it. Every tab stays alive so scroll
/// positions and navigation survive switching.
private struct PhoneRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(\.player) private var player

    var body: some View {
        @Bindable var app = app
        ZStack {
            ForEach(Tab.allCases) { tab in
                TabRoot(tab: tab)
                    .opacity(app.tab == tab ? 1 : 0)
                    .allowsHitTesting(app.tab == tab)
                    .accessibilityHidden(app.tab != tab)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                UndoToastView().padding(.horizontal, 8)
                MobileAllowanceChip()
                MiniPlayer().padding(.horizontal, 8)
                PoddleTabBar(selection: $app.tab)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.item?.id)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.undo.toast?.id)
        }
        .overlay { GrainOverlay().ignoresSafeArea() }
        .background(PaperBackground())
    }
}

/// iPad and Mac: a sidebar with the same four sections, mini player under the detail.
private struct SidebarRoot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: Binding<Tab?>(get: { app.tab }, set: { if let t = $0 { app.tab = t } })) {
                Section {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                } header: {
                    HStack(spacing: 8) {
                        AppMark(size: 22)
                        Text("Poddle").font(.rounded(17, .heavy)).foregroundStyle(Palette.ink)
                    }
                    .padding(.bottom, 6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper2)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            #if os(macOS)
            .toolbar(removing: .sidebarToggle)
            #endif
        } detail: {
            TabRoot(tab: app.tab)
                .id(app.tab)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        UndoToastView()
                        MobileAllowanceChip()
                        MiniPlayer()
                    }
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.undo.toast?.id)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .overlay { GrainOverlay().ignoresSafeArea() }
                .background(PaperBackground())
        }
        .tint(Palette.tomato)
    }
}

/// The navigation stack for one tab.
struct TabRoot: View {
    var tab: Tab
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack(path: app.path(tab)) {
            Group {
                switch tab {
                case .upNext: UpNextView()
                case .library: LibraryView()
                case .discover: DiscoverView()
                case .stats: StatsView()
                }
            }
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case let .podcast(id): PodcastView(podcastId: id)
                    case let .episode(id): EpisodeDetailView(episodeId: id)
                    case .settings: SettingsView()
                    case .importOvercast: ImportView()
                    }
                }
                .background(Palette.paper.ignoresSafeArea())
                .hidesSystemNavBar()
            }
            .background(Palette.paper.ignoresSafeArea())
            .hidesSystemNavBar()
        }
    }
}

/// Sheets presented from anywhere in the main UI.
struct SheetHost: View {
    var route: SheetRoute
    var body: some View {
        switch route {
        case let .showSettings(podcastId): ShowSettingsSheet(podcastId: podcastId)
        case .queue: QueueSheet()
        case let .episode(id):
            NavigationStack { EpisodeDetailView(episodeId: id, inSheet: true).hidesSystemNavBar() }
                .poddleSheet(detents: [.large])
        }
    }
}

extension View {
    /// Screens draw their own paper headers, so the system bar is hidden. Swipe-back still works
    /// (see `UINavigationController` below).
    func hidesSystemNavBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        toolbar(.hidden, for: .windowToolbar)
        #endif
    }

    /// Paper sheet with the grabber, matching the design's sheets.
    func poddleSheet(detents: Set<PresentationDetent> = [.large]) -> some View {
        self
            .background(PaperBackground())
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationBackground(Palette.paper)
            .presentationCornerRadius(38)
    }
}

#if os(iOS)
import UIKit

/// Keep the interactive swipe-back gesture when the navigation bar is hidden.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif

/// The Poddle mark: tomato tile with a cream arch, gold needle and a dotted base.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xE7653D), Color(hex: 0xC9461F)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, sz in
                let u = sz.width / 60
                var arch = Path()
                arch.move(to: CGPoint(x: 13.5 * u, y: 38 * u))
                arch.addLine(to: CGPoint(x: 13.5 * u, y: 30 * u))
                arch.addArc(center: CGPoint(x: 30 * u, y: 30 * u), radius: 16.5 * u, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                arch.addLine(to: CGPoint(x: 46.5 * u, y: 38 * u))
                ctx.stroke(arch, with: .color(Color(hex: 0xF7ECDC)), style: StrokeStyle(lineWidth: 3.2 * u, lineCap: .round))
                var needle = ctx
                needle.translateBy(x: 30 * u, y: 38 * u)
                needle.rotate(by: .degrees(28))
                needle.fill(Path(roundedRect: CGRect(x: -1.6 * u, y: -20 * u, width: 3.2 * u, height: 20 * u), cornerRadius: 1.6 * u), with: .color(Color(hex: 0xF2C14E)))
                var x: CGFloat = 12
                while x < 48 {
                    ctx.fill(Path(roundedRect: CGRect(x: x * u, y: 42 * u, width: 3 * u, height: 6 * u), cornerRadius: 1.2 * u), with: .color(Color(hex: 0xF7ECDC)))
                    x += 6
                }
            }
        }
        .frame(width: size, height: size)
    }
}
