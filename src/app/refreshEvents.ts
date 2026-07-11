import type { RefreshCompletedEvent } from './types.ts'

export type SurfaceRevisionDecision = 'reload' | 'defer' | 'ignore'

export class SurfaceRevisionGate {
  private appliedRevision = 0
  private pendingRevision = 0

  accept(event: RefreshCompletedEvent, visible: boolean): SurfaceRevisionDecision {
    if (
      !event.succeeded ||
      event.refreshRevision <= Math.max(this.appliedRevision, this.pendingRevision)
    ) {
      return 'ignore'
    }
    if (!visible) {
      this.pendingRevision = event.refreshRevision
      return 'defer'
    }
    this.appliedRevision = event.refreshRevision
    return 'reload'
  }

  onVisible(): 'reload' | 'ignore' {
    if (this.pendingRevision <= this.appliedRevision) {
      return 'ignore'
    }
    this.appliedRevision = this.pendingRevision
    return 'reload'
  }
}

export interface RefreshSurfaceState<T> {
  data: T | null
  loading: boolean
  refreshing: boolean
  error: string | null
}

export function settleRefreshFailure<T>(
  state: RefreshSurfaceState<T>,
  error: unknown,
): RefreshSurfaceState<T> {
  return {
    ...state,
    loading: false,
    refreshing: false,
    error: state.data === null ? String(error) : null,
  }
}
