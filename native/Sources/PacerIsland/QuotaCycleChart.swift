import SwiftUI
import Charts
import PacerCore

struct QuotaCycleChart: View, Equatable {
    let data: QuotaChartData
    let accent: Color
    @State private var selectedDate: Date?
    @State private var selectedExpiryID: Date?
    private let expiryColor = Color(red: 0.91, green: 0.75, blue: 0.48)
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.accent == rhs.accent
    }
    private var points: [QuotaPoint] { data.points }
    private var selected: QuotaPoint? {
        guard let selectedDate, let first = points.first, let last = points.last,
              (first.timestamp...last.timestamp).contains(selectedDate) else { return nil }
        return points.min { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }
    }
    private var expiries: [QuotaChartData.ResetExpiry] { data.expiries }

    var body: some View {
        VStack(spacing: 8) {
            chart.frame(height: 118)
            HStack {
                Text(data.startedAt, format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                Spacer()
                Text(data.resetsAt, format: .dateTime.month(.defaultDigits).day(.defaultDigits))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            .padding(.leading, 4).padding(.trailing, 34)
            .help("实线为实际剩余额度，虚线为均匀配速参考")
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前窗口剩余额度折线。\(points.count) 个显示采样点；虚线为均匀配速参考。")
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("时间", point.timestamp),
                    yStart: .value("剩余 %", 0), yEnd: .value("剩余 %", point.remaining))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.13), accent.opacity(0.015)],
                        startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
            ForEach([data.startedAt, data.resetsAt], id: \.self) { date in
                LineMark(x: .value("时间", date), y: .value("剩余 %", date == data.startedAt ? 100 : 0),
                    series: .value("曲线", "均匀配速"))
                    .foregroundStyle(Color.white.opacity(0.23))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 5]))
            }
            ForEach(points) { point in
                LineMark(x: .value("时间", point.timestamp), y: .value("剩余 %", point.remaining),
                    series: .value("曲线", "实际额度"))
                    .interpolationMethod(.linear).foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let selected {
                RuleMark(x: .value("时间", selected.timestamp))
                    .foregroundStyle(Color.white.opacity(0.24)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let highlighted = selected ?? points.last {
                PointMark(x: .value("时间", highlighted.timestamp), y: .value("剩余 %", highlighted.remaining))
                    .foregroundStyle(accent.opacity(0.16)).symbolSize(selected == nil ? 80 : 130)
                    .accessibilityHidden(true)
                PointMark(x: .value("时间", highlighted.timestamp), y: .value("剩余 %", highlighted.remaining))
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
                AxisGridLine().foregroundStyle(Color.white.opacity(0.065))
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
                let markers = plot.map { expiryMarkers(proxy: proxy, plot: $0) } ?? []
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
                            .accessibilityLabel(expiryDescription(marker))
                        }
                    }
                    if let marker = markers.first(where: { $0.id == selectedExpiryID }), let plot {
                        expiryTooltip(marker)
                            .offset(x: max(plot.minX, min(plot.maxX - 196, marker.x - 98)), y: plot.minY + 30)
                            .allowsHitTesting(false)
                    } else if let selected, let anchor = proxy.plotFrame,
                       let x = proxy.position(forX: selected.timestamp) {
                        let plot = geometry[anchor]
                        HStack(spacing: 10) {
                            Text(selected.timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("\(Int(selected.remaining.rounded()))%")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        }
                        .monospacedDigit().padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 0.5))
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

    private func expiryMarkers(proxy: ChartProxy, plot: CGRect) -> [ExpiryMarker] {
        var groups: [[QuotaChartData.ResetExpiry]] = []
        for expiry in expiries {
            if let last = groups.last, let first = last.first,
               let firstX = proxy.position(forX: first.date), let x = proxy.position(forX: expiry.date), x - firstX < 40 {
                groups[groups.count - 1].append(expiry)
            } else { groups.append([expiry]) }
        }
        func marker(_ group: [QuotaChartData.ResetExpiry]) -> ExpiryMarker? {
            guard let first = group.first, let x = proxy.position(forX: first.date) else { return nil }
            let count = group.reduce(0) { $0 + $1.count }
            let width: CGFloat = count > 1 ? 43 : 28
            return ExpiryMarker(expiries: group, dateX: plot.minX + x,
                x: min(plot.maxX - width / 2, max(plot.minX + width / 2, plot.minX + x)),
                width: width)
        }
        var result: [ExpiryMarker] = []
        for group in groups {
            guard var current = marker(group) else { continue }
            while let last = result.last, current.x - last.x < (current.width + last.width) / 2 + 6 {
                result.removeLast()
                guard let combined = marker(last.expiries + current.expiries) else { break }
                current = combined
            }
            result.append(current)
        }
        return result
    }

    private func expiryTooltip(_ marker: ExpiryMarker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(data.hasPartialExpiryDetails ? "已知 " : "")\(marker.count) 次重置即将到期")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(expiryColor)
            ForEach(marker.expiries.prefix(3)) { expiry in
                HStack(spacing: 10) {
                    Text(expiry.date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    if marker.expiries.count > 1 { Text("\(expiry.count) 次") }
                }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            if marker.expiries.count > 3 {
                Text("另有 \(marker.expiries.count - 3) 个到期时间")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 174, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(expiryColor.opacity(0.2), lineWidth: 0.5))
        .fixedSize()
    }

    private func expiryDescription(_ marker: ExpiryMarker) -> String {
        let details = marker.expiries.map { "\($0.count) 次于 \($0.date.formatted(date: .abbreviated, time: .shortened)) 到期" }
        return "\(marker.count) 次 banked reset 即将到期。" + details.joined(separator: "；")
    }
}

private struct ExpiryMarker: Identifiable {
    let expiries: [QuotaChartData.ResetExpiry]
    let dateX: CGFloat
    let x: CGFloat
    let width: CGFloat
    var id: Date { expiries[0].date }
    var count: Int { expiries.reduce(0) { $0 + $1.count } }
}
