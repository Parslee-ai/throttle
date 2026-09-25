import CoreGraphics

/// Every fixed size in the detail window, in points. Columns have one width
/// so column N lines up in every row of every section.
enum PopupMetrics {
    static let width: CGFloat = 1000
    /// Left and right inset of headers, rows, and the footer.
    static let horizontalPadding: CGFloat = 22
    /// The account name, plan, and state column.
    static let identityWidth: CGFloat = 210
    /// Where the first window column starts, from the window's left edge.
    static let columnsLeading: CGFloat = 246
    static let columnWidth: CGFloat = 224
    static let columnGap: CGFloat = 18
    /// Columns per line; more windows wrap onto another line of columns.
    static let columnsPerLine = 3
    /// Space between two wrapped lines of columns.
    static let columnLineSpacing: CGFloat = 14
    static let barHeight: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 12
    /// Space between the actions button and the window's right edge, when
    /// the row has room for it. A narrower row gives this up first.
    static let actionsTrailingPadding: CGFloat = 14
    /// The least space between the last column and the actions button.
    static let actionsMinGap: CGFloat = 4
    /// Extra space above every provider section after the first.
    static let sectionSpacing: CGFloat = 20
    /// Width reserved for the account's number before its name.
    static let indexWidth: CGFloat = 20
    /// The list scrolls once it would grow past this.
    static let maxListHeight: CGFloat = 720
    /// The horizontal inset a plain macOS `List` puts inside every row. Rows
    /// cancel it with negative insets so their content lines up with the
    /// header and footer.
    static let listCellInset: CGFloat = 8

    /// Gap between the identity column and the first window column.
    static var identityGap: CGFloat { columnsLeading - horizontalPadding - identityWidth }

    /// Where the actions button may start at the earliest, from the row's
    /// left edge: past the last column, so it never covers one.
    static var actionsLeading: CGFloat {
        columnsLeading + columnsLineWidth + actionsMinGap
    }

    /// From the leading edge of the column in `slot` (0-based within its
    /// line) to the end of the line: the room a reset message may take
    /// without reaching the actions button.
    static func lineRemainder(fromSlot slot: Int) -> CGFloat {
        let slot = min(max(slot, 0), columnsPerLine - 1)
        return columnsLineWidth - CGFloat(slot) * (columnWidth + columnGap)
    }

    /// The width of one full line of columns.
    static var columnsLineWidth: CGFloat {
        CGFloat(columnsPerLine) * columnWidth + CGFloat(columnsPerLine - 1) * columnGap
    }
}
