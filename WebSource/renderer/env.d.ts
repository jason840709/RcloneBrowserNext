/// <reference types="vite/client" />
import type { ExoticComponent, ReactNode } from 'react';

// React 19.2 made <Activity> stable; the pinned @types/react 19.0.0 predates it.
declare module 'react' {
  export const Activity: ExoticComponent<{mode?: 'visible' | 'hidden'; name?: string; children?: ReactNode}>;
}
