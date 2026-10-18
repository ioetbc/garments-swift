import SwiftUI
import ClerkKit

/// The way in: email and password through Clerk.
struct GateScreen: View {
    /// A Clerk attempt waiting on the code Clerk emailed: verifying a new address, or a new device.
    private enum Pending { case signUp(SignUp), signIn(SignIn) }

    @State private var signingIn = false
    @State private var failure: String?
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var pending: Pending?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Garms")
                .font(.system(size: 56, weight: .bold, design: .rounded))
            Text("Collect the clothes you're thinking of buying, and arrange them into wishlists.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if pending == nil {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Sign in") { run(signIn) }
                        .buttonStyle(.borderedProminent)
                    Button("Create account") { run(signUp) }
                        .buttonStyle(.bordered)
                }
                .disabled(signingIn || email.isEmpty || password.isEmpty)
            } else {
                Text("Enter the code we emailed to \(email).")
                    .font(.footnote)
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Verify") { run(verify) }
                        .buttonStyle(.borderedProminent)
                        .disabled(signingIn || code.isEmpty)
                    Button("Back") { pending = nil; code = "" }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
    }

    private func run(_ step: @escaping () async throws -> Void) {
        failure = nil
        signingIn = true
        Task {
            defer { signingIn = false }
            do { try await step() } catch { failure = "\(error.localizedDescription) Try again." }
        }
    }

    private func signIn() async throws {
        let attempt = try await Clerk.shared.auth.signInWithPassword(identifier: email, password: password)
        switch attempt.status {
        case .complete: break
        // A new device: Clerk wants a code sent to the account's email before trusting it.
        case .needsClientTrust, .needsSecondFactor:
            pending = .signIn(try await attempt.sendMfaEmailCode())
        default: failure = "Couldn't sign in with that email and password."
        }
    }

    private func signUp() async throws {
        let attempt = try await Clerk.shared.auth.signUp(emailAddress: email, password: password)
        if attempt.status != .complete { pending = .signUp(try await attempt.sendEmailCode()) }
    }

    private func verify() async throws {
        switch pending {
        case .signUp(let attempt):
            let signUp = try await attempt.verifyEmailCode(code)
            // A verified code still leaves the sign-up open if Clerk requires more fields.
            guard signUp.status == .complete else {
                let missing = (signUp.missingFields + signUp.unverifiedFields).map(\.rawValue)
                failure = "Code accepted, but Clerk still needs: \(missing.joined(separator: ", "))."
                return
            }
        case .signIn(let attempt):
            let signIn = try await attempt.verifyMfaCode(code, type: .emailCode)
            guard signIn.status == .complete else { failure = "Clerk still needs: \(signIn.status.rawValue)."; return }
        case nil: break
        }
        pending = nil; code = ""
    }
}

#Preview { GateScreen() }
