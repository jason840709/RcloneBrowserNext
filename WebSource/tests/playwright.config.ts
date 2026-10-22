import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  outputDir: process.env.RBN_TEST_OUTPUT || '.test-results',
  fullyParallel: false,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 6_000 },
  reporter: [['list']],
  use: {
    browserName: process.env.RBN_TEST_WEBKIT ? 'webkit' : 'chromium',
    headless: true,
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    reducedMotion: 'reduce',
    launchOptions: { ignoreDefaultArgs: ['--hide-scrollbars'], ...(process.env.RBN_TEST_BROWSER ? { executablePath: process.env.RBN_TEST_BROWSER } : {}) },
  },
});
