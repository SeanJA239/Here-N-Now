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

/// Caregiver-side styling: Home-app-like warm wallpaper with light, rounded tiles.
enum Theme {
    /// Orange dark enough for text on white (4.7:1).
    static let accent = Color(hex: 0xC25100)
    static let accentFill = Color(hex: 0xFF9500)
    static let tile = Color(.secondarySystemGroupedBackground)
    static let ok = Color(hex: 0x1E7B34)
    static let warn = Color(hex: 0x9A5B00)
    static let bad = Color(hex: 0xC4281C)

    static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: 0xF6D9BC), Color(hex: 0xF3E7DA), Color(hex: 0xEFEAE4)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
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
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint))
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
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(framed ? 0.92 : 0)))
        .accessibilityElement(children: .combine)
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
