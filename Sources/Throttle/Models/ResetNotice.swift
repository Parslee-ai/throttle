import Foundation

/// The one-line message a row shows after the user spends, or tries to spend,
/// a banked reset. Built by the app from a provider-neutral result, already
/// redacted and capped, so a view can draw `text` as-is. Lives in memory only;
/// it is never written to disk.
struct ResetNotice: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// The reset went through. Fades on its own after a few seconds.
        case success
        /// Anything else. Stays until closed or replaced by the next use.
        case failure
    }

    let id: UUID
    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}
