import CoreGraphics

/// Every fixed size in the detail window, in points. Columns have one width
/// so column N lines up in every row of every section.
enum PopupMetrics {
    static let width: CGFloat = 1000
    /// Left and right inset of headers, rows, and the footer.
    static let horizontalPadding: CGFloat = 22
    /// The account name, plan, and state column.
    static let identityWidth: CGFloat = 200
    /// Where the first window column starts, from the window's left edge.
    static let columnsLeading: CGFloat = 240
    static let columnWidth: CGFloat = 224
    static let columnGap: CGFloat = 18
    /// Columns per line; more windows wrap onto another line of columns.
    static let columnsPerLine = 3
    /// Space between two wrapped lines of columns.
    static let columnLineSpacing: CGFloat = 14
    static let barHeight: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 12
    /// Space between the actions button and the window's right edge.
    static let actionsTrailingPadding: CGFloat = 14
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

    /// The width of one full line of columns.
    static var columnsLineWidth: CGFloat {
        CGFloat(columnsPerLine) * columnWidth + CGFloat(columnsPerLine - 1) * columnGap
    }
}
