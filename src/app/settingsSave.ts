interface CodexHomeSettings {
  codexHome: string | null
}

interface SaveSettingsOptions<TSyncSettings extends CodexHomeSettings, TSubscriptionProfile> {
  previousSyncSettings: TSyncSettings
  nextSyncSettings: TSyncSettings
  previousSubscriptionProfile: TSubscriptionProfile
  nextSubscriptionProfile: TSubscriptionProfile
  updateSyncSettings: (settings: TSyncSettings) => Promise<TSyncSettings>
  updateSubscriptionProfile: (profile: TSubscriptionProfile) => Promise<TSubscriptionProfile>
  scanCodexHome: (codexHome: string | null) => Promise<unknown>
}

interface SavedSettings<TSyncSettings, TSubscriptionProfile> {
  syncSettings: TSyncSettings
  subscriptionProfile: TSubscriptionProfile
  codexHomeChanged: boolean
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function closeSettingsPanelIfIdle(saving: boolean, onClose: () => void): boolean {
  if (saving) return false
  onClose()
  return true
}

export async function saveSettingsWithCodexHomeRollback<
  TSyncSettings extends CodexHomeSettings,
  TSubscriptionProfile,
>({
  previousSyncSettings,
  nextSyncSettings,
  previousSubscriptionProfile,
  nextSubscriptionProfile,
  updateSyncSettings,
  updateSubscriptionProfile,
  scanCodexHome,
}: SaveSettingsOptions<TSyncSettings, TSubscriptionProfile>): Promise<
  SavedSettings<TSyncSettings, TSubscriptionProfile>
> {
  let savedSyncSettings: TSyncSettings | null = null
  let savedSubscriptionProfile: TSubscriptionProfile | null = null

  try {
    savedSyncSettings = await updateSyncSettings(nextSyncSettings)
    savedSubscriptionProfile = await updateSubscriptionProfile(nextSubscriptionProfile)
    const codexHomeChanged = previousSyncSettings.codexHome !== savedSyncSettings.codexHome
    if (codexHomeChanged) {
      await scanCodexHome(savedSyncSettings.codexHome)
    }

    return {
      syncSettings: savedSyncSettings,
      subscriptionProfile: savedSubscriptionProfile,
      codexHomeChanged,
    }
  } catch (error) {
    const rollbackErrors: string[] = []
    let syncSettingsRestored = savedSyncSettings === null
    if (savedSyncSettings) {
      try {
        await updateSyncSettings(previousSyncSettings)
        syncSettingsRestored = true
      } catch (rollbackError) {
        rollbackErrors.push(errorMessage(rollbackError))
      }
    }
    if (savedSubscriptionProfile) {
      try {
        await updateSubscriptionProfile(previousSubscriptionProfile)
      } catch (rollbackError) {
        rollbackErrors.push(errorMessage(rollbackError))
      }
    }
    if (
      savedSyncSettings &&
      syncSettingsRestored &&
      previousSyncSettings.codexHome !== savedSyncSettings.codexHome
    ) {
      try {
        await scanCodexHome(previousSyncSettings.codexHome)
      } catch (rollbackError) {
        rollbackErrors.push(errorMessage(rollbackError))
      }
    }

    if (rollbackErrors.length > 0) {
      throw new Error(
        `${errorMessage(error)} Previous settings could not be fully restored: ${rollbackErrors.join('; ')}`,
      )
    }
    throw error
  }
}
