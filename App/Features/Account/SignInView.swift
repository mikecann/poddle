import SwiftUI
import PoddleKit

/// The first thing you see signed out: Poddle waving hello, then Apple or Google on puffy buttons. Debug simulator
/// builds also get a test sign-in that picks an email (only works on dev, see convex/auth.ts).
struct SignInView: View {
    @Environment(Account.self) private var account

    @State private var working: String?
    @State private var errorMessage: String?
    @State private var sheet = SignInSheet()
    #if DEBUG && targetEnvironment(simulator)
    @State private var testEmail = UserDefaults.standard.string(forKey: "PoddleTestSignIn") ?? "mike.cann@gmail.com"
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                VStack(spacing: 14) {
                    Companion(pose: .waving, motion: .wave, size: 190)
                        .frame(height: 190)
                    PoddleWordmark(size: 48)
                    Text("Your shows, your Up Next and your listening stats, on every device you sign in on.")
                        .font(.text(17, .medium))
                        .foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                VStack(spacing: 12) {
                    providerButton("Sign in with Apple", id: "apple", fill: Palette.inverse, text: Palette.inverseInk) {
                        Image(systemName: "apple.logo").font(.system(size: 19, weight: .semibold))
                    } action: { signIn(.apple) }

                    providerButton("Sign in with Google", id: "google", fill: Palette.card, text: Palette.ink) {
                        GoogleG()
                    } action: { signIn(.google) }

                    #if DEBUG && targetEnvironment(simulator)
                    testSignIn.padding(.top, 10)
                    #endif

                    if let errorMessage {
                        HStack(spacing: 10) {
                            Companion(pose: .confused, motion: .tilt, size: 56, tappable: false)
                                .frame(width: 56, height: 56)
                            Text(errorMessage)
                        }
                            .accessibilityIdentifier("signIn.error")
                            .font(.text(14, .medium))
                            .foregroundStyle(Palette.tomato)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 4)
                    }
                }
                .disabled(working != nil)

                Text("Signing in with Apple and Google using the same email gets you the same account.")
                    .font(.text(13.5, .medium))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        #if DEBUG && targetEnvironment(simulator)
        .task {
            // `-PoddleTestSignIn <email>`: sign straight in at launch (once, while signed out).
            if UserDefaults.standard.string(forKey: "PoddleTestSignIn") != nil, !Self.autoSignInTried {
                Self.autoSignInTried = true
                testSignInNow()
            }
        }
        #endif
    }

    private func providerButton(_ title: String, id: String, fill: Color, text: Color,
                                @ViewBuilder icon: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if working == id { ProgressView().tint(text) } else { icon() }
                Text(title)
            }
            .font(.text(17, .bold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .raised(Capsule(), fill: fill)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("signIn.\(id)")
    }

    #if DEBUG && targetEnvironment(simulator)
    nonisolated(unsafe) private static var autoSignInTried = false

    private var testSignIn: some View {
        VStack(spacing: 8) {
            TextField("Email", text: $testEmail)
                .font(.mono(14))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .well(Capsule())
                .accessibilityIdentifier("signIn.testEmail")
            Button { testSignInNow() } label: {
                HStack(spacing: 6) {
                    if working == "test" { ProgressView() } else { Image(systemName: "person.crop.circle.badge.checkmark") }
                    Text("Test sign-in (simulator, dev only)")
                }
                .font(.text(14, .semibold))
                .foregroundStyle(Palette.ink2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("signIn.test")
        }
    }

    private func testSignInNow() {
        run("test") { try await account.signInForTesting(email: testEmail.trimmingCharacters(in: .whitespaces)) }
    }
    #endif

    private func signIn(_ provider: Account.Provider) {
        run(provider == .apple ? "apple" : "google") { try await account.signIn(with: provider, sheet: sheet) }
    }

    private func run(_ id: String, _ body: @escaping () async throws -> Void) {
        working = id
        errorMessage = nil
        Task {
            do {
                try await body()
            } catch AccountError.cancelled {
                // Closed the sheet: nothing to say.
            } catch {
                errorMessage = error.localizedDescription
            }
            working = nil
        }
    }
}

/// Google's "G", in its four colours.
private struct GoogleG: View {
    var body: some View {
        Text("G")
            .font(.system(size: 21, weight: .bold, design: .rounded))
            .foregroundStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .blue, .red], center: .center))
    }
}
