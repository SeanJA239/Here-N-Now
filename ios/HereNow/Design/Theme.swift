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

    static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: 0x3F6B52), Color(hex: 0x2B4C3B), Color(hex: 0x1D382B)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
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
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.badgeInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.badge(for: tint)))
                .accessibilityHidden(true)
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

    /// Forest-green wallpaper; text placed directly on it renders light.
    func forestBackground() -> some View {
        background(Theme.wallpaper).environment(\.colorScheme, .dark)
    }
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
