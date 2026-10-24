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
        .sheet(item: $app.sheet, onDismiss: {
            if app.nowPlayingAfterSheet {
                app.nowPlayingAfterSheet = false
                app.showNowPlaying = true
            }
        }) { SheetHost(route: $0) }
        .modifier(MobileDownloadPrompt())
        .modifier(CompanionDirector())
        // Up Next changed: download what's coming, clean up what's done.
        .onChange(of: store.snapshot.queue.map(\.episodeId)) { _, queue in
            // First launch with no cache: the queue arrives after the player was set up.
            if player.currentEpisodeId == nil, let head = queue.first { player.load(head) }
            AppServices.current?.runHousekeeping()
        }
        // Their settings just arrived (a fresh sign-in): now it's safe to auto-download.
        .onChange(of: store.settingsReady) { _, ready in if ready { AppServices.current?.runHousekeeping() } }
        // Ask for notifications after the first subscribe, not on first launch (when the library
        // arriving from Convex also bumps the count from zero).
        .onChange(of: store.library.count) { old, new in if old > 0, new > old { push.requestAuthorizationIfNeeded() } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .poddleDeviceShaken)) { _ in player.extendSleepTimer() }
        .fullScreenCover(isPresented: $app.showNowPlaying) { NowPlayingView() }
        .fullScreenCover(isPresented: $app.showYearInReview) { YearInReviewView() }
        #else
        .sheet(isPresented: $app.showNowPlaying) { NowPlayingView().frame(width: 430, height: 860) }
        .sheet(isPresented: $app.showYearInReview) { YearInReviewView().frame(width: 460, height: 860) }
        #endif
    }
}

/// iPhone: the cloud tab bar with the mini player above it. Every tab stays alive so scroll
/// positions and navigation survive switching; only the visible one lets the companion move.
private struct PhoneRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(\.player) private var player
    @AppStorage(CompanionSettings.showKey) private var showPoddle = true
    @State private var barHeight: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        let covered = app.showNowPlaying || app.showYearInReview
        ZStack {
            ForEach(Tab.allCases) { tab in
                TabRoot(tab: tab)
                    .opacity(app.tab == tab ? 1 : 0)
                    .allowsHitTesting(app.tab == tab)
                    .accessibilityHidden(app.tab != tab)
                    .environment(\.companionActive, app.tab == tab && !covered)
            }
        }
        .environment(\.bottomBarHeight, barHeight)
        // An overlay that each screen makes room for (`bottomBarRoom`), not a `safeAreaInset`.
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                UndoToastView().padding(.horizontal, 10)
                MobileAllowanceChip()
                VStack(spacing: 6) {
                    MiniPlayer().padding(.horizontal, 10)
                    PoddleTabBar(selection: $app.tab)
                }
                // Content scrolling under the bottom bar fades into the paper, so Poddle's strip
                // never sits on top of a row's text or buttons.
                .background { BottomFade() }
                .overlay(alignment: .topTrailing) {
                    // An episode just finished: he pops up where he was peeking, then settles back.
                    if showPoddle, app.companion.celebrating, !covered {
                        CelebrationPop()
                            .padding(.trailing, 4)
                            .offset(y: -80)
                    }
                }
            }
            .environment(\.companionActive, !covered)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.item?.id)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.undo.toast?.id)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
        .background(PaperBackground())
    }
}

/// iPad and Mac: a sidebar with the same four sections, mini player under the detail.
private struct SidebarRoot: View {
    @Environment(AppModel.self) private var app
    @State private var barHeight: CGFloat = 0

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
                    BrandLockup(size: 22)
                        .padding(.leading, -12)
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
                .environment(\.bottomBarHeight, barHeight)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        UndoToastView()
                        MobileAllowanceChip()
                        MiniPlayer()
                    }
                        .background { BottomFade().padding(.horizontal, -400).padding(.bottom, -10) }
                        .overlay(alignment: .topTrailing) {
                            if app.companion.celebrating, !app.showNowPlaying {
                                CelebrationPop().offset(y: -80)
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.undo.toast?.id)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
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
                case .profile: SettingsView(isTab: true)
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
                .bottomBarRoom()
            }
            .background(Palette.paper.ignoresSafeArea())
            .hidesSystemNavBar()
            .bottomBarRoom()
        }
    }
}

extension EnvironmentValues {
    /// How tall the mini player, tab bar and Undo toast are, from the bottom of the safe area.
    @Entry var bottomBarHeight: CGFloat = 0
}

/// Room at the bottom of a screen for the bar over it, so the last row scrolls clear of the mini
/// player while rows still pass under the bar's fade on the way. It has to be applied inside the
/// `NavigationStack`: the stack doesn't pass a `safeAreaInset` from outside it on to its screens,
/// whose lists then only made room for the home indicator and kept their last rows under the bar.
private struct BottomBarRoom: ViewModifier {
    @Environment(\.bottomBarHeight) private var height
    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, height)
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

    fileprivate func bottomBarRoom() -> some View { modifier(BottomBarRoom()) }

    /// Cream sheet with the grabber, matching the design's sheets.
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

/// A regular image set mirrors the app icon for in-app brand moments.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Paper behind the bottom bar, fading in over its top edge (one gradient, no blur or blending).
private struct BottomFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Palette.paper.opacity(0), Palette.paper], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Palette.paper
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}
