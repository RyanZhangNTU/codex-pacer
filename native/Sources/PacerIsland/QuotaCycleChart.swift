import SwiftUI
import Charts
import PacerCore

struct QuotaCycleChart: View, Equatable {
    let data: QuotaChartData
    let accent: Color
    var referenceColor: Color = PacerPalette.tick
    @State private var selectedDate: Date?
    @State private var selectedExpiryID: Date?
    @StateObject private var presentationCache = QuotaCyclePresentationCache()
    @Environment(\.colorScheme) private var colorScheme
    /// Reset markers in a theme amber: lighter on dark windows, deeper on light ones.
    private var expiryColor: Color {
        colorScheme == .light ? Color(red: 176 / 255, green: 118 / 255, blue: 24 / 255) : Color(red: 232 / 255, green: 191 / 255, blue: 122 / 255)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.accent == rhs.accent && lhs.referenceColor == rhs.referenceColor
    }
    private var points: [QuotaPoint] { data.points }
    private var selected: QuotaPoint? {
        guard let selectedDate, let first = points.first, let last = points.last,
              (first.timestamp...last.timestamp).contains(selectedDate) else { return nil }
        return points.min { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }
    }
    private var presentation: QuotaCycleChartPresentation { presentationCache.value(for: data) }

    var body: some View {
        VStack(spacing: 8) {
            chart.frame(height: 118)
            HStack {
                Text(presentation.startText)
                Spacer()
                Text(presentation.endText)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            .padding(.leading, 4).padding(.trailing, 34)
            .help(presentation.lineHelp)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value(L10n.text("chart.time"), point.timestamp),
                    yStart: .value(L10n.text("chart.remaining_axis"), 0), yEnd: .value(L10n.text("chart.remaining_axis"), point.remaining))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.13), accent.opacity(0.015)],
                        startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
            ForEach([data.startedAt, data.resetsAt], id: \.self) { date in
                LineMark(x: .value(L10n.text("chart.time"), date), y: .value(L10n.text("chart.remaining_axis"), date == data.startedAt ? 100 : 0),
                    series: .value(L10n.text("chart.series"), L10n.text("chart.pace_reference")))
                    .foregroundStyle(referenceColor.opacity(0.23))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 5]))
            }
            ForEach(points) { point in
                LineMark(x: .value(L10n.text("chart.time"), point.timestamp), y: .value(L10n.text("chart.remaining_axis"), point.remaining),
                    series: .value(L10n.text("chart.series"), L10n.text("chart.actual_quota")))
                    .interpolationMethod(.linear).foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let selected {
                RuleMark(x: .value(L10n.text("chart.time"), selected.timestamp))
                    .foregroundStyle(referenceColor.opacity(0.24)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let highlighted = selected ?? points.last {
                PointMark(x: .value(L10n.text("chart.time"), highlighted.timestamp), y: .value(L10n.text("chart.remaining_axis"), highlighted.remaining))
                    .foregroundStyle(accent.opacity(0.16)).symbolSize(selected == nil ? 80 : 130)
                    .accessibilityHidden(true)
                PointMark(x: .value(L10n.text("chart.time"), highlighted.timestamp), y: .value(L10n.text("chart.remaining_axis"), highlighted.remaining))
                    .foregroundStyle(accent).symbolSize(selected == nil ? 18 : 30)
                    .accessibilityHidden(true)
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...100, range: .plotDimension(padding: 5))
        .chartXScale(domain: data.startedAt...data.resetsAt, range: .plotDimension(padding: 4))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(referenceColor.opacity(0.065))
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text("\(number)%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] }
                let markers = plot.map { expiryMarkers(plot: $0) } ?? []
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear)
                    if let plot {
                        ForEach(markers) { marker in
                            Path { path in
                                path.move(to: CGPoint(x: marker.x, y: plot.minY + 27))
                                path.addLine(to: CGPoint(x: marker.dateX, y: plot.minY + 34))
                                path.addLine(to: CGPoint(x: marker.dateX, y: plot.maxY))
                            }
                            .stroke(expiryColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            .allowsHitTesting(false).accessibilityHidden(true)
                            Button {
                                selectedExpiryID = marker.id
                                selectedDate = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock").font(.system(size: 12, weight: .medium))
                                    if marker.count > 1 { Text("\(marker.count)").font(.system(size: 11, weight: .medium)).monospacedDigit() }
                                }
                                .foregroundStyle(expiryColor)
                                .frame(width: marker.width, height: 23)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().stroke(expiryColor.opacity(0.3), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .position(x: marker.x, y: plot.minY + 13)
                            .accessibilityLabel(marker.reading.accessibilityLabel)
                        }
                    }
                    if let marker = markers.first(where: { $0.id == selectedExpiryID }), let plot {
                        expiryTooltip(marker)
                            .offset(x: max(plot.minX, min(plot.maxX - 196, marker.x - 98)), y: plot.minY + 30)
                            .allowsHitTesting(false)
                    } else if let selected, let reading = presentation.points.first(where: { $0.timestamp == selected.timestamp.timeIntervalSince1970 }),
                       let anchor = proxy.plotFrame,
                       let x = proxy.position(forX: selected.timestamp) {
                        let plot = geometry[anchor]
                        HStack(spacing: 10) {
                            Text(reading.dateText)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(reading.valueText)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        }
                        .monospacedDigit().padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(referenceColor.opacity(0.1), lineWidth: 0.5))
                        .fixedSize()
                        .position(x: max(88, min(plot.maxX - 88, plot.minX + x)), y: plot.minY + 14)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        updateSelection(at: location, proxy: proxy, plot: plot, markers: markers)
                    case .ended:
                        selectedDate = nil; selectedExpiryID = nil
                    }
                }
                .highPriorityGesture(SpatialTapGesture().onEnded { value in
                    updateSelection(at: value.location, proxy: proxy, plot: plot, markers: markers)
                })
            }
        }
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, plot: CGRect?, markers: [ExpiryMarker]) {
        guard let plot else { selectedDate = nil; selectedExpiryID = nil; return }
        selectedExpiryID = markers.first {
            abs(location.x - $0.x) <= $0.width / 2 + 4 && (plot.minY...plot.minY + 30).contains(location.y)
        }?.id
        selectedDate = selectedExpiryID == nil && plot.contains(location)
            ? proxy.value(atX: location.x - plot.minX) : nil
    }

    private func expiryMarkers(plot: CGRect) -> [ExpiryMarker] {
        presentation.markers(plotWidth: Double(plot.width)).map { ExpiryMarker(reading: $0, originX: plot.minX) }
    }

    private func expiryTooltip(_ marker: ExpiryMarker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(marker.reading.title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(expiryColor)
            ForEach(marker.reading.details, id: \.timestamp) { expiry in
                HStack(spacing: 10) {
                    Text(expiry.dateText)
                    if marker.reading.details.count > 1 { Text(expiry.countText) }
                }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let more = marker.reading.moreText {
                Text(more)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 174, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(expiryColor.opacity(0.2), lineWidth: 0.5))
        .fixedSize()
    }

}

private struct ExpiryMarker: Identifiable {
    let reading: QuotaCycleChartPresentation.Marker
    let originX: CGFloat
    var dateX: CGFloat { originX + CGFloat(reading.dateX) }
    var x: CGFloat { originX + CGFloat(reading.x) }
    var width: CGFloat { CGFloat(reading.width) }
    var id: Date { Date(timeIntervalSince1970: reading.id) }
    var count: Int { reading.count }
}

/// Hover changes selection, so it can reuse the cycle's formatted readings.
private final class QuotaCyclePresentationCache: ObservableObject {
    private var cached: (data: QuotaChartData, language: AppLanguage, presentation: QuotaCycleChartPresentation)?
    func value(for data: QuotaChartData) -> QuotaCycleChartPresentation {
        if let cached, cached.data == data, cached.language == L10n.language { return cached.presentation }
        let value = QuotaCycleChartPresentation(data: data)
        cached = (data, L10n.language, value)
        return value
    }
}
