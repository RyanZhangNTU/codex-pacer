import { formatUsd } from '../app/format'
import type { MenuBarPopupQuotaSnapshot, MenuBarPopupSuggestedSpeed, QuotaTrendPoint } from '../app/types'
import { useI18n } from '../app/useI18n'

interface PopupSevenDayUsageChartProps {
  ariaLabel: string
  data: QuotaTrendPoint[]
  fetchedAt: string | null
  quota: MenuBarPopupQuotaSnapshot | null
  speed: MenuBarPopupSuggestedSpeed | null
}

interface ValuePoint {
  time: number
  value: number
}

interface PlotPoint extends ValuePoint {
  x: number
  y: number
}

const CHART_WIDTH = 360
const CHART_HEIGHT = 132
const PADDING_X = 12
const PADDING_TOP = 12
const PADDING_BOTTOM = 14
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000

export function PopupSevenDayUsageChart({ ariaLabel, data, fetchedAt, quota, speed }: PopupSevenDayUsageChartProps) {
  const { language } = useI18n()
  const dataTimes = data
    .map((point) => toTimestamp(point.timestamp))
    .filter((value): value is number => value !== null)
  const fallbackCurrent =
    toTimestamp(fetchedAt) ?? dataTimes[dataTimes.length - 1] ?? toTimestamp(quota?.resetsAt ?? null) ?? SEVEN_DAYS_MS
  const fallbackStart = dataTimes.length > 0 ? Math.min(...dataTimes) : fallbackCurrent - SEVEN_DAYS_MS
  const windowStart = toTimestamp(quota?.windowStart ?? null) ?? fallbackStart
  const windowEnd = toTimestamp(quota?.resetsAt ?? null) ?? Math.max(windowStart + SEVEN_DAYS_MS, ...dataTimes, windowStart)
  const safeWindowEnd = windowEnd > windowStart ? windowEnd : windowStart + SEVEN_DAYS_MS
  const currentTime = clamp(fallbackCurrent, windowStart, safeWindowEnd)

  const valuePoints = buildValuePoints(data, quota, currentTime, windowStart, safeWindowEnd)
  const plotPoints = valuePoints.map((point) => toPlotPoint(point, windowStart, safeWindowEnd))
  const actualPath = buildSmoothPath(plotPoints)
  const areaPath = buildAreaPath(plotPoints)
  const referenceStart = toPlotPoint({ time: windowStart, value: 100 }, windowStart, safeWindowEnd)
  const referenceEnd = toPlotPoint({ time: safeWindowEnd, value: 0 }, windowStart, safeWindowEnd)
  const currentPoint = plotPoints.find((point) => point.time === currentTime) ?? plotPoints[plotPoints.length - 1] ?? null
  const apiValueUsd = getSevenDayApiValue(data, windowStart, currentTime)
  const dayLines = Array.from({ length: 8 }, (_, index) => {
    const x = PADDING_X + ((CHART_WIDTH - PADDING_X * 2) * index) / 7
    return <line className="popup-seven-day-grid-line popup-seven-day-grid-line--vertical" key={index} x1={x} x2={x} y1={PADDING_TOP} y2={chartBottom()} />
  })
  const horizontalLines = [25, 50, 75].map((value) => {
    const y = toY(value)
    return <line className="popup-seven-day-grid-line" key={value} x1={PADDING_X} x2={CHART_WIDTH - PADDING_X} y1={y} y2={y} />
  })

  return (
    <section aria-label={ariaLabel} className="popup-seven-day-chart">
      {speed ? (
        <div className={`popup-seven-day-speed-badge popup-seven-day-speed-badge--${speed.status}`}>
          {speed.emoji ? (
            <span aria-hidden="true" className="popup-seven-day-speed-emoji">
              {speed.emoji}
            </span>
          ) : null}
          <strong>{speed.displayValue}</strong>
        </div>
      ) : null}
      <div className="popup-seven-day-value-badge">
        <span aria-hidden="true" className="popup-seven-day-badge-emoji">
          💵
        </span>
        <strong>{formatUsd(apiValueUsd, language)}</strong>
      </div>
      <svg aria-hidden="true" className="popup-seven-day-svg" focusable="false" viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}>
        <defs>
          <linearGradient id="popupSevenDayUsageFill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="#76c5ff" stopOpacity="0.24" />
            <stop offset="100%" stopColor="#76c5ff" stopOpacity="0" />
          </linearGradient>
          <filter id="popupSevenDayCurrentGlow" x="-80%" y="-80%" width="260%" height="260%">
            <feGaussianBlur stdDeviation="4" result="blur" />
            <feColorMatrix
              in="blur"
              result="glow"
              type="matrix"
              values="0 0 0 0 0.462 0 0 0 0 0.773 0 0 0 0 1 0 0 0 0.7 0"
            />
            <feMerge>
              <feMergeNode in="glow" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        <rect className="popup-seven-day-plot" height={CHART_HEIGHT} rx="16" width={CHART_WIDTH} x="0" y="0" />
        {dayLines}
        {horizontalLines}
        <line
          className="popup-seven-day-reference"
          x1={referenceStart.x}
          x2={referenceEnd.x}
          y1={referenceStart.y}
          y2={referenceEnd.y}
        />
        {areaPath ? <path className="popup-seven-day-area" d={areaPath} /> : null}
        {actualPath ? <path className="popup-seven-day-line" d={actualPath} /> : null}
        {currentPoint ? (
          <g className="popup-seven-day-current" filter="url(#popupSevenDayCurrentGlow)">
            <circle className="popup-seven-day-current-halo" cx={currentPoint.x} cy={currentPoint.y} r="9" />
            <circle className="popup-seven-day-current-dot" cx={currentPoint.x} cy={currentPoint.y} r="4.5" />
          </g>
        ) : null}
      </svg>
    </section>
  )
}

function buildValuePoints(
  data: QuotaTrendPoint[],
  quota: MenuBarPopupQuotaSnapshot | null,
  currentTime: number,
  windowStart: number,
  windowEnd: number,
) {
  const byMinute = new Map<number, ValuePoint>()

  for (const point of data) {
    const time = toTimestamp(point.timestamp)
    if (time === null || time < windowStart || time > windowEnd || point.remainingPercent === null) continue
    byMinute.set(roundToMinute(time), { time: roundToMinute(time), value: clamp(point.remainingPercent, 0, 100) })
  }

  if (quota) {
    byMinute.set(roundToMinute(currentTime), {
      time: roundToMinute(currentTime),
      value: clamp(quota.remainingPercent, 0, 100),
    })
  }

  const points = [...byMinute.values()].sort((left, right) => left.time - right.time)
  if (points.length > 0 && points[0].time > windowStart) {
    points.unshift({ time: windowStart, value: 100 })
  }

  return points
}

function getSevenDayApiValue(data: QuotaTrendPoint[], windowStart: number, currentTime: number) {
  const values = data
    .map((point) => ({
      time: toTimestamp(point.timestamp),
      value: point.cumulativeApiValueUsd,
    }))
    .filter((point): point is { time: number; value: number } => {
      return point.time !== null && point.time >= windowStart && point.time <= currentTime && Number.isFinite(point.value)
    })
    .sort((left, right) => left.time - right.time)

  return values[values.length - 1]?.value ?? 0
}

function buildSmoothPath(points: PlotPoint[]) {
  if (points.length === 0) return ''
  if (points.length === 1) return `M ${points[0].x} ${points[0].y}`

  return points.slice(1).reduce((path, point, index) => {
    const previous = points[index]
    const midpointX = (previous.x + point.x) / 2
    return `${path} C ${midpointX} ${previous.y}, ${midpointX} ${point.y}, ${point.x} ${point.y}`
  }, `M ${points[0].x} ${points[0].y}`)
}

function buildAreaPath(points: PlotPoint[]) {
  const linePath = buildSmoothPath(points)
  if (!linePath || points.length < 2) return ''

  const first = points[0]
  const last = points[points.length - 1]
  const bottom = chartBottom()
  return `${linePath} L ${last.x} ${bottom} L ${first.x} ${bottom} Z`
}

function toPlotPoint(point: ValuePoint, windowStart: number, windowEnd: number): PlotPoint {
  const plotWidth = CHART_WIDTH - PADDING_X * 2
  const x = PADDING_X + ((point.time - windowStart) / (windowEnd - windowStart)) * plotWidth
  return {
    ...point,
    x: clamp(x, PADDING_X, CHART_WIDTH - PADDING_X),
    y: toY(point.value),
  }
}

function toY(value: number) {
  const plotHeight = CHART_HEIGHT - PADDING_TOP - PADDING_BOTTOM
  return PADDING_TOP + ((100 - clamp(value, 0, 100)) / 100) * plotHeight
}

function chartBottom() {
  return CHART_HEIGHT - PADDING_BOTTOM
}

function toTimestamp(value: string | null | undefined) {
  if (!value) return null
  const timestamp = new Date(value).getTime()
  return Number.isFinite(timestamp) ? timestamp : null
}

function roundToMinute(value: number) {
  return Math.round(value / 60000) * 60000
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value))
}
