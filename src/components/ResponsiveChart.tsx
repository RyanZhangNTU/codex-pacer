import { useEffect, useRef, useState, type ReactNode } from 'react'

interface ChartSize {
  width: number
  height: number
}

interface ResponsiveChartProps {
  children: (size: ChartSize) => ReactNode
  className?: string
  minHeight?: number
}

export function ResponsiveChart({
  children,
  className = 'chart-stage',
  minHeight,
}: ResponsiveChartProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const [size, setSize] = useState<ChartSize>({ width: 0, height: 0 })

  useEffect(() => {
    const node = containerRef.current
    if (!node) return

    const updateSize = () => {
      const { width, height } = node.getBoundingClientRect()
      setSize({
        width: Math.max(0, Math.floor(width)),
        height: Math.max(0, Math.floor(height)),
      })
    }

    updateSize()
    const observer = new ResizeObserver(updateSize)
    observer.observe(node)

    return () => observer.disconnect()
  }, [])

  const isReady = size.width > 0 && size.height > 0

  return (
    <div className={className} ref={containerRef} style={minHeight ? { minHeight } : undefined}>
      {isReady ? children(size) : <div aria-hidden="true" className="chart-stage-placeholder" />}
    </div>
  )
}
