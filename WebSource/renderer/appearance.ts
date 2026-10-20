import type {InterfaceScale, Theme} from '../shared/types';

export const INTERFACE_SCALES: readonly InterfaceScale[] = [80, 90, 100, 110, 125];

export const interfaceScaleZoom = (scale: InterfaceScale): number => (scale - 10) / 100;

export function interfaceScaleChoices(current: InterfaceScale): readonly InterfaceScale[] {
  return INTERFACE_SCALES.includes(current) ? INTERFACE_SCALES : [...INTERFACE_SCALES, current].sort((a, b) => a - b);
}

declare global {
  interface Window { __rbnInitialAppearance?: {theme?: string}; }
}

const isTheme = (value: unknown): value is Theme => typeof value === 'string' && /^(purple|blue|green)-(dark|light)$/.test(value);

export function initialTheme(): Theme {
  const nativeTheme = window.__rbnInitialAppearance?.theme;
  if (isTheme(nativeTheme)) return nativeTheme;
  const documentTheme = document.documentElement.dataset.theme;
  return isTheme(documentTheme) ? documentTheme : 'purple-dark';
}

export function applyTheme(theme: Theme) {
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem('rbn:theme', theme); } catch { /* Native settings remain the source of truth. */ }
}

export function themeIcon(theme: Theme): string {
  return theme.startsWith('blue-') ? 'favicon-blue.svg' : theme.startsWith('green-') ? 'favicon-green.svg' : 'favicon.svg';
}
