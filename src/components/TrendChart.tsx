import { Area, AreaChart, CartesianGrid, Line, Tooltip, XAxis, YAxis } from 'recharts'

import { formatTokenCount, formatUsd } from '../app/format'
import { useI18n } from '../app/useI18n'
import type { TrendPoint } from '../app/types'
import { ResponsiveChart } from './ResponsiveChart'

interface TrendChartProps {
  data: TrendPoint[]
}

export function TrendChart({ data }: TrendChartProps) {
  const { language, t } = useI18n()

  return (
    <div className="chart-shell chart-shell--primary">
      <div className="chart-heading">
        <div>
          <p className="eyebrow">{t.charts.trendEyebrow}</p>
          <h3>{t.charts.valueAndTokens}</h3>
        </div>
        <p className="chart-note">{t.charts.valueVsTokens}</p>
      </div>
      <ResponsiveChart>
        {({ width, height }) => (
          <AreaChart data={data} height={height} margin={{ top: 12, right: 8, left: 0, bottom: 0 }} width={width}>
            <defs>
              <linearGradient id="valueGradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#f59e0b" stopOpacity={0.9} />
                <stop offset="100%" stopColor="#f59e0b" stopOpacity={0.08} />
              </linearGradient>
            </defs>
            <CartesianGrid stroke="rgba(148, 163, 184, 0.14)" vertical={false} />
            <XAxis
              dataKey="label"
              axisLine={false}
              tickLine={false}
              minTickGap={24}
              tick={{ fill: 'rgba(157, 176, 200, 0.76)', fontSize: 12 }}
            />
            <YAxis
              yAxisId="value"
              axisLine={false}
              tickLine={false}
              width={60}
              tickMargin={8}
              tick={{ fill: 'rgba(245, 197, 112, 0.86)', fontSize: 12 }}
              tickFormatter={(value) => formatUsd(Number(value), language)}
            />
            <YAxis
              yAxisId="tokens"
              orientation="right"
              axisLine={false}
              tickLine={false}
              width={68}
              tickMargin={10}
              tick={{ fill: 'rgba(125, 180, 255, 0.86)', fontSize: 12 }}
              tickFormatter={(value) => formatTokenCount(Number(value), language)}
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
                const metricValue = typeof value === 'number' ? value : Number(value ?? 0)
                return [
                  name === 'apiValueUsd'
                    ? formatUsd(metricValue, language)
                    : formatTokenCount(metricValue, language),
                  name === 'apiValueUsd' ? t.charts.apiValue : t.charts.tokens,
                ]
              }}
            />
            <Area
              yAxisId="value"
              type="monotone"
              dataKey="apiValueUsd"
              stroke="#f6ad25"
              strokeWidth={2.5}
              fill="url(#valueGradient)"
            />
            <Line
              yAxisId="tokens"
              type="monotone"
              dataKey="totalTokens"
              stroke="#60a5fa"
              strokeWidth={3}
              dot={false}
              activeDot={{ r: 4, fill: '#dceaff' }}
            />
          </AreaChart>
        )}
      </ResponsiveChart>
    </div>
  )
}
