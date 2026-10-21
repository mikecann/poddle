import SwiftUI
import PoddleKit

/// Global defaults. Every show set to "Use default" follows these live.
struct SettingsView: View {
    @Environment(PoddleStore.self) private var store
    @Environment(AppModel.self) private var app

    private var g: GlobalSettings { store.global }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TopBar { BackButton(title: "Library") } trailing: { EmptyView() }
                LargeTitle(title: "Settings", subtitle: "Defaults for every show. Shows can override any of these.")
                    .padding(.top, 6)

                GroupLabel(text: "Bring your stuff").padding(.top, 8)
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
                    picker("Time-pitch", \.timePitch, TimePitchAlgorithm.allCases, \.label)
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
                    picker("Where they go", \.autoAdd, AutoAdd.allCases, \.label)
                    toggle("Notifications", \.notifications)
                    picker("Auto-archive unplayed", \.autoArchive, AutoArchive.allCases, \.label)
                }

                GroupLabel(text: "Downloads")
                GroupCard {
                    toggle("Auto-download Up Next", \.autoDownload)
                    Cell(title: "Keep latest") {
                        WellStepper(text: "\(g.keepLatest) eps",
                                    onDecrement: { store.updateGlobal { $0.keepLatest = max(1, $0.keepLatest - 1) } },
                                    onIncrement: { store.updateGlobal { $0.keepLatest = min(50, $0.keepLatest + 1) } })
                    }
                    picker("Cellular", \.cellularDownloads, CellularDownloads.allCases, \.label)
                    picker("Delete played files", \.deletePlayed, DeletePlayed.allCases, \.label)
                    Cell(title: "Storage cap") {
                        WellStepper(text: "\(Int(g.storageCapGB)) GB",
                                    onDecrement: { store.updateGlobal { $0.storageCapGB = max(1, $0.storageCapGB - 1) } },
                                    onIncrement: { store.updateGlobal { $0.storageCapGB = min(100, $0.storageCapGB + 1) } })
                    }
                }

                VStack(spacing: 6) {
                    AppMark(size: 44)
                    Text("Poddle").font(.rounded(17, .heavy)).foregroundStyle(Palette.ink)
                    Text("Version 0.1 · sample data, not synced yet").font(.text(12.5)).foregroundStyle(Palette.ink2)
                }
                .padding(.top, 30).padding(.bottom, 30)
            }
        }
        .scrollContentBackground(.hidden)
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
