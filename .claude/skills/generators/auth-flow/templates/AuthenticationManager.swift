import AuthenticationServices
import Foundation

/// Central authentication manager.
///
/// Coordinates Sign in with Apple, biometrics, and session management.
///
/// Usage:
/// ```swift
/// @main
/// struct MyApp: App {
///     @State private var authManager = AuthenticationManager()
///
///     var body: some Scene {
///         WindowGroup {
///             if authManager.isAuthenticated {
///                 ContentView()
///             } else {
///                 AuthenticationView()
///             }
///         }
///         .environment(authManager)
///     }
/// }
/// ```
@MainActor
@Observable
final class AuthenticationManager {
    // MARK: - Published State

    /// Whether user is currently authenticated.
    private(set) var isAuthenticated = false

    /// Current user info (if authenticated).
    private(set) var currentUser: AuthenticatedUser?

    /// Any authentication error.
    private(set) var error: AuthenticationError?

    /// Whether authentication is in progress.
    private(set) var isLoading = false

    // MARK: - Initialization

    init() {
        // Check for existing session on init
        Task {
            await self.checkExistingSession()
        }
    }

    // MARK: - Sign in with Apple

    /// Handle Sign in with Apple result.
    func handleSignInWithApple(_ result: Result<ASAuthorization, Error>) {
        self.isLoading = true
        defer { isLoading = false }

        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                self.error = .invalidCredential
                return
            }

            // Extract user info
            let userID = credential.user

            // Name only on first sign-in - save immediately
            var name: String?
            if let fullName = credential.fullName {
                name = PersonNameComponentsFormatter().string(from: fullName)
            }

            // Email may be real or relay
            let email = credential.email

            // Save to Keychain
            self.saveCredentials(userID: userID, name: name, email: email)

            // Update state
            self.currentUser = AuthenticatedUser(
                id: userID,
                name: name ?? KeychainManager.shared.get(.userName),
                email: email ?? KeychainManager.shared.get(.userEmail)
            )
            self.isAuthenticated = true
            self.error = nil

        case let .failure(authError):
            if let asError = authError as? ASAuthorizationError {
                switch asError.code {
                case .canceled:
                    // User cancelled - not an error
                    break
                case .failed:
                    self.error = .failed(authError)
                case .invalidResponse:
                    self.error = .invalidCredential
                case .notHandled:
                    self.error = .failed(authError)
                case .unknown:
                    self.error = .unknown
                case .notInteractive:
                    self.error = .failed(authError)
                @unknown default:
                    self.error = .unknown
                }
            } else {
                self.error = .failed(authError)
            }
        }
    }

    // MARK: - Biometric Authentication

    /// Authenticate using Face ID or Touch ID.
    func authenticateWithBiometrics() async -> Bool {
        self.isLoading = true
        defer { isLoading = false }

        let success = await BiometricAuthManager.shared.authenticate()

        if success {
            // Load saved user
            if let userID = KeychainManager.shared.get(.userID) {
                self.currentUser = AuthenticatedUser(
                    id: userID,
                    name: KeychainManager.shared.get(.userName),
                    email: KeychainManager.shared.get(.userEmail)
                )
                self.isAuthenticated = true
            }
        }

        return success
    }

    // MARK: - Sign Out

    /// Sign out and clear all credentials.
    func signOut() {
        KeychainManager.shared.clearAll()
        self.currentUser = nil
        self.isAuthenticated = false
        self.error = nil
    }

    // MARK: - Credential State

    /// Check if existing credentials are still valid.
    func checkCredentialState() async {
        guard let userID = KeychainManager.shared.get(.userID) else {
            self.isAuthenticated = false
            return
        }

        let state = await SignInWithAppleManager.shared.checkCredentialState(userID: userID)

        switch state {
        case .authorized:
            // Still valid
            self.currentUser = AuthenticatedUser(
                id: userID,
                name: KeychainManager.shared.get(.userName),
                email: KeychainManager.shared.get(.userEmail)
            )
            self.isAuthenticated = true

        case .revoked, .notFound:
            // User revoked or doesn't exist
            self.signOut()

        case .transferred:
            // Handle account transfer if needed
            self.signOut()

        @unknown default:
            break
        }
    }

    // MARK: - Private

    private func checkExistingSession() async {
        guard KeychainManager.shared.get(.userID) != nil else {
            return
        }
        await self.checkCredentialState()
    }

    private func saveCredentials(userID: String, name: String?, email: String?) {
        KeychainManager.shared.save(userID, for: .userID)

        if let name {
            KeychainManager.shared.save(name, for: .userName)
        }

        if let email {
            KeychainManager.shared.save(email, for: .userEmail)
        }
    }
}

// MARK: - Models

/// Authenticated user information.
struct AuthenticatedUser {
    let id: String
    let name: String?
    let email: String?
}

/// Authentication errors.
enum AuthenticationError: Error, LocalizedError {
    case invalidCredential
    case failed(Error)
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "Invalid credentials received"
        case let .failed(error):
            error.localizedDescription
        case .cancelled:
            "Authentication was cancelled"
        case .unknown:
            "An unknown error occurred"
        }
    }
}
