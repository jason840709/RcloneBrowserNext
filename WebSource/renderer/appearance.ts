import type {InterfaceScale, Theme} from '../shared/types';

export const INTERFACE_SCALES: readonly InterfaceScale[] = [80, 90, 100, 110, 125];

export function themeIcon(theme: Theme): string {
  return theme.startsWith('blue-') ? 'favicon-blue.svg' : theme.startsWith('green-') ? 'favicon-green.svg' : 'favicon.svg';
}
