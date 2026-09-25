import SwiftUI

/// A modal drawn inside the detail window: a dimmed backdrop over the
/// window's content and a card on top of it, in the window's own view
/// hierarchy.
///
/// The detail window is a menu bar panel, and it closes the moment it stops
/// being the key window. A `.sheet`, `.alert`, or `.confirmationDialog` is a
/// window of its own: clicking a button in it takes key from the panel, and
/// the panel closes under the user as if they had clicked away. A panel modal
/// never opens a window, so the panel stays key, and open, while the user
/// answers.
///
/// While a card is up the content beneath it takes no clicks, no keyboard
/// shortcuts, and no VoiceOver focus; the card's own buttons are the only
/// ones that work. When the content is shorter than the card, the panel grows
/// to fit the card.
extension View {
    /// Shows `card` over this view while `isPresented` is true.
    func panelModal<Card: View>(isPresented: Bool, @ViewBuilder card: () -> Card) -> some View {
        modifier(PanelModalModifier(card: isPresented ? card() : nil))
    }

    /// Shows `card` for `item` over this view while `item` is not nil.
    func panelModal<Item, Card: View>(item: Item?, @ViewBuilder card: (Item) -> Card) -> some View {
        modifier(PanelModalModifier(card: item.map(card)))
    }
}

/// The card's frame: the window's background, a hairline border, and a
/// shadow, centered over the dimmed backdrop.
struct PanelModal<Card: View>: View {
    let card: Card

    static var cornerRadius: CGFloat { 10 }
    /// The least space between the card and the window's edges.
    static var margin: CGFloat { 24 }
    /// How dark the backdrop makes the content beneath the card.
    static var backdropOpacity: Double { 0.35 }

    var body: some View {
        card
            .background(Colors.windowBackground, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Colors.divider)
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Takes every click that misses the card, so nothing beneath
                // it can be reached. It does not dismiss the card: only the
                // card's own buttons answer it.
                Color.black.opacity(Self.backdropOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
    }
}

private struct PanelModalModifier<Card: View>: ViewModifier {
    let card: Card?

    func body(content: Content) -> some View {
        let presented = card != nil
        PanelModalLayout {
            content
                .disabled(presented)
                .accessibilityHidden(presented)
            if let card {
                PanelModal(card: card)
            }
        }
    }
}

/// The content, and the modal layer over all of it. Without a modal this is
/// exactly the content: same size, same proposal. With one, the stack is as
/// tall as the taller of the two, and the modal layer is proposed the
/// stack's whole size so the backdrop covers every point of the window.
private struct PanelModalLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        var size = content.sizeThatFits(proposal)
        for modal in subviews.dropFirst() {
            let fitted = modal.sizeThatFits(ProposedViewSize(width: size.width, height: nil))
            size.height = max(size.height, fitted.height)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        for modal in subviews.dropFirst() {
            modal.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// A yes-or-no question on a panel modal card. **Cancel** is the default
/// button (Return) and the cancel action (Escape), and takes the initial
/// focus, so no key pressed alone ever confirms. The confirm button has no
/// shortcut: it takes a click, or Tab to it and Space.
struct ConfirmationCard<Details: View>: View {
    let title: String
    let confirmTitle: String
    var confirmRole: ButtonRole?
    var width: CGFloat = 380
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    @ViewBuilder let details: () -> Details

    private enum Choice: Hashable {
        case cancel, confirm
    }

    @FocusState private var focus: Choice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            details()
            HStack(spacing: 8) {
                Spacer()
                Button(confirmTitle, role: confirmRole) { onConfirm() }
                    .focused($focus, equals: .confirm)
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.defaultAction)
                    .focused($focus, equals: .cancel)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: width, alignment: .leading)
        .background {
            // Escape: the cancel action, on a button nobody sees.
            Button("") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .defaultFocus($focus, .cancel)
        .onAppear { focus = .cancel }
    }
}
