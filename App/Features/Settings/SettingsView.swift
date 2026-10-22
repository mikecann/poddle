import SwiftUI
import PoddleKit

/// The Profile tab: who's signed in, then the global defaults. Every show set to "Use default"
/// follows these live. Also pushable (with a back button) when `isTab` is false.
struct SettingsView: View {
    var isTab = false

    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(PushCoordinator.self) private var push
    @Environment(Account.self) private var account: Account?

    @State private var confirmingSignOut = false

    private var g: GlobalSettings { store.global }

    private var storageSubtitle: String? {
        guard let used = store.downloader?.storageUsed else { return nil }
        return "\(Format.bytes(used)) used. Never deletes the top 3 in Up Next."
    }

    /// Device-local, not synced: "Download on" plus the temporary mobile allowance.
    @ViewBuilder
    private func downloadNetwork(_ downloader: DownloadManager) -> some View {
        Menu {
            Picker("Download on", selection: Binding(get: { downloader.settings.mode }, set: { downloader.setMode($0) })) {
                ForEach(DownloadNetworkMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            Cell(title: "Download on", subtitle: "This device only") { MenuValue(text: downloader.settings.mode.label, isOverride: false) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        if downloader.settings.mode == .wifiOnly {
            if let remaining = downloader.mobileAllowanceRemaining {
                Cell(title: "Mobile downloads on", subtitle: MobileAllowanceChip.left(remaining), icon: "antenna.radiowaves.left.and.right", iconTint: Palette.fern) {
                    TextButton(title: "Stop", bold: true) { downloader.stopMobileAllowance() }
                }
            } else {
                Menu {
                    ForEach(MobileAllowance.allCases, id: \.self) { a in
                        Button(a.label) { downloader.allowMobile(a) }
                    }
                } label: {
                    Cell(title: "Allow mobile downloads", subtitle: "Streaming always works on mobile", icon: "antenna.radiowaves.left.and.right", iconTint: Palette.ink3) {
                        MenuValue(text: "Off", isOverride: false)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !isTab {
                    TopBar { BackButton(title: "Library") } trailing: { EmptyView() }
                }
                LargeTitle(title: isTab ? "Profile" : "Settings",
                           subtitle: isTab ? "Your account, and the defaults for every show. Shows can override any of these."
                                           : "Defaults for every show. Shows can override any of these.")
                    .padding(.top, isTab ? 16 : 6)

                connection.padding(.top, 8)

                GroupLabel(text: "Bring your stuff")
                GroupCard {
                    Button { app.push(.importOvercast, on: app.tab) } label: {
                        Cell(title: "Import from Overcast", subtitle: "Shows, played history, progress and stars", icon: "square.and.arrow.down", iconTint: Palette.tomato) {
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                GroupLabel(text: "Playback")
                GroupCard {
                    Cell(title: "Speed") {
                        WellStepper(text: Format.speedPrecise(g.speed) + "×",
                                    onDecrement: { store.setSpeed(g.speed - 0.05, scope: .allPodcasts) },
                                    onIncrement: { store.setSpeed(g.speed + 0.05, scope: .allPodcasts) })
                    }
                    toggle("Smart Speed", \.smartSpeed, subtitle: "Trims silences", icon: "waveform.path", tint: Palette.mustard)
                    toggle("Voice Boost", \.voiceBoost, subtitle: "Evens out loud and quiet voices", icon: "speaker.wave.2", tint: Palette.fern)
                    picker("Speed-up method", \.timePitch, TimePitchAlgorithm.allCases, \.label)
                }

                GroupLabel(text: "Skipping")
                GroupCard {
                    Cell(title: "Skip back") { seconds(\.skipBack) }
                    Cell(title: "Skip forward") { seconds(\.skipForward) }
                    picker("AirPods next / previous", \.headphoneMapping, HeadphoneMapping.allCases, \.label)
                    toggle("Auto-rewind on resume", \.autoRewind, subtitle: "3 s after 5 min paused, 10 s after an hour")
                    toggle("Play the next episode", \.autoAdvance)
                }

                GroupLabel(text: "Sleep timer")
                GroupCard {
                    toggle("Fade out", \.sleepFadeOut, subtitle: "Over the last 10 seconds")
                    toggle("Shake to restart", \.shakeToRestartSleep, subtitle: "Within 30 seconds of stopping")
                }

                GroupLabel(text: "New episodes")
                GroupCard {
                    Menu {
                        Picker("Where they go", selection: Binding(get: { g.autoAdd.shown }, set: { v in store.updateGlobal { $0.autoAdd = v } })) {
                            ForEach(AutoAdd.choices, id: \.self) { Text($0.choiceLabel).tag($0) }
                        }
                    } label: {
                        Cell(title: "Where they go") { MenuValue(text: g.autoAdd.choiceLabel, isOverride: false) }
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    toggle("Notifications", \.notifications)
                    if push.notAskedYet || push.isDenied {
                        Button { push.requestAuthorizationIfNeeded() } label: {
                            Cell(title: "Allow notifications", subtitle: push.isDenied ? "Turned off in system Settings" : "So new-episode alerts can show",
                                 icon: "bell.badge", iconTint: Palette.mustard) {
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(push.isDenied)
                    }
                    picker("Auto-archive unplayed", \.autoArchive, AutoArchive.allCases, \.label)
                }

                GroupLabel(text: "Downloads")
                GroupCard {
                    if let downloader = store.downloader {
                        downloadNetwork(downloader)
                    }
                    toggle("Auto-download Up Next", \.autoDownload, subtitle: "The first 10, plus new episodes from priority shows")
                    Cell(title: "Keep latest") {
                        WellStepper(text: "\(g.keepLatest) eps",
                                    onDecrement: { store.updateGlobal { $0.keepLatest = max(1, $0.keepLatest - 1) } },
                                    onIncrement: { store.updateGlobal { $0.keepLatest = min(50, $0.keepLatest + 1) } })
                    }
                    picker("Delete played files", \.deletePlayed, DeletePlayed.allCases, \.label)
                    Cell(title: "Storage cap", subtitle: storageSubtitle) {
                        WellStepper(text: "\(Int(g.storageCapGB)) GB",
                                    onDecrement: { store.updateGlobal { $0.storageCapGB = max(1, $0.storageCapGB - 1) } },
                                    onIncrement: { store.updateGlobal { $0.storageCapGB = min(100, $0.storageCapGB + 1) } })
                    }
                }

                VStack(spacing: 6) {
                    AppMark(size: 44)
                    Text("Poddle").font(.rounded(17, .heavy)).foregroundStyle(Palette.ink)
                    Text(app.isMock ? "Version 0.1 · sample data" : "Version 0.1 · synced with Convex").font(.text(12.5)).foregroundStyle(Palette.ink2)
                }
                .padding(.top, 30).padding(.bottom, 30)
                ListeningBrandFooter()
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Sign out of Poddle?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await account?.signOut() } }
        } message: {
            Text("Your library stays in your account. Downloads stay on this device.")
        }
    }

    /// Who's signed in, which deployment this is synced with, and how it's doing.
    @ViewBuilder private var connection: some View {
        if let account, let profile = account.profile {
            GroupLabel(text: "Account")
            GroupCard {
                Cell(title: profile.name ?? profile.email ?? "Signed in", subtitle: profile.name == nil ? nil : profile.email,
                     icon: "person.crop.circle", iconTint: Palette.tomato) {
                    TextButton(title: "Sign Out", bold: true) { confirmingSignOut = true }
                }
            }
        }
        GroupLabel(text: "Sync")
        GroupCard {
            if app.isMock {
                Cell(title: "Sample data", subtitle: "Launched with -PoddleMock. Nothing is synced.", icon: "shippingbox", iconTint: Palette.mustard) { EmptyView() }
            } else if let c = store.connection {
                Cell(title: "Connection", subtitle: c.deploymentName, icon: "antenna.radiowaves.left.and.right", iconTint: c.connected ? Palette.fern : Palette.ink3) {
                    Text(c.connected ? "Live" : "Offline").font(.text(14, .medium)).foregroundStyle(Palette.ink2)
                }
                if c.pending > 0 {
                    Cell(title: "Waiting to sync", subtitle: "Sent in order when the connection's back") {
                        Text("\(c.pending)").font(.text(15, .semibold)).monospacedDigit().foregroundStyle(Palette.ink2)
                    }
                }
                if c.failed > 0 {
                    Cell(title: "\(c.failed) change\(c.failed == 1 ? "" : "s") rejected", subtitle: c.error ?? "The server said no") {
                        HStack(spacing: 4) {
                            TextButton(title: "Retry", bold: true) { retryFailed() }
                            TextButton(title: "Discard") { discardFailed() }
                        }
                    }
                } else if let error = c.error {
                    Cell(title: "Last problem", subtitle: error) { EmptyView() }
                }
                if let at = c.lastSyncAt {
                    Cell(title: "Last caught up") {
                        Text(Date(timeIntervalSince1970: at / 1000), style: .relative).font(.text(14)).foregroundStyle(Palette.ink2)
                    }
                }
            } else {
                Cell(title: "Connecting…") { ProgressView() }
            }
        }
    }

    private func retryFailed() {
        guard let live = store.dataSource as? LiveStore else { return }
        Task { await live.retryFailed() }
    }

    private func discardFailed() {
        guard let live = store.dataSource as? LiveStore else { return }
        Task { await live.discardFailed() }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<GlobalSettings, Bool>, subtitle: String? = nil, icon: String? = nil, tint: Color = Palette.tomato) -> some View {
        Toggle(isOn: Binding(get: { g[keyPath: key] }, set: { v in store.updateGlobal { $0[keyPath: key] = v } })) {
            Cell(title: title, subtitle: subtitle, icon: icon, iconTint: tint) { EmptyView() }
                .padding(.horizontal, -16)
        }
        .toggleStyle(.poddle)
        .padding(.horizontal, 16)
    }

    private func seconds(_ key: WritableKeyPath<GlobalSettings, Double>) -> some View {
        let steps: [Double] = [5, 10, 15, 30, 45, 60]
        let current = g[keyPath: key]
        let i = steps.firstIndex(of: current) ?? 2
        return WellStepper(text: "\(Int(current)) s",
                           onDecrement: { store.updateGlobal { $0[keyPath: key] = steps[max(0, i - 1)] } },
                           onIncrement: { store.updateGlobal { $0[keyPath: key] = steps[min(steps.count - 1, i + 1)] } })
    }

    private func picker<V: Hashable>(_ title: String, _ key: WritableKeyPath<GlobalSettings, V>, _ all: [V], _ label: KeyPath<V, String>) -> some View {
        Menu {
            Picker(title, selection: Binding(get: { g[keyPath: key] }, set: { v in store.updateGlobal { $0[keyPath: key] = v } })) {
                ForEach(all, id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
        } label: {
            Cell(title: title) { MenuValue(text: g[keyPath: key][keyPath: label], isOverride: false) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }
}
