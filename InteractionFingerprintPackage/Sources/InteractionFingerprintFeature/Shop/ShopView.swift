import SwiftUI

/// The study stimulus: a small product catalogue a participant can browse.
///
/// Deliberately plain. A distinctive interface would itself become a variable, and the
/// experiment is about what people look at, not about whether they liked the design. Every
/// region a hypothesis refers to is marked with `areaOfInterest` and sized generously,
/// because gaze lands within roughly 11 mm and two regions closer than about 23 mm cannot
/// be told apart. See `09-GAZE-ACCURACY.md`.
public struct ShopView: View {
    let recorder: EventRecorder
    @State private var selected: Product?

    public init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    public var body: some View {
        Group {
            if let product = selected {
                ProductDetailView(product: product, recorder: recorder) {
                    recorder.wentBack(from: .productDetail, productID: product.id)
                    selected = nil
                }
            } else {
                ProductListView(recorder: recorder) { product in
                    selected = product
                }
            }
        }
        .background(Color(white: 0.98))
    }
}

struct ProductListView: View {
    let recorder: EventRecorder
    let onSelect: (Product) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Product.catalogue) { product in
                    Button { onSelect(product) } label: {
                        row(product)
                    }
                    .buttonStyle(.plain)
                    .areaOfInterest(.listItem, on: .productList, productID: product.id)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            recorder.scrolled(screen: .productList, offset: offset)
        }
        .safeAreaInset(edge: .top) { header }
        .onAppear { recorder.screenAppeared(.productList) }
        .onDisappear { recorder.screenDisappeared(.productList) }
    }

    private var header: some View {
        Text("Shop")
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
    }

    private func row(_ product: Product) -> some View {
        HStack(spacing: 14) {
            Image(systemName: product.symbol)
                .font(.system(size: 30))
                .frame(width: 78, height: 78)
                .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text(product.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(product.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(product.formattedPrice).font(.callout.weight(.semibold))
                    Text(String(format: "%.1f ★ (%d)", product.rating, product.reviewCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minHeight: 102)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ProductDetailView: View {
    let product: Product
    let recorder: EventRecorder
    let onBack: () -> Void

    @State private var appearedAt = SessionClock.now

    /// Minimum height for a measurable region, in points. Roughly 23 mm on this display,
    /// which is twice the gaze error, and therefore the smallest region two of which can
    /// be reliably told apart.
    private let regionHeight: CGFloat = 140

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                image
                title
                price
                rating
                reviews
                description
                callToAction
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            recorder.scrolled(screen: .productDetail, offset: offset, productID: product.id)
        }
        .safeAreaInset(edge: .top) { header }
        .onAppear {
            appearedAt = SessionClock.now
            recorder.screenAppeared(.productDetail, productID: product.id)
        }
        .onDisappear { recorder.screenDisappeared(.productDetail, productID: product.id) }
        .task(id: product.id) {
            try? await Task.sleep(for: .milliseconds(600))
            recorder.noteProductVisible(product.id, since: appearedAt)
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .font(.callout)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
            }
            .areaOfInterest(.backButton, on: .productDetail, productID: product.id)
            Spacer()
        }
        .padding(.horizontal, 6)
        .background(.regularMaterial)
    }

    private var image: some View {
        Image(systemName: product.symbol)
            .font(.system(size: 64))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 16))
            .areaOfInterest(.productImage, on: .productDetail, productID: product.id)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(product.name).font(.title3.weight(.semibold))
            Text(product.summary).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .areaOfInterest(.title, on: .productDetail, productID: product.id)
    }

    private var price: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(product.formattedPrice).font(.system(size: 34, weight: .semibold))
            Text("Includes VAT. Free delivery.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .areaOfInterest(.price, on: .productDetail, productID: product.id)
    }

    private var rating: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.1f", product.rating)).font(.title3.weight(.semibold))
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: Double(index) < product.rating ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .areaOfInterest(.rating, on: .productDetail, productID: product.id)
    }

    private var reviews: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(product.reviewCount) reviews").font(.callout.weight(.medium))
            Text("\"Arrived quickly and does exactly what it says. The build feels solid for the money.\"")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Verified buyer").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: regionHeight, alignment: .topLeading)
        .areaOfInterest(.reviews, on: .productDetail, productID: product.id)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.callout.weight(.medium))
            Text(product.details).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: regionHeight, alignment: .topLeading)
        .areaOfInterest(.description, on: .productDetail, productID: product.id)
    }

    private var callToAction: some View {
        Button {
            recorder.productSelected(product.id, on: .productDetail)
        } label: {
            Text("Add to basket")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 96)
        .areaOfInterest(.cta, on: .productDetail, productID: product.id)
    }
}
