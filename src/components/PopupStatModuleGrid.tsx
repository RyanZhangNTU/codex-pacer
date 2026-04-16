interface PopupStatModule {
  id: string
  label: string
  value: string
  note?: string | null
}

interface PopupStatModuleGridProps {
  modules: PopupStatModule[]
}

export function PopupStatModuleGrid({ modules }: PopupStatModuleGridProps) {
  if (modules.length === 0) return null

  return (
    <section className="popup-module-grid">
      {modules.map((module) => (
        <article className="popup-card popup-stat-card" key={module.id}>
          <span>{module.label}</span>
          <strong>{module.value}</strong>
          {module.note ? <small>{module.note}</small> : null}
        </article>
      ))}
    </section>
  )
}
