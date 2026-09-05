import Foundation

/// A fictional product.
///
/// Invented rather than scraped from a real shop, so that brand recognition cannot become
/// a confound and no participant arrives with a prior opinion about the item.
public struct Product: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let priceGBP: Double
    public let rating: Double
    public let reviewCount: Int
    public let summary: String
    public let details: String
    /// Two SF Symbols, used instead of photography so that image quality cannot vary
    /// between products in a way that draws the eye.
    public let symbol: String

    public static let catalogue: [Product] = [
        Product(
            id: "sku_101", name: "Aurel M2 Headphones", priceGBP: 189,
            rating: 4.4, reviewCount: 218,
            summary: "Over-ear, active noise cancelling, 30 hour battery",
            details: "Two microphones per cup handle noise cancelling. Folds flat. Charges over USB-C, reaching half capacity in twenty minutes. Weighs 254 grams.",
            symbol: "headphones"
        ),
        Product(
            id: "sku_102", name: "Corven Field Speaker", priceGBP: 129,
            rating: 4.1, reviewCount: 96,
            summary: "Portable, water resistant, 14 hour battery",
            details: "Rated IP67, so rain and dust are not a problem. Pairs two units for stereo. A strap loop is moulded into the case. Weighs 610 grams.",
            symbol: "hifispeaker"
        ),
        Product(
            id: "sku_103", name: "Lumen Desk Lamp", priceGBP: 74,
            rating: 4.7, reviewCount: 431,
            summary: "Adjustable colour temperature, weighted base",
            details: "Ranges from 2700K to 6000K with a continuous dial. The arm holds position without drifting. Draws 9 watts at full brightness.",
            symbol: "lamp.desk"
        ),
        Product(
            id: "sku_104", name: "Palis Travel Kettle", priceGBP: 46,
            rating: 3.8, reviewCount: 57,
            summary: "0.5 litre, dual voltage, folding handle",
            details: "Switches between 120V and 240V. Boils half a litre in four minutes. The handle folds flat against the body for packing.",
            symbol: "mug"
        ),
        Product(
            id: "sku_105", name: "Orten Mechanical Keyboard", priceGBP: 152,
            rating: 4.5, reviewCount: 302,
            summary: "65 percent layout, hot swappable, wired",
            details: "Switches lift out without soldering. The case is machined aluminium. A detachable braided cable exits on the left.",
            symbol: "keyboard"
        ),
        Product(
            id: "sku_106", name: "Halden Camera Bag", priceGBP: 98,
            rating: 4.0, reviewCount: 143,
            summary: "Waxed canvas, padded dividers, 12 litre",
            details: "Three dividers reconfigure the main compartment. The flap closes with magnetic catches. A rain cover stows in the base pocket.",
            symbol: "bag"
        ),
    ]

    public init(
        id: String, name: String, priceGBP: Double, rating: Double,
        reviewCount: Int, summary: String, details: String, symbol: String
    ) {
        self.id = id
        self.name = name
        self.priceGBP = priceGBP
        self.rating = rating
        self.reviewCount = reviewCount
        self.summary = summary
        self.details = details
        self.symbol = symbol
    }

    public var formattedPrice: String { String(format: "£%.0f", priceGBP) }
}
