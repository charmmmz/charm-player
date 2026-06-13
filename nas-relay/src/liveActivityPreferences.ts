import type { SonosGroupSnapshot } from './types.js';

export interface LiveActivityPreferencesRequest {
  groupId: string;
  liveActivityStyleRaw?: string | null;
}

interface StoredLiveActivityPreferences {
  groupId: string;
  liveActivityStyleRaw: string | null;
  updatedAt: number;
}

export class LiveActivityPreferenceStore {
  private readonly preferences = new Map<string, StoredLiveActivityPreferences>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  update(request: LiveActivityPreferencesRequest): void {
    this.preferences.set(request.groupId, {
      groupId: request.groupId,
      liveActivityStyleRaw: clean(request.liveActivityStyleRaw),
      updatedAt: this.now(),
    });
  }

  apply(snapshot: SonosGroupSnapshot): SonosGroupSnapshot {
    const preference = this.preferences.get(snapshot.groupId);
    const liveActivityStyleRaw = clean(snapshot.liveActivityStyleRaw)
      ?? preference?.liveActivityStyleRaw
      ?? null;

    if ((snapshot.liveActivityStyleRaw ?? null) === liveActivityStyleRaw) {
      return snapshot;
    }

    return {
      ...snapshot,
      liveActivityStyleRaw,
    };
  }
}

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
