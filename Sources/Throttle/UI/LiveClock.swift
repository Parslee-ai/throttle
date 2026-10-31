import SwiftUI

/// Hands its content the wall clock at the moment it renders, and re-renders
/// on a fixed interval so phrases advance while the window sits open.
///
/// The timeline's own `context.date` is the date of the schedule entry that
/// last fired, which can be minutes old after a data-driven re-render or
/// after ticks paused while the window was hidden. It only drives the
/// refresh; the content reads `Date()` each time it is evaluated.
struct LiveClock<Content: View>: View {
    let from: Date
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content

    init(from: Date = .now, every interval: TimeInterval = 30,
         @ViewBuilder content: @escaping (Date) -> Content) {
        self.from = from
        self.interval = interval
        self.content = content
    }

    var body: some View {
        TimelineView(.periodic(from: from, by: interval)) { _ in
            content(Date())
        }
    }
}
