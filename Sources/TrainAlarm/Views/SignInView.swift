import SwiftUI

/// One-time sign-in with the Můj vlak / ČD e-shop account. Credentials go to the Keychain.
struct SignInView: View {
    let store: RideStore
    let onUseIdosLink: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "train.side.front.car")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Sign in to Můj vlak")
                    .font(.headline)
                Text("Your ČD tickets turn into live rides.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                TextField("E-mail", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isSigningIn)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: signIn) {
                Group {
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(email.isEmpty || password.isEmpty || isSigningIn)

            HStack {
                Button("Use an IDOS link", action: onUseIdosLink)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty else { return }
        isSigningIn = true
        error = nil
        Task {
            do {
                try await store.signIn(email: email, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}
