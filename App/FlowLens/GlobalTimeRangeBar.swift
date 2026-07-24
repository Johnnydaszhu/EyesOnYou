import SwiftUI

/// Global time-range filter for Overview / Apps / History (and any period-scoped data).
struct GlobalTimeRangeBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Label(l10n.t("time.global"), systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textSecondary)

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
                    .foregroundStyle(FlowLensTheme.accentBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if model.overviewPeriod == .custom {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text(l10n.t("overview.period.from"))
                            .font(.system(size: 11))
                            .foregroundStyle(FlowLensTheme.textSecondary)
                        DatePicker(
                            "",
                            selection: $model.customRangeStart,
                            in: ...model.customRangeEnd,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                        .colorScheme(.dark)
                    }
                    HStack(spacing: 6) {
                        Text(l10n.t("overview.period.to"))
                            .font(.system(size: 11))
                            .foregroundStyle(FlowLensTheme.textSecondary)
                        DatePicker(
                            "",
                            selection: $model.customRangeEnd,
                            in: model.customRangeStart...,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                        .colorScheme(.dark)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            LiquidGlassBackground(style: .card, cornerRadius: 14)
        }
        .id(l10n.revision)
    }

    private func chip(_ period: AppModel.OverviewPeriod) -> some View {
        let selected = model.overviewPeriod == period
        return Button {
            model.overviewPeriod = period
        } label: {
            Text(l10n.overviewPeriodTitle(period))
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black.opacity(0.88) : FlowLensTheme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule()
                            .fill(FlowLensTheme.accentBlue.opacity(0.92))
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.7)
                            )
                            .shadow(color: FlowLensTheme.accentBlue.opacity(0.35), radius: 6, y: 2)
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(Capsule().fill(Color.white.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
