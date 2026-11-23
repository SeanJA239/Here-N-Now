import HereNowCore
import SwiftUI

/// The patient's whole screen: one time cue, one card, one fixed button. No menus, scrolling, or navigation.
struct PatientMomentView: View {
    var moment: Moment
    var isPlaying: Bool
    var photo: (String) -> UIImage?
    var onToggle: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let palette = PatientPalette.of(moment.palette)
            let scale = moment.textScale
            let cardWidth = PatientLayout.cardWidth(for: proxy.size)
            ZStack {
                ZStack {
                    Color(hex: palette.base)
                    LinearGradient(stops: [.init(color: Color(hex: palette.backgroundTop), location: 0),
                                           .init(color: Color(hex: palette.backgroundBottom), location: PatientPalette.solidUntil),
                                           .init(color: Color(hex: palette.backgroundBottom, opacity: 0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
                // Time and card form one centered block; the card keeps the same height with or without a photo,
                // so the button never moves when content changes.
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    timeArea(palette: palette, scale: scale)
                    if let card = moment.card {
                        cardView(card, palette: palette, scale: scale, width: cardWidth)
                            .padding(.top, 64)
                    }
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PatientLayout.outerMargin)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func timeArea(palette: PatientPalette, scale: TextScale) -> some View {
        let big = moment.card == nil ? scale.segmentPointSize * 1.25 : scale.segmentPointSize
        return VStack(spacing: 8) {
            Text(moment.segmentName)
                .font(Theme.patientFont(big, weight: .bold))
                .foregroundStyle(Color(hex: palette.timeText))
            if let date = moment.dateLine {
                Text(date)
                    .font(Theme.patientFont(scale.datePointSize, weight: .medium))
                    .foregroundStyle(Color(hex: palette.secondaryTimeText))
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("现在是\(moment.segmentName)\(moment.dateLine.map { "，\($0)" } ?? "")")
        .accessibilitySortPriority(3)
        .accessibilityIdentifier("patient.time")
    }

    private func cardView(_ card: Card, palette: PatientPalette, scale: TextScale, width: CGFloat) -> some View {
        let side = PatientLayout.photoSide(cardWidth: width, scale: scale)
        let image = card.photoAssetID.flatMap(photo)
        return VStack(spacing: 32) {
            HStack(alignment: .center, spacing: PatientLayout.photoSpacing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                Text(card.line)
                    .font(Theme.patientFont(scale.cardPointSize))
                    .foregroundStyle(Color(hex: palette.cardText))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: side, alignment: .leading)
                    .accessibilitySortPriority(2)
                    .accessibilityIdentifier("patient.card")
            }
            soundButton(palette: palette, scale: scale)
        }
        .padding(PatientLayout.cardPadding)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(hex: palette.card))
                .shadow(color: .black.opacity(moment.isNight ? 0 : 0.14), radius: 24, y: 10)
        )
    }

    @ViewBuilder
    private func soundButton(palette: PatientPalette, scale: TextScale) -> some View {
        let height = max(96, scale.buttonPointSize * 2.4)
        if moment.audio != nil {
            Button(action: onToggle) {
                HStack(spacing: 18) {
                    Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.system(size: scale.buttonPointSize * 0.9, weight: .bold))
                    Text(isPlaying ? "停止" : "听一听")
                        .font(Theme.patientFont(scale.buttonPointSize, weight: .bold))
                }
                .foregroundStyle(Color(hex: isPlaying ? palette.stopText : palette.playText))
                .frame(maxWidth: .infinity, minHeight: height)
                .background(
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(Color(hex: isPlaying ? palette.stopFill : palette.playFill))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "停止" : "听一听")
            .accessibilityHint(isPlaying ? "停止播放" : "播放这句话")
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("patient.sound")
        } else {
            // Keeps the card the same size so nothing moves when sound becomes available later.
            Color.clear.frame(maxWidth: .infinity, minHeight: height).accessibilityHidden(true)
        }
    }
}

/// Patient mode on the display device, with a hidden long-press entry for the caregiver.
struct PatientScreen: View {
    @Bindable var engine: DisplayEngine
    var onCaregiverEntry: () -> Void

    var body: some View {
        GeometryReader { proxy in
            PatientMomentView(
                moment: engine.moment,
                isPlaying: engine.playback.isPlaying,
                photo: { sha in ImageCache.image(at: engine.assetURL(sha), key: sha) },
                onToggle: engine.toggleSound
            )
            .overlay(alignment: .topTrailing) {
                CaregiverEntryButton(dark: true, action: onCaregiverEntry)
                    .padding(12)
            }
            .onAppear { engine.updateLayout(size: proxy.size) }
            .onChange(of: proxy.size) { _, size in engine.updateLayout(size: size) }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// A faint corner control that only responds to a 2-second press, so a patient's taps never open settings.
struct CaregiverEntryButton: View {
    var dark: Bool
    var action: () -> Void

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.25))
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 2, perform: action)
            .accessibilityLabel("照护者设置")
            .accessibilityHint("照护者长按两秒进入")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier("patient.caregiverEntry")
    }
}
