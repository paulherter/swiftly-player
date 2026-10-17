import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// A measured, cropped logo, ready to draw.
struct TitleLogo: @unchecked Sendable {
    let image: CGImage
    let measurement: LogoMeasurement
    var dark: Bool { TitleMarksMetric.isDark(luminance: measurement.luminance) }
}

/// Fetches logos, trims the transparent border, measures (off the main path)
/// and caches the result per URL.
@MainActor
final class TitleLogoCache {
    static let shared = TitleLogoCache()
    private var known: [URL: TitleLogo] = [:]
    /// URLs without a usable logo, so not every appearance fetches again.
    private var empty: Set<URL> = []
    private var ongoing: [URL: Task<TitleLogo?, Never>] = [:]

    func available(_ url: URL) -> TitleLogo? { known[url] }

    func load(_ url: URL) async -> TitleLogo? {
        if let present = known[url] { return present }
        if empty.contains(url) { return nil }
        if let run = ongoing[url] { return await run.value }
        let run = Task<TitleLogo?, Never> {
            guard let (data, answer) = try? await URLSession.shared.data(for: .withOwnHeaders(url)),
                  (answer as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.gauge(data) }.value
        }
        ongoing[url] = run
        let result = await run.value
        ongoing[url] = nil
        if let result { known[url] = result } else { empty.insert(url) }
        return result
    }

    /// Decode (800 px at most), read premultiplied RGBA, measure,
    /// crop to the opaque box.
    nonisolated private static func gauge(_ data: Data) -> TitleLogo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        let b = raw.width, h = raw.height
        var buffer = [UInt8](repeating: 0, count: b * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { rohbytes -> Bool in
            guard let ctx = CGContext(data: rohbytes.baseAddress, width: b, height: h,
                                      bitsPerComponent: 8, bytesPerRow: b * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(raw, in: CGRect(x: 0, y: 0, width: b, height: h))
            return true
        }
        guard drawn,
              let m = TitleMarksMetric.measure(rgba: buffer, width: b, height: h),
              let toward = raw.cropping(to: CGRect(x: m.x, y: m.y, width: m.width, height: m.height))
        else { return nil }
        return TitleLogo(image: toward, measurement: m)
    }
}

/// A detail page title: the text - or, if "Title as logo" is on
/// (iPhone and iPad: Profile -> Appearance; Mac and TV likewise) and the
/// server has one, the logo.
///
/// The logo is cropped to the text edge and sized to the same visual weight
/// (`TitleMarksMetric`); mostly dark logos are shown as a light silhouette.
/// Until cropping and measuring are done the text stays in place; if the fetch
/// fails, it stays. Off: plain text, no fetch.
///
/// The scale is the platform's title line (`row`: 28 on phone, tablet and
/// Mac, 56 on TV). Where the title sits in a block with fixed positions (Mac,
/// TV), the logo stays within that height - nothing below it moves.
struct TitleMark: View {
    /// How much room the title has.
    enum Space {
        /// Free-standing on the page: at most 70% of the screen width.
        case page
        /// In a column (wide header): at most 70% of its width,
        /// the text wraps to two lines.
        case column
        /// A title slot of fixed height: one line of text, the logo never taller.
        case compartment(height: CGFloat)
    }

    let title: String
    let logo: URL?
    let slot: Space

    @AppStorage("titelAlsLogo") private var asLogo = false
    @ScaledMetric private var row: CGFloat
    @State private var mark: TitleLogo?
    @State private var width: CGFloat = 0

    init(title: String, logo: URL?, row: CGFloat = 28, slot: Space = .page) {
        self.title = title
        self.logo = logo
        self.slot = slot
        _row = ScaledMetric(wrappedValue: row, relativeTo: .title)
    }

    var body: some View {
        if !asLogo || logo == nil {
            text
        } else {
            frameRect
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
                .task(id: logo) {
                    guard let logo else { return }
                    if let present = TitleLogoCache.shared.available(logo) { mark = present; return }
                    mark = nil
                    let loaded = await TitleLogoCache.shared.load(logo)
                    withAnimation(Theme.reveal) { mark = loaded }
                }
        }
    }

    @ViewBuilder
    private var frameRect: some View {
        let content = ZStack(alignment: .leading) {
            text.opacity(ready == nil ? 1 : 0)
            if let ready {
                drawing(ready.0, ready.1)
                    .transition(.opacity)
            }
        }
        switch slot {
        case .page:
            content
                .frame(minHeight: row * 2, alignment: .bottomLeading)
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in width * 0.7 }
        case .column:
            content
                .frame(minHeight: row * 2, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .compartment(let height):
            content
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        }
    }

    /// The size is only fixed once measurement and width are available.
    private var ready: (TitleLogo, CGSize)? {
        guard let mark, width > 0 else { return nil }
        var max: Double?
        var maxWidth = Double(width)
        switch slot {
        case .page: break
        case .column: maxWidth *= 0.7
        case .compartment(let height): max = Double(height)
        }
        let g = TitleMarksMetric.size(pagesRatio: mark.measurement.pagesRatio,
                                        density: mark.measurement.density,
                                        row: Double(row), maxWidth: maxWidth,
                                        maxHeight: max)
        return (mark, CGSize(width: g.width, height: g.height))
    }

    @ViewBuilder
    private func drawing(_ mark: TitleLogo, _ size: CGSize) -> some View {
        let image = Image(decorative: mark.image, scale: 1).resizable()
        Group {
            if mark.dark {
                image.renderingMode(.template).foregroundStyle(Theme.font)
            } else {
                image
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var text: some View {
        let t = Text(title)
            .font(Theme.titleLarge)
            .tracking(Theme.lockTitle)
            .foregroundStyle(Theme.font)
        switch slot {
        case .page: t
        case .column: t.lineLimit(2)
        case .compartment(let height):
            t.lineLimit(1)
                // A long title shrinks instead of pushing the page.
                .minimumScaleFactor(0.62)
                .frame(height: height, alignment: .leading)
        }
    }
}
