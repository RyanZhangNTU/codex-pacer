import { Cell, Pie, PieChart, Tooltip } from 'recharts'

import { formatTokenCount, formatUsd } from '../app/format'
import { useI18n } from '../app/useI18n'
import type { ShareDimension, ShareMode, ShareSlice } from '../app/types'
import { ResponsiveChart } from './ResponsiveChart'

interface ModelShareChartProps {
  data: ShareSlice[]
  mode: ShareMode
  dimension: ShareDimension
  title: string
  eyebrow: string
  onModeChange?: (mode: ShareMode) => void
  onDimensionChange?: (dimension: ShareDimension) => void
}

export function ModelShareChart({
  data,
  mode,
  dimension,
  title,
  eyebrow,
  onModeChange,
  onDimensionChange,
}: ModelShareChartProps) {
  const { language, t } = useI18n()
  const totalValue = data.reduce((sum, item) => sum + item.apiValueUsd, 0)
  const totalTokens = data.reduce((sum, item) => sum + item.totalTokens, 0)
  const chartData = data.map((item) => ({
    ...item,
    metric: mode === 'value' ? item.apiValueUsd : item.totalTokens,
  }))
  const hasRenderableData = chartData.some((item) => item.metric > 0)

  return (
    <div className="chart-shell chart-shell--secondary">
      <div className="chart-heading">
        <div>
          <p className="eyebrow">{eyebrow}</p>
          <h3>{title}</h3>
        </div>
        <div className="chart-controls">
          {onDimensionChange ? (
            <div className="pill-strip">
              <button
                className={dimension === 'model' ? 'active' : ''}
                onClick={() => onDimensionChange('model')}
                type="button"
              >
                {t.charts.byModel}
              </button>
              <button
                className={dimension === 'composition' ? 'active' : ''}
                onClick={() => onDimensionChange('composition')}
                type="button"
              >
                {t.charts.byStructure}
              </button>
            </div>
          ) : null}
          {onModeChange ? (
            <div className="pill-strip">
              <button
                className={mode === 'value' ? 'active' : ''}
                onClick={() => onModeChange('value')}
                type="button"
              >
                {t.charts.byValue}
              </button>
              <button
                className={mode === 'tokens' ? 'active' : ''}
                onClick={() => onModeChange('tokens')}
                type="button"
              >
                {t.charts.byTokens}
              </button>
            </div>
          ) : null}
        </div>
      </div>
      <div className="share-layout share-layout--solo">
        <div className="share-chart">
          {hasRenderableData ? (
            <ResponsiveChart className="share-chart-canvas" minHeight={320}>
              {({ width, height }) => (
                <PieChart height={height} width={width}>
                  <Tooltip
                    contentStyle={{
                      background: 'rgba(7, 13, 24, 0.96)',
                      borderRadius: '16px',
                      border: '1px solid rgba(148, 163, 184, 0.18)',
                    }}
                    formatter={(value) =>
                      mode === 'value'
                        ? formatUsd(coerceMetricValue(value), language)
                        : formatTokenCount(coerceMetricValue(value), language)
                    }
                    labelFormatter={(_, payload) => payload?.[0]?.payload?.label ?? ''}
                  />
                  <Pie
                    data={chartData}
                    dataKey="metric"
                    nameKey="label"
                    cx="50%"
                    cy="50%"
                    innerRadius={78}
                    outerRadius={116}
                    minAngle={2}
                    paddingAngle={3}
                    stroke="rgba(7, 13, 24, 0.92)"
                    strokeWidth={2}
                    isAnimationActive={false}
                  >
                    {chartData.map((entry) => (
                      <Cell key={entry.id} fill={entry.color} />
                    ))}
                  </Pie>
                </PieChart>
              )}
            </ResponsiveChart>
          ) : (
            <div className="share-empty">{t.charts.noShareData}</div>
          )}
          <div className="share-center">
            <span>{mode === 'value' ? t.charts.apiValue : t.charts.tokens}</span>
            <strong>
              {mode === 'value'
                ? formatUsd(totalValue, language)
                : formatTokenCount(totalTokens, language)}
            </strong>
          </div>
        </div>
      </div>
    </div>
  )
}

function coerceMetricValue(value: unknown) {
  return typeof value === 'number' ? value : Number(value ?? 0)
}
