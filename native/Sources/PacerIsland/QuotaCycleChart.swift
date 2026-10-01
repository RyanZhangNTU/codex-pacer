import SwiftUI
import Charts
import PacerCore

struct QuotaCycleChart: View {
    let cycle: QuotaCycle
    let accent: Color
    @State private var selectedDate: Date?
    private var points: [QuotaPoint] { cycle.displayPoints() }
    private var selected: QuotaPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(cycle.bucketName.map { $0 + " · 7 天曲线" } ?? "当前 7 天额度曲线").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text((selected ?? points.last).map { "\(formatted($0.timestamp)) · \(Int($0.remaining.rounded()))%" } ?? "等待采样")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("时间", point.timestamp), y: .value("剩余 %", point.remaining),
                        series: .value("曲线", "实际额度"))
                        .interpolationMethod(.linear).foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let last = points.last {
                    PointMark(x: .value("时间", last.timestamp), y: .value("剩余 %", last.remaining))
                        .foregroundStyle(accent).symbolSize(16)
                }
                ForEach([cycle.startedAt, cycle.resetsAt], id: \.self) { date in
                    LineMark(x: .value("时间", date), y: .value("剩余 %", date == cycle.startedAt ? 100 : 0),
                        series: .value("曲线", "均匀配速"))
                        .foregroundStyle(Color.white.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let selected {
                    RuleMark(x: .value("时间", selected.timestamp)).foregroundStyle(Color.white.opacity(0.2))
                    PointMark(x: .value("时间", selected.timestamp), y: .value("剩余 %", selected.remaining))
                        .foregroundStyle(accent).symbolSize(24)
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartXScale(domain: cycle.startedAt...cycle.resetsAt)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
            } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
            } }
            .chartXSelection(value: $selectedDate)
            .frame(height: 108)
            .accessibilityLabel("当前窗口剩余额度折线。\(points.count) 个显示采样点；虚线为均匀配速参考。")
            HStack(spacing: 12) {
                Label("实际采样", systemImage: "circle.fill").foregroundStyle(accent)
                Text("虚线：均匀配速").foregroundStyle(.secondary)
                Spacer()
            }.font(.system(size: 9))
            Text("\(formatted(cycle.startedAt)) 至 \(formatted(cycle.resetsAt))，重置后重新记录。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }
}
