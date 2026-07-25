import SwiftUI

/// Global time-range filter — pill chips matching design refs (selected = brand green).
struct GlobalTimeRangeBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Label(l10n.t("time.global"), systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AppModel.OverviewPeriod.presets) { period in
                            chip(period)
                        }
                    }
                }

                Spacer(minLength: 8)

                Text(l10n.overviewRangeCaption(start: model.periodRangeStart, end: model.periodRangeEnd))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(EyesOnYouTheme.brandGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if model.overviewPeriod == .custom {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text(l10n.t("overview.period.from"))
                            .font(.system(size: 11))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                        DatePicker(
                            "",
                            selection: $model.customRangeStart,
                            in: ...model.customRangeEnd,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Text(l10n.t("overview.period.to"))
                            .font(.system(size: 11))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                        DatePicker(
                            "",
                            selection: $model.customRangeEnd,
                            in: model.customRangeStart...,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            LiquidGlassBackground(style: .card, cornerRadius: 16)
        }
        .id(l10n.revision)
    }

    private func chip(_ period: AppModel.OverviewPeriod) -> some View {
        let selected = model.overviewPeriod == period
        let isLight = colorScheme == .light
        return Button {
            model.overviewPeriod = period
        } label: {
            Text(l10n.overviewPeriodTitle(period))
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(
                    selected
                        ? (isLight ? Color.white : Color.black.opacity(0.88))
                        : EyesOnYouTheme.textSecondary
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule()
                            .fill(EyesOnYouTheme.brandGreen)
                            .shadow(
                                color: EyesOnYouTheme.brandGreen.opacity(isLight ? 0.25 : 0.4),
                                radius: 6,
                                y: 2
                            )
                    } else {
                        Capsule()
                            .fill(isLight ? Color.white.opacity(0.7) : Color.white.opacity(0.05))
                            .overlay(
                                Capsule().strokeBorder(
                                    EyesOnYouTheme.cardBorder.opacity(isLight ? 0.7 : 1),
                                    lineWidth: 0.7
                                )
                            )
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
