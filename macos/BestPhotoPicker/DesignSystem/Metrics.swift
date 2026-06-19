import CoreGraphics

enum Metrics {
    enum Radius {
        static let window: CGFloat = 13
        static let card: CGFloat = 11
        static let cardLarge: CGFloat = 12
        static let cardSmall: CGFloat = 10
        static let button: CGFloat = 9
        static let buttonSmall: CGFloat = 8
        static let thumbnail: CGFloat = 9
        static let thumbnailDense: CGFloat = 7
        static let chip: CGFloat = 7
        static let badge: CGFloat = 6
        static let pill: CGFloat = 99
    }

    enum Window {
        static let maxWidth: CGFloat = 1340
        static let maxHeight: CGFloat = 884
        static let widthFraction: CGFloat = 0.97
        static let heightFraction: CGFloat = 0.93
        static let borderWidth: CGFloat = 1
    }

    enum Chrome {
        static let titleBarHeight: CGFloat = 28
        static let footerHeight: CGFloat = 34
        static let titleBarPadding: CGFloat = 16
        static let footerPadding: CGFloat = 14
        static let iconButtonWidth: CGFloat = 28
        static let iconButtonHeight: CGFloat = 24
        static let trafficLightSize: CGFloat = 12
    }

    enum Spacing {
        static let xs: CGFloat = 7
        static let sm: CGFloat = 9
        static let md: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 26
        static let screenPadding: CGFloat = 36
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let dashed: CGFloat = 1.5
    }

    enum Content {
        static let importMaxWidth: CGFloat = 760
    }
}
