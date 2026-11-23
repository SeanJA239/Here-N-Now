import HereNowCore
import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Caregiver-side styling: Home-app-like forest-green wallpaper with white, rounded tiles and soft badges.
enum Theme {
    /// Forest green dark enough for text on white (6.3:1); also the tint for toggles and buttons.
    static let accent = Color(hex: 0x2E6B4F)
    static let ok = Color(hex: 0x1E7B34)
    static let warn = Color(hex: 0x8A5A00)
    static let bad = Color(hex: 0xC4281C)
    /// Low-saturation badge fills behind dark glyphs.
    static let badgeYellow = Color(hex: 0xF1E4B5)
    static let badgeBlue = Color(hex: 0xD4E4EF)
    static let badgeRose = Color(hex: 0xF0D6D1)
    static let badgeNeutral = Color(hex: 0xE5E9E3)
    static let badgeInk = Color(hex: 0x24402F)
    static let tileFill = Color.white.opacity(0.94)
    static let forest = Color(hex: 0x3F6B52)
    /// Page color the forest gradient fades into.
    static let pageBase = Color(hex: 0xF3F4EF)

    /// Forest green at the top, fading to transparent toward the bottom of the screen.
    static func forestFade(solidUntil: CGFloat = 0.3, clearAt: CGFloat = 0.75) -> LinearGradient {
        LinearGradient(stops: [.init(color: forest, location: 0), .init(color: forest, location: solidUntil),
                               .init(color: forest.opacity(0), location: clearAt)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Full-screen backdrop for centered screens (PIN, pairing).
    static var wallpaper: some View {
        ZStack { pageBase; forestFade() }.ignoresSafeArea()
    }

    /// Status colors map to soft badges: fine → blue, attention → yellow, problem → rose.
    static func badge(for tint: Color) -> Color {
        if tint == ok { return badgeBlue }
        if tint == warn { return badgeYellow }
        if tint == bad { return badgeRose }
        return badgeNeutral
    }

    static func patientFont(_ size: Double, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Small Home-style tile: icon in a colored circle, a title, and a value.
struct StatusTile: View {
    var icon: String
    var tint: Color
    var title: String
    var value: String
    var detail: String?
    var framed = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GlassBadge(systemName: icon, tint: Theme.badge(for: tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(framed ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(framed ? Theme.tileFill : .clear))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// White rounded tile that keeps dark text even on the dark-green wallpaper.
    func tile(cornerRadius: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.tileFill))
            .environment(\.colorScheme, .light)
    }

    /// Scrolling page whose top band is forest green and fades out, so it moves with the header text on it.
    /// Text placed in the first `solid` points should be light; everything below it sits on the light page.
    func forestPage(solid: CGFloat = 200, fade: CGFloat = 260) -> some View {
        background(alignment: .top) {
            Theme.forestFade(solidUntil: (solid + 600) / (solid + fade + 600), clearAt: 1)
                .frame(height: solid + fade + 600)
                .offset(y: -600)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .light)
    }

    /// iOS 26 Liquid Glass when available; a thin material elsewhere.
    @ViewBuilder
    func glassCircle(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint.opacity(0.25)), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Soft yellow or blue icon with a Liquid Glass rim; the color fades to clear toward the bottom.
struct GlassBadge: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Theme.badgeInk)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.55), tint.opacity(0)],
                                                       startPoint: .top, endPoint: .bottom)))
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [.white, tint.opacity(0.9), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                    lineWidth: size > 40 ? 2 : 1.5)
            )
            .glassCircle(tint: tint)
            .accessibilityHidden(true)
    }
}

/// Home-app accessory tile: glass icon on the left, name and state on the right. Dimmed when `active` is false.
struct HomeTile: View {
    var icon: String
    var tint: Color
    var title: String
    var value: String
    var active = true

    var body: some View {
        HStack(spacing: 10) {
            GlassBadge(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(value).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(active ? 0.94 : 0.62)))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }
}

/// Section title in the Home app style.
struct HomeSectionTitle: View {
    var text: String
    var body: some View { Text(text).font(.title3.weight(.semibold)).padding(.top, 6) }
}

enum HomeGrid {
    static let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
}

enum TextFit {
    /// Measures the sentence with the patient screen's font and width; at most two lines, never truncated.
    static func lineCount(_ text: String, scale: TextScale, width: Double) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        let base = UIFont.systemFont(ofSize: scale.cardPointSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: scale.cardPointSize) } ?? base
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width * 0.96, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(1, Int((rect.height / font.lineHeight).rounded(.up)))
    }

    static func fits(_ text: String, scale: TextScale, width: Double) -> Bool {
        lineCount(text, scale: scale, width: width) <= 2
    }
}

enum ImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL, key: String) -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

extension Date {
    var relativeChinese: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    func formatted(in zone: TimeZone, _ format: String = "M月d日 HH:mm") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: self)
    }
}

extension Double {
    /// Server timestamps are milliseconds since 1970.
    var serverDate: Date { Date(timeIntervalSince1970: self / 1000) }
}
