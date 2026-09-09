//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct LocalUserAuthenticationAction {

    let action: (LocalUserAccessPolicy, String?, Bool, String?) async throws -> EvaluatedLocalUserAccessPolicy

    // tvOS extras (both ignored on iOS, whose alert validates in the view model):
    //   • `requireConfirmation` — when true (creating a PIN), the entry must be re-entered to confirm before
    //     it's accepted; a mismatch shows "PINs don't match" and restarts.
    //   • `expectedPin` — when non-nil (verifying an existing PIN: login / Change-PIN old / Turn-Off), the
    //     entry must match it or the modal shows an inline "Incorrect PIN" and stays open. Nil = no check.
    func callAsFunction(
        policy: LocalUserAccessPolicy,
        reason: String?,
        requireConfirmation: Bool = false,
        expectedPin: String? = nil
    ) async throws -> EvaluatedLocalUserAccessPolicy {
        try await action(policy, reason, requireConfirmation, expectedPin)
    }
}

extension EnvironmentValues {

    @Entry
    var localUserAuthenticationAction: LocalUserAuthenticationAction? = nil
}

struct WithUserAuthentication<Content: View>: View {

    @State
    private var reason: String? = nil

    #if os(tvOS)
    // tvOS drives the PIN prompt off a per-prompt IDENTITY (a fresh box each time) rather than a shared bool,
    // so a second prompt in the same flow (the old→new Change PIN sequence) re-presents reliably instead of
    // being coalesced away. See `ProwloguePinEntryView`.
    @State
    private var pinPrompt: PinPromptBox? = nil
    #else
    @State
    private var isPresentingLocalPin: Bool = false
    @State
    private var pin: String = ""
    @State
    private var pinContinuation: CheckedContinuation<String, Error>? = nil
    #endif

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private func handlePinAuthentication(requireConfirmation: Bool, expectedPin: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            #if os(tvOS)
            pinPrompt = PinPromptBox(
                reason: reason,
                requireConfirmation: requireConfirmation,
                expectedPin: expectedPin,
                continuation: continuation
            )
            #else
            pinContinuation = continuation
            isPresentingLocalPin = true
            #endif
        }
    }

    private func handleAuthentication(
        policy: LocalUserAccessPolicy,
        reason: String?,
        requireConfirmation: Bool,
        expectedPin: String?
    ) async throws -> EvaluatedLocalUserAccessPolicy {
        self.reason = reason

        switch policy {
        case .none:
            return EmptyEvaluatedUserAccessPolicy()
        case .requireDeviceAuthentication:
            #if os(iOS)
            _ = try await AppPermission.deviceAuthentication.request(reason: reason)
            return EmptyEvaluatedUserAccessPolicy()
            #else
            throw ErrorMessage(L10n.deviceAuthFailed)
            #endif
        case .requirePin:
            let pin = try await handlePinAuthentication(requireConfirmation: requireConfirmation, expectedPin: expectedPin)
            return PinEvaluatedUserAccessPolicy(pin: pin, pinHint: nil)
        }
    }

    #if os(tvOS)
    private func submitPin(_ box: PinPromptBox, _ pin: String) {
        let id = box.id
        box.resume(returning: pin)
        // Keep the cover up if the resumed flow immediately queued the NEXT prompt (old→new Change PIN); only
        // close when nothing replaced this box. The resumed continuation runs before this MainActor task, so by
        // the time we check, `pinPrompt` is already the next box (different id) or still this resolved one.
        Task { @MainActor in
            if pinPrompt?.id == id { pinPrompt = nil }
        }
    }

    private func cancelPin(_ box: PinPromptBox) {
        box.cancel()
        pinPrompt = nil
    }
    #endif

    var body: some View {
        content
            .environment(
                \.localUserAuthenticationAction,
                .init(action: handleAuthentication)
            )
        #if os(tvOS)
            // Themed, native full-screen PIN entry (Apple's tvOS overlay pattern) in place of the un-themeable
            // system alert. ONE persistent cover whose CONTENT swaps by `box.id`: a second prompt in the same
            // flow (the old→new Change PIN sequence) just replaces the content — the cover never dismisses and
            // re-presents, which was unreliable (the new prompt sometimes never appeared, so the PIN never
            // updated). `.id(box.id)` resets the inner entry's state per prompt.
            .fullScreenCover(
                    isPresented: Binding(
                        get: { pinPrompt != nil },
                        // Fires only on an EXTERNAL dismissal (e.g. Menu): cancel the pending prompt.
                        set: { presented in
                            if !presented, let box = pinPrompt {
                                box.cancel()
                                pinPrompt = nil
                            }
                        }
                    )
                ) {
                    if let box = pinPrompt {
                        ProwloguePinEntryView(
                            reason: box.reason,
                            requireConfirmation: box.requireConfirmation,
                            expectedPin: box.expectedPin,
                            onSubmit: { pin in submitPin(box, pin) },
                            onCancel: { cancelPin(box) }
                        )
                        .id(box.id)
                    }
                }
        #else
                .alert(
                L10n.pin,
                isPresented: $isPresentingLocalPin,
                presenting: pinContinuation
            ) { continuation in

                TextField(L10n.pin, text: $pin)
                    .keyboardType(.numberPad)

                // bug in SwiftUI: having .disabled will dismiss
                // alert but not call the closure (for length)
                Button(L10n.done) {
                    continuation.resume(returning: pin)
                }
                .disabled((4 ... 30 ~= pin.count) == false)

                Button(L10n.cancel, role: .cancel) {
                    continuation.resume(throwing: CancellationError())
                }
                .tint(.red)
            } message: { _ in
                if let reason {
                    Text(reason)
                }
            }
            .backport
            .onChange(of: isPresentingLocalPin) { _, newValue in
                guard !newValue else { return }
                pinContinuation = nil
                pin = ""
            }
        #endif
    }
}

#if os(tvOS)

// Reference-typed, identifiable holder for a single PIN prompt. Being a reference type lets `resume`/`cancel`
// be idempotent (the continuation is nil-ed after the first call), so the presenter's `onDisappear` safety-net
// can freely call `cancel()` without risking a double-resume crash; a fresh `id` per prompt gives the
// `fullScreenCover(item:)` a new identity so sequential prompts re-present cleanly.
private final class PinPromptBox: Identifiable {

    let id = UUID()
    let reason: String?
    let requireConfirmation: Bool
    let expectedPin: String?

    private var continuation: CheckedContinuation<String, Error>?

    init(reason: String?, requireConfirmation: Bool, expectedPin: String?, continuation: CheckedContinuation<String, Error>) {
        self.reason = reason
        self.requireConfirmation = requireConfirmation
        self.expectedPin = expectedPin
        self.continuation = continuation
    }

    func resume(returning pin: String) {
        continuation?.resume(returning: pin)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

#endif
