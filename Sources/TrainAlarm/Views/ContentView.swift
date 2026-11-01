import SwiftUI
import TrainAlarmKit

/// The menu bar window: sign-in, the current ride, or an empty/error state, plus a footer.
struct ContentView: View {
    let store: RideStore
    @State private var isEditingLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isEditingLink {
                    IdosLinkEditor(store: store, isPresented: $isEditingLink)
                } else if !store.isConfigured {
                    SignInView(store: store, onUseIdosLink: { isEditingLink = true })
                } else if let ride = store.ride {
                    RideView(ride: ride, now: store.now)
                } else {
                    placeholder
                }
            }
            .padding(16)

            if store.isConfigured && !isEditingLink {
                if let error = store.errorMessage, store.ride != nil {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                Divider()
                footer
            }
        }
        .frame(width: 340)
        .task { await store.refreshIfStale() }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 10) {
            if !store.hasLoaded {
                ProgressView().controlSize(.small)
            } else if let error = store.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(error)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await store.refresh() } }
            } else {
                Image(systemName: "ticket")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No upcoming rides")
                    .font(.headline)
                Text("Tickets from Můj vlak appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 16, height: 16)
            .disabled(store.isRefreshing)
            .help("Refresh")

            Menu {
                if store.idosLink != nil {
                    Button("Stop Tracking IDOS Link") { store.clearIdosLink() }
                } else {
                    Button("Track IDOS Link…") { isEditingLink = true }
                }
                if let account = store.account {
                    Divider()
                    Section(account) {
                        Button("Sign Out") { store.signOut() }
                    }
                }
                Divider()
                Button("Quit TrainAlarm") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var status: String {
        let source = store.idosLink != nil ? "IDOS link" : "Můj vlak"
        guard let lastUpdated = store.lastUpdated else { return source }
        return "\(source) · updated \(lastUpdated.clockTime)"
    }
}

/// Paste an IDOS connection link to track a ride that isn't on your ČD account.
struct IdosLinkEditor: View {
    let store: RideStore
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track an IDOS link")
                .font(.headline)
            TextField("https://idos.cz/vlaky/spojeni/…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error = store.errorMessage, !isLoading {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Track", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || isLoading)
            }
        }
        .onAppear { text = store.idosLink?.absoluteString ?? "" }
    }

    private func submit() {
        isLoading = true
        Task {
            if await store.track(idosLink: text) { isPresented = false }
            isLoading = false
        }
    }
}
