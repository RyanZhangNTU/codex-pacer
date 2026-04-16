import { Area, CartesianGrid, ComposedChart, Line, Tooltip, XAxis, YAxis } from 'recharts'

import { formatCompactDateTime, formatPercent, formatUsd } from '../app/format'
import { useI18n } from '../app/useI18n'
import type { LiveRateLimitSnapshot, OverviewBucket, QuotaTrendPoint } from '../app/types'
import { ResponsiveChart } from './ResponsiveChart'

interface QuotaTrendChartProps {
  bucket: OverviewBucket
  data: QuotaTrendPoint[]
  liveRateLimits: LiveRateLimitSnapshot | null
  windowStart: string
  windowEnd: string
  isHistorical: boolean
}

export function QuotaTrendChart({
  bucket,
  data,
  liveRateLimits,
  windowStart,
  windowEnd,
  isHistorical,
}: QuotaTrendChartProps) {
  const { language, t } = useI18n()
  const title = bucket === 'five_hour' ? t.charts.fiveHourQuotaTrend : t.charts.sevenDayQuotaTrend
  const note = isHistorical ? t.charts.historicalQuotaNote : t.charts.currentQuotaNote
  const activeWindow = bucket === 'five_hour' ? liveRateLimits?.primary : liveRateLimits?.secondary
  const cutoffTime =
    !isHistorical &&
    activeWindow &&
    sameMinute(activeWindow.windowStart, windowStart) &&
    sameMinute(activeWindow.resetsAt, windowEnd)
      ? new Date(liveRateLimits?.fetchedAt ?? '').getTime()
      : null
  const chartData = data.map((point) => {
    if (!cutoffTime) return point
    const pointTime = new Date(point.timestamp).getTime()
    if (Number.isNaN(pointTime) || pointTime <= cutoffTime) return point
    return {
      ...point,
      apiValueUsd: null,
      cumulativeApiValueUsd: null,
    }
  })

  return (
    <div className="chart-shell chart-shell--primary">
      <div className="chart-heading quota-chart-heading">
        <div>
          <p className="eyebrow">{t.charts.liveQuotaEyebrow}</p>
          <h3>{title}</h3>
        </div>
        <div className="timeline-meta quota-chart-meta">
          <span className="timeline-pill">
            {t.common.start} {formatCompactDateTime(windowStart, language)}
          </span>
          <span className="timeline-pill">
            {t.common.reset} {formatCompactDateTime(windowEnd, language)}
          </span>
          {liveRateLimits?.fetchedAt ? (
            <span className="timeline-pill">
              {t.common.updated} {formatCompactDateTime(liveRateLimits.fetchedAt, language)}
            </span>
          ) : null}
        </div>
      </div>
      <p className="chart-note">{note}</p>
      <ResponsiveChart>
        {({ width, height }) =>
          data.length === 0 ? (
            <div className="empty-state">{t.charts.noLiveQuotaHistory}</div>
          ) : (
            <ComposedChart
              data={chartData}
              height={height}
              margin={{ top: 12, right: 8, left: 0, bottom: 0 }}
              width={width}
            >
              <defs>
                <linearGradient id="quotaValueGradient" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="#f59e0b" stopOpacity={0.84} />
                  <stop offset="100%" stopColor="#f59e0b" stopOpacity={0.08} />
                </linearGradient>
              </defs>
              <CartesianGrid stroke="rgba(148, 163, 184, 0.14)" vertical={false} />
              <XAxis
                dataKey="label"
                axisLine={false}
                tickLine={false}
                minTickGap={20}
                tick={{ fill: 'rgba(157, 176, 200, 0.76)', fontSize: 12 }}
              />
              <YAxis
                yAxisId="quota"
                axisLine={false}
                tickLine={false}
                width={54}
                tickMargin={8}
                domain={[0, 100]}
                tick={{ fill: 'rgba(125, 180, 255, 0.88)', fontSize: 12 }}
                tickFormatter={(value) => formatPercent(Number(value) / 100, language)}
              />
              <YAxis
                yAxisId="value"
                orientation="right"
                axisLine={false}
                tickLine={false}
                width={68}
                tickMargin={10}
                tick={{ fill: 'rgba(245, 197, 112, 0.86)', fontSize: 12 }}
                tickFormatter={(value) => formatUsd(Number(value), language)}
              />
              <Tooltip
                contentStyle={{
                  background: 'rgba(7, 13, 24, 0.96)',
                  borderRadius: '16px',
                  border: '1px solid rgba(148, 163, 184, 0.18)',
                  boxShadow: '0 22px 45px rgba(2, 8, 23, 0.32)',
                }}
                labelStyle={{ color: '#f8fbff' }}
                formatter={(value, name) => {
                  const numericValue = typeof value === 'number' ? value : Number(value ?? 0)
                  if (name === 'remainingPercent') {
                    return [formatPercent(numericValue / 100, language), t.charts.remaining]
                  }
                  if (name === 'cumulativeApiValueUsd') {
                    return [formatUsd(numericValue, language), t.charts.cumulativeValue]
                  }
                  if (name === 'apiValueUsd') {
                    return [formatUsd(numericValue, language), t.charts.windowValue]
                  }
                  return [numericValue, name]
                }}
              />
              <Area
                yAxisId="value"
                type="monotone"
                dataKey="cumulativeApiValueUsd"
                stroke="#f6ad25"
                strokeWidth={2.25}
                fill="url(#quotaValueGradient)"
              />
              <Line
                yAxisId="quota"
                type="monotone"
                dataKey="remainingPercent"
                stroke="#60a5fa"
                strokeWidth={3}
                dot={false}
                activeDot={{ r: 4, fill: '#dceaff' }}
              />
            </ComposedChart>
          )
        }
      </ResponsiveChart>
    </div>
  )
}

function sameMinute(left: string | null | undefined, right: string | null | undefined) {
  if (!left || !right) return false
  const leftDate = new Date(left)
  const rightDate = new Date(right)
  if (Number.isNaN(leftDate.getTime()) || Number.isNaN(rightDate.getTime())) return false
  return Math.floor(leftDate.getTime() / 60000) === Math.floor(rightDate.getTime() / 60000)
}
