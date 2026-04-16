interface PopupActionRowProps {
  openDashboardLabel: string
  refreshLabel: string
  settingsLabel: string
  onOpenDashboard: () => void
  onRefresh: () => void
  onOpenSettings: () => void
  disabled?: boolean
}

export function PopupActionRow({
  openDashboardLabel,
  refreshLabel,
  settingsLabel,
  onOpenDashboard,
  onRefresh,
  onOpenSettings,
  disabled = false,
}: PopupActionRowProps) {
  return (
    <div className="popup-action-row">
      <button className="ghost-button" disabled={disabled} onClick={onOpenDashboard} type="button">
        {openDashboardLabel}
      </button>
      <button className="ghost-button" disabled={disabled} onClick={onRefresh} type="button">
        {refreshLabel}
      </button>
      <button className="accent-button" disabled={disabled} onClick={onOpenSettings} type="button">
        {settingsLabel}
      </button>
    </div>
  )
}
