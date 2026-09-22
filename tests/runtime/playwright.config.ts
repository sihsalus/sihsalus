import { defineConfig } from '@playwright/test';
import path from 'node:path';

if (!process.env.SMOKE_STATE) throw new Error('A private synthetic runtime fixture is required');

export default defineConfig({
  testDir: '.',
  testMatch: 'smoke.spec.ts',
  timeout: 240_000,
  expect: { timeout: 60_000 },
  workers: 1,
  retries: 0,
  reporter: 'line',
  outputDir: path.join(process.env.SMOKE_STATE, 'private-playwright'),
  use: { browserName: 'chromium', baseURL: 'http://127.0.0.1', trace: 'off', screenshot: 'off', video: 'off' },
});
