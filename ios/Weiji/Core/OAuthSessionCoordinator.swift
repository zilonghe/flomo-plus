import AuthenticationServices
import UIKit

@MainActor
final class OAuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var window: ASPresentationAnchor?

    func authenticate(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        guard session == nil,
              let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow else {
            throw WeijiAPIError.interrupted
        }
        window = anchor
        defer { session = nil; window = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "weiji") { callback, error in
                    if let callback { continuation.resume(returning: callback) }
                    else if let failure = error as? ASWebAuthenticationSessionError, failure.code == .canceledLogin {
                        continuation.resume(throwing: CancellationError())
                    } else { continuation.resume(throwing: error ?? WeijiAPIError.interrupted) }
                }
                auth.presentationContextProvider = self
                auth.prefersEphemeralWebBrowserSession = true
                session = auth
                if !auth.start() { continuation.resume(throwing: WeijiAPIError.interrupted) }
            }
        } onCancel: {
            Task { @MainActor in self.session?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? ASPresentationAnchor()
    }
}
