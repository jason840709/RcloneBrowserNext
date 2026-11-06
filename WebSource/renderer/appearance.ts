import type {InterfaceScale, Theme, ThemeAccent, ThemeMode} from '../shared/types';

export const INTERFACE_SCALES: readonly InterfaceScale[] = [80, 90, 100, 110, 125];

/** 100% is actual size: one CSS pixel per point (macOS) or per device-independent pixel (Windows, Linux). */
export const interfaceScaleZoom = (scale: InterfaceScale): number => scale / 100;

export function interfaceScaleChoices(current: InterfaceScale): readonly InterfaceScale[] {
  return INTERFACE_SCALES.includes(current) ? INTERFACE_SCALES : [...INTERFACE_SCALES, current].sort((a, b) => a - b);
}

declare global {
  interface Window { __rbnInitialAppearance?: {theme?: string}; }
}

export const THEME_ACCENTS: readonly ThemeAccent[] = ['purple', 'green', 'blue'];
export const THEME_MODES: readonly ThemeMode[] = ['auto', 'light', 'dark'];

const isTheme = (value: unknown): value is Theme => typeof value === 'string' && /^(purple|blue|green)-(dark|light|auto)$/.test(value);

export const themeAccent = (theme: Theme): ThemeAccent => theme.split('-')[0] as ThemeAccent;
export const themeMode = (theme: Theme): ThemeMode => theme.split('-')[1] as ThemeMode;
export const makeTheme = (accent: ThemeAccent, mode: ThemeMode): Theme => `${accent}-${mode}`;

export function initialTheme(): Theme {
  const nativeTheme = window.__rbnInitialAppearance?.theme;
  if (isTheme(nativeTheme)) return nativeTheme;
  const documentTheme = document.documentElement.dataset.theme;
  return isTheme(documentTheme) ? documentTheme : 'purple-auto';
}

let themeApplied = false;
export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  const commit = () => { root.dataset.theme = theme; };
  const changed = themeApplied && root.dataset.theme !== theme;
  themeApplied = true;
  // One snapshot cross-fade (opacity only, so it also runs under Reduce
  // Motion) instead of transitioning every element's colours.
  type Transition = {ready: Promise<void>; finished: Promise<void>; updateCallbackDone: Promise<void>};
  const doc = document as Document & {startViewTransition?: (update: () => void) => Transition};
  if (changed && doc.startViewTransition) {
    // A quick second change skips the running fade; that is expected, not an error.
    const transition = doc.startViewTransition(commit);
    for (const step of [transition.ready, transition.finished, transition.updateCallbackDone]) step?.catch(() => {});
  } else commit();
  try { localStorage.setItem('rbn:theme', theme); } catch { /* Native settings remain the source of truth. */ }
}

export function themeIcon(theme: Theme): string {
  const accent = themeAccent(theme);
  return accent === 'blue' ? 'favicon-blue.svg' : accent === 'green' ? 'favicon-green.svg' : 'favicon.svg';
}

// The native loading cover reads these same rasters. Keeping one optical
// profile avoids an ICNS representation changing shape during the handoff.
export function startupIcon(theme: Theme): string {
  return `startup-${themeAccent(theme)}.png`;
}
