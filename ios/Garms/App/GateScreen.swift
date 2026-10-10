import SwiftUI
import AuthenticationServices
import ClerkKit

/// The only way in: Sign in with Apple, handed to Clerk's native Apple sign-in.
struct GateScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var signingIn = false
    @State private var failure: String?

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
            SignInWithAppleButton(.signIn) { request in
                failure = nil
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task { await complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .disabled(signingIn)
            .opacity(signingIn ? 0.5 : 1)
        }
        .padding(24)
    }

    private func complete(_ result: Result<ASAuthorization, Error>) async {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                failure = "Apple didn't return a sign-in token. Try again."
                return
            }
            signingIn = true
            defer { signingIn = false }
            // Signs up when new (Apple only shares the name the first time), otherwise signs in.
            try await Clerk.shared.auth.signUpWithIdToken(token, provider: .apple,
                firstName: credential.fullName?.givenName, lastName: credential.fullName?.familyName)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // Cancelling is harmless: stay on the gate quietly.
        } catch {
            failure = "Couldn't sign in. \(error.localizedDescription) Try again."
        }
    }
}

#Preview { GateScreen() }
