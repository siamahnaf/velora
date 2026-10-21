/**
 * Subtitle size (`sub-scale`), shared by the settings sheet and the subtitle
 * menu over the control bar. One range for both, and one way of writing it:
 * applied live, then persisted into mpv.conf a moment after the drag settles —
 * the same line the settings sheet writes, so the two stay in agreement.
 */
import { invoke } from '@tauri-apps/api/core';
import { command, getProperty } from 'tauri-plugin-libmpv-api';

export const SUB_SCALE = {
  min: 0.1,
  max: 2,
  step: 0.05,
  decimals: 2,
  /// mpv's own default; landing on it removes the mpv.conf line.
  default: 1,
} as const;

class SubScale {
  value = $state<number>(SUB_SCALE.default);
}

export const subScale = new SubScale();

function clamp(v: number): number {
  return Math.min(SUB_SCALE.max, Math.max(SUB_SCALE.min, v));
}

/// Read what mpv is using now — the settings sheet may have changed it.
export async function readSubScale() {
  const v = await getProperty('sub-scale', 'double').catch(() => null);
  if (typeof v === 'number' && Number.isFinite(v)) subScale.value = clamp(v);
}

const CONF_WRITE_MS = 400;
let confWrite: ReturnType<typeof setTimeout> | undefined;

export function setSubScale(v: number) {
  const snapped = Number(clamp(v).toFixed(SUB_SCALE.decimals));
  subScale.value = snapped;
  void command('set', ['sub-scale', String(snapped)]).catch(() => {});
  clearTimeout(confWrite);
  confWrite = setTimeout(() => {
    const isDefault = Math.abs(snapped - SUB_SCALE.default) < 1e-9;
    void invoke('mpv_conf_set', { key: 'sub-scale', value: isDefault ? null : String(snapped) }).catch(
      (e) => console.warn('mpv_conf_set failed:', e),
    );
  }, CONF_WRITE_MS);
}
