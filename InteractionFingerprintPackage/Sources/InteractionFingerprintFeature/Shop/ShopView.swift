import SwiftUI

/// The study stimulus: a small product catalogue a participant can browse.
///
/// Plain on purpose, but not crude. A shoddy interface changes how people behave in it,
/// so the stimulus has to read as an ordinary competent shop while carrying nothing
/// memorable enough to draw the eye for its own sake.
///
/// Every region a hypothesis refers to is marked with `areaOfInterest` and sized to at
/// least twice the measured gaze error, because two regions closer than that cannot be
/// told apart. See `09-GAZE-ACCURACY.md`.
public struct ShopView: View {
    let recorder: EventRecorder
    @State private var selected: Product?

    public init(recorder: EventRecorder, startOn product: Product? = nil) {
        self.recorder = recorder
        _selected = State(initialValue: product)
    }

    public var body: some View {
        ZStack {
            Shop.background.ignoresSafeArea()
            if let product = selected {
                ProductDetailView(product: product, recorder: recorder) {
                    recorder.wentBack(from: .productDetail, productID: product.id)
                    selected = nil
                }
                .transition(.opacity)
            } else {
                ProductListView(recorder: recorder) { product in
                    selected = product
                }
                .transition(.opacity)
            }
        }
        .tint(Shop.action)
        // Pinned so the stimulus is identical for every participant regardless of their
        // own display settings.
        .environment(\.colorScheme, .light)
    }
}

// MARK: - List

struct ProductListView: View {
    let recorder: EventRecorder
    let onSelect: (Product) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Product.catalogue) { product in
                    Button { onSelect(product) } label: {
                        row(product)
                    }
                    .buttonStyle(CardButtonStyle())
                    .accessibilityIdentifier("product_\(product.id)")
                    .areaOfInterest(.listItem, on: .productList, productID: product.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, SafeAreaProbe.bottom + 24)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            recorder.scrolled(screen: .productList, offset: offset)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .onAppear { recorder.screenAppeared(.productList) }
        .onDisappear { recorder.screenDisappeared(.productList) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // The right-hand side of this row is left clear for the recording control,
            // which floats over it during a session.
            HStack(alignment: .firstTextBaseline) {
                Text("Shop")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Shop.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, SafeAreaProbe.top + 6)
            .padding(.bottom, 12)
            Divider().overlay(Shop.hairline)
        }
        .background(Shop.background)
    }

    private func row(_ product: Product) -> some View {
        HStack(spacing: 14) {
            ProductImage(symbol: product.symbol, size: 40)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text(product.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Shop.ink)
                    .lineLimit(1)
                Text(product.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Shop.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(product.formattedPrice)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Shop.ink)
                    RatingLine(rating: product.rating, count: product.reviewCount, compact: true)
                }
            }
            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Shop.inkTertiary)
        }
        .padding(12)
        .frame(minHeight: 108)
        .background(Shop.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Shop.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Detail

struct ProductDetailView: View {
    let product: Product
    let recorder: EventRecorder
    let onBack: () -> Void

    @State private var appearedAt = SessionClock.now
    @State private var added = false

    /// Minimum height for a measurable region, in points. About 23 mm on this display,
    /// twice the measured gaze error, and therefore the smallest region two of which can
    /// reliably be told apart.
    private let regionHeight: CGFloat = 132

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                image
                block { title }
                separator
                block { price }
                separator
                block { rating }
                separator
                block { reviews }
                separator
                block { details }
                callToAction
            }
            .padding(.bottom, SafeAreaProbe.bottom + 24)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            recorder.scrolled(screen: .productDetail, offset: offset, productID: product.id)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .onAppear {
            appearedAt = SessionClock.now
            added = false
            recorder.screenAppeared(.productDetail, productID: product.id)
        }
        .onDisappear { recorder.screenDisappeared(.productDetail, productID: product.id) }
        .task(id: product.id) {
            try? await Task.sleep(for: .milliseconds(600))
            recorder.noteProductVisible(product.id, since: appearedAt)
        }
    }

    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
    }

    private var separator: some View {
        Divider().overlay(Shop.hairline).padding(.leading, 18)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text("Shop").font(.system(size: 16))
                    }
                    .foregroundStyle(Shop.action)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("back_to_shop")
                .areaOfInterest(.backButton, on: .productDetail, productID: product.id)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, SafeAreaProbe.top)
            Divider().overlay(Shop.hairline)
        }
        .background(Shop.background)
    }

    private var image: some View {
        ZStack {
            Shop.imageWell
            Image(systemName: product.symbol)
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Shop.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 208)
        .areaOfInterest(.productImage, on: .productDetail, productID: product.id)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(product.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Shop.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(product.summary)
                .font(.system(size: 15))
                .foregroundStyle(Shop.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .areaOfInterest(.title, on: .productDetail, productID: product.id)
    }

    private var price: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(product.formattedPrice)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Shop.ink)
            Text("Includes VAT · Free delivery")
                .font(.system(size: 13))
                .foregroundStyle(Shop.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .areaOfInterest(.price, on: .productDetail, productID: product.id)
    }

    private var rating: some View {
        VStack(alignment: .leading, spacing: 7) {
            RatingLine(rating: product.rating, count: product.reviewCount, compact: false)
            Text("Based on verified purchases")
                .font(.system(size: 13))
                .foregroundStyle(Shop.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .areaOfInterest(.rating, on: .productDetail, productID: product.id)
    }

    private var reviews: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reviews")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Shop.ink)
            VStack(alignment: .leading, spacing: 5) {
                Text("“Arrived quickly and does exactly what it says. The build feels solid for the money.”")
                    .font(.system(size: 14))
                    .foregroundStyle(Shop.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Verified buyer")
                    .font(.system(size: 12))
                    .foregroundStyle(Shop.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: regionHeight, alignment: .topLeading)
        .areaOfInterest(.reviews, on: .productDetail, productID: product.id)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Shop.ink)
            Text(product.details)
                .font(.system(size: 14))
                .foregroundStyle(Shop.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: regionHeight, alignment: .topLeading)
        .areaOfInterest(.description, on: .productDetail, productID: product.id)
    }

    private var callToAction: some View {
        Button {
            added = true
            recorder.productSelected(product.id, on: .productDetail)
        } label: {
            Text(added ? "Added to basket" : "Add to basket")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(added ? Shop.inkSecondary : Shop.action, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityIdentifier("add_to_basket")
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .frame(minHeight: 104, alignment: .top)
        .areaOfInterest(.cta, on: .productDetail, productID: product.id)
    }
}

// MARK: - Pieces

/// Stands in for product photography.
///
/// A flat neutral panel rather than a picture, so that no product is more visually
/// arresting than another. Photograph quality varying between items would be a variable in
/// a study about where people look.
private struct ProductImage: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Shop.imageWell)
            Image(systemName: symbol)
                .font(.system(size: size, weight: .light))
                .foregroundStyle(Shop.inkSecondary)
        }
    }
}

private struct RatingLine: View {
    let rating: Double
    let count: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            if !compact {
                Text(String(format: "%.1f", rating))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Shop.ink)
            }
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: Double(index) + 0.5 < rating ? "star.fill" : "star")
                        .font(.system(size: compact ? 10 : 13))
                        .foregroundStyle(Shop.star)
                }
            }
            .fixedSize()
            Text(compact ? "(\(count))" : "\(count) reviews")
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(Shop.inkSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A press that dims rather than scales. Motion would draw the eye to whatever was tapped.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}
