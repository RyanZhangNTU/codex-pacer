interface VelocityGaugeCardProps {
  title: string
  value: string
  emoji: string
  statusText: string
  helperText: string
  percent: number
  tone: 'fast' | 'healthy' | 'slow'
  thresholds: {
    fast: number
    slow: number
  }
}

export function VelocityGaugeCard({
  title,
  value,
  emoji,
  statusText,
  helperText,
  percent,
  tone,
  thresholds,
}: VelocityGaugeCardProps) {
  const clampedPercent = Math.max(0, Math.min(1000, percent))
  const fastStop = Math.max(0, Math.min(100, (thresholds.fast / 1000) * 100))
  const slowStop = Math.max(fastStop, Math.min(100, (thresholds.slow / 1000) * 100))
  const marker = Math.max(0, Math.min(100, (clampedPercent / 1000) * 100))

  return (
    <section className={`popup-card velocity-card velocity-card--${tone}`}>
      <div className="velocity-topline">
        <p className="eyebrow">{title}</p>
        <span className={`velocity-pill velocity-pill--${tone}`}>{statusText}</span>
      </div>

      <div className="velocity-head">
        <strong className="velocity-value">
          {emoji ? <span>{emoji}</span> : null}
          {value}
        </strong>
      </div>

      <div className="velocity-gauge" role="img">
        <div className="velocity-gauge-track">
          <span className="velocity-gauge-zone velocity-gauge-zone--fast" style={{ width: `${fastStop}%` }} />
          <span
            className="velocity-gauge-zone velocity-gauge-zone--healthy"
            style={{ left: `${fastStop}%`, width: `${Math.max(0, slowStop - fastStop)}%` }}
          />
          <span
            className="velocity-gauge-zone velocity-gauge-zone--slow"
            style={{ left: `${slowStop}%`, width: `${Math.max(0, 100 - slowStop)}%` }}
          />
          <span className="velocity-gauge-marker" style={{ left: `${marker}%` }} />
        </div>
      </div>

      <p className="velocity-helper">{helperText}</p>
    </section>
  )
}
