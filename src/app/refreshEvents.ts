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

export function shouldLoadDashboardAfterManualRefresh(listenerReady: boolean): boolean {
  return !listenerReady
}

export function shouldLoadDashboardAfterSettingsSave(
  codexHomeChanged: boolean,
  listenerReady: boolean,
): boolean {
  return !codexHomeChanged || !listenerReady
}

export type SurfaceRequestKind = 'passive' | 'manual'

export interface SurfaceRequestClaim {
  readonly id: number
  readonly kind: SurfaceRequestKind
}

export class SurfaceRequestController {
  private latestRequestId = 0
  private manualRequestId: number | null = null

  get manualInFlight(): boolean {
    return this.manualRequestId !== null
  }

  claim(kind: SurfaceRequestKind): SurfaceRequestClaim | null {
    if (kind === 'manual' && this.manualRequestId !== null) {
      return null
    }
    const claim = { id: this.latestRequestId + 1, kind }
    this.latestRequestId = claim.id
    if (kind === 'manual') {
      this.manualRequestId = claim.id
    }
    return claim
  }

  isLatest(claim: SurfaceRequestClaim): boolean {
    return claim.id === this.latestRequestId
  }

  finish(claim: SurfaceRequestClaim): void {
    if (claim.kind === 'manual' && claim.id === this.manualRequestId) {
      this.manualRequestId = null
    }
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
