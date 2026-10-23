import { expect, test, type Page } from '@playwright/test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { installHostFixture, selectPlace } from './native-fixture';
import { translator } from '../renderer/i18n';
import { ListingCache, relatedEndpoints } from '../renderer/listingCache';
import type { Endpoint, FileEntry, ResolvedLanguage, Theme } from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
const pane = (page: Page, side: 'left' | 'right' = 'right') => page.getByTestId(`${side}-pane`);
const input = (page: Page, side: 'left' | 'right' = 'right') => pane(page, side).locator('.path-form input');
const file = (name: string): FileEntry => ({ name, path: name, size: 42, modified: '2026-10-20T12:00:00Z', isDir: false });
async function open(page: Page, settings: Parameters<typeof installHostFixture>[1] = {}) {
  await installHostFixture(page, { ...settings, settings: { autoCheckUpdates: false, theme: 'purple-dark', ...settings.settings } });
  await page.goto(url);
  for (const side of ['left', 'right'] as const) {
    await expect(pane(page, side).locator('.file-name').first()).toBeVisible();
    await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  }
}
async function go(page: Page, value: string, side: 'left' | 'right' = 'right', wait = true) {
  await input(page, side).fill(value);
  await input(page, side).press('Enter');
  if (wait) {
    await expect(input(page, side)).toHaveValue(value || '/');
    await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  }
}
async function calls(page: Page, method = 'list') {
  return page.evaluate(method => (window as any).__fixture.calls.filter((call: any) => call.method === method), method);
}
async function listings(page: Page, values: Record<string, FileEntry[]>) {
  await page.evaluate(values => Object.assign((window as any).__fixture.listings, values), values);
}
async function gate(page: Page, key: string, method = 'list') {
  await page.evaluate(({ key, method }) => {
    const w = window as any;
    if (!w.__listingGates) {
      w.__listingGates = new Map();
      const send = w.webkit.messageHandlers.rclone.postMessage, reply = w.__rbnReply;
      const requests = new Map<string, string>();
      w.webkit.messageHandlers.rclone.postMessage = (message: any) => {
        const key = message.method === 'list' ? `${message.args[0].remote ?? 'local'}:${message.args[0].path}` : message.method;
        if (w.__listingGates.has(key)) requests.set(message.id, key);
        send(message);
      };
      w.__rbnReply = (message: any) => {
        const key = requests.get(message.id), held = w.__listingGates.get(key);
        if (held) { held.push(message); return; }
        reply(message);
      };
      w.__releaseListingGate = (key: string) => {
        const held = w.__listingGates.get(key) || [];
        w.__listingGates.delete(key);
        for (const message of held) reply(message);
      };
    }
    w.__listingGates.set(method === 'list' ? key : method, []);
  }, { key, method });
}
async function release(page: Page, key: string) {
  await page.evaluate(key => (window as any).__releaseListingGate(key), key);
}
async function waitHeld(page: Page, key: string) {
  await expect.poll(() => page.evaluate(key => (window as any).__listingGates.get(key)?.length || 0, key)).toBeGreaterThan(0);
}

// Budget/epoch tests exercise eviction and delayed insertion independently of
// DOM timing. Native process termination is verified by the engine suite.
test('remote cache is session-only LRU bounded by folder, entry and byte budgets', () => {
  const a = { remote: 'drive', path: 'A' }, b = { remote: 'drive', path: 'B' }, c = { remote: 'drive', path: 'C' };
  const cache = new ListingCache({ folders: 2, entries: 3, bytes: 2000 });
  expect(cache.put({ remote: null, path: '/tmp' }, [file('local')])).toBe(false);
  cache.put(a, [file('A')]); cache.put(b, []);
  expect(cache.get(a)).toEqual([file('A')]);
  cache.put(c, [file('C')]);
  expect(cache.get(b)).toBeUndefined();
  expect(cache.get(a)).toHaveLength(1);
  expect(cache.put(b, Array.from({ length: 4 }, () => file('large')))).toBe(false);
  expect(cache.put(b, [file('x'.repeat(2000))])).toBe(false);
  expect(cache.size).toBe(2);
  const epoch = cache.epoch;
  cache.clear();
  expect(cache.put(a, [file('late')], epoch)).toBe(false);
  expect(cache.size).toBe(0);
});

test('cache invalidation respects account and path boundaries and pane ownership', () => {
  const cache = new ListingCache(), other = new ListingCache();
  const endpoints: Endpoint[] = ['', 'A', 'A/child', 'AB', 'B'].map(path => ({ remote: 'drive', path }));
  for (const endpoint of endpoints) { cache.put(endpoint, []); other.put(endpoint, []); }
  cache.put({ remote: 'second', path: 'A' }, []);
  cache.invalidate({ remote: 'drive', path: 'A/' });
  for (const endpoint of endpoints.slice(0, 3)) expect(cache.get(endpoint)).toBeUndefined();
  expect(cache.get(endpoints[3])).toEqual([]);
  expect(cache.get({ remote: 'second', path: 'A' })).toEqual([]);
  expect(other.get(endpoints[1])).toEqual([]);
  expect(relatedEndpoints({ remote: null, path: 'C:\\Users\\test' }, { remote: null, path: 'C:/Users/test/child' })).toBe(true);
  expect(relatedEndpoints({ remote: 'drive', path: 'A' }, { remote: 'drive', path: 'AB' })).toBe(false);
});

test('loading keeps path, rows and history together; keyboard cancel waits for native stop and rejects a late reply', async ({ page }) => {
  await open(page);
  await listings(page, { 'research-drive:A': [file('A.txt')], 'research-drive:B': [file('B.txt')] });
  await go(page, 'A');
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('/');
  await gate(page, 'research-drive:B'); await gate(page, '', 'cancelList');
  await go(page, 'B', 'right', false);
  const button = pane(page).getByRole('button', { name: t('cancelLoadingFolder'), exact: true });
  await expect(button).toBeVisible();
  await expect(input(page)).toHaveValue('/');
  await expect(pane(page).locator('.file-name').filter({ hasText: /^Documents$/ })).toBeVisible();
  await expect(pane(page).getByRole('button', { name: t('forward'), exact: true })).toBeEnabled();
  await button.focus();
  await expect(button.locator('.folder-loading-cross')).toHaveCSS('opacity', '1');
  await expect(button.locator('.folder-loading-ring')).toHaveCSS('animation-name', 'none');
  await button.press('Space');
  await waitHeld(page, 'cancelList');
  await expect(pane(page).getByRole('button', { name: t('cancellingFolder'), exact: true })).toBeDisabled();
  const request = (await calls(page)).at(-1);
  expect((await calls(page, 'cancelList')).at(-1).args).toEqual([request.args[1].requestId]);
  await waitHeld(page, 'research-drive:B');
  await release(page, 'research-drive:B');
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'true');
  await release(page, 'cancelList');
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(input(page)).toHaveValue('/');
  await expect(pane(page).locator('.notice-error')).toHaveCount(0);
  await pane(page).getByRole('button', { name: t('forward'), exact: true }).click();
  await expect(input(page)).toHaveValue('A');
  const before = (await calls(page)).length;
  await go(page, 'B');
  expect((await calls(page)).length).toBe(before + 1);
  await expect(pane(page).locator('.file-name')).toHaveText(['B.txt']);
});

test('pending remote navigation can be superseded without committing the older result or its history', async ({ page }) => {
  await open(page);
  await listings(page, { 'research-drive:Slow': [file('Old.txt')], 'research-drive:Fast': [file('New.txt')] });
  await gate(page, 'research-drive:Slow');
  await go(page, 'Slow', 'right', false); await waitHeld(page, 'research-drive:Slow');
  const slow = (await calls(page)).at(-1);
  await go(page, 'Fast');
  expect((await calls(page, 'cancelList')).some((call: any) => call.args[0] === slow.args[1].requestId)).toBe(true);
  await release(page, 'research-drive:Slow');
  await expect(pane(page).locator('.file-name')).toHaveText(['New.txt']);
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('/');
  await expect(pane(page).getByRole('button', { name: t('back'), exact: true })).toBeDisabled();
});

test('failed navigation leaves the original folder actionable; retry commits the requested folder once', async ({ page }) => {
  await open(page);
  await listings(page, { 'research-drive:A': [file('A.txt')], 'research-drive:B': [file('B.txt')] });
  await go(page, 'A');
  await page.evaluate(() => { (window as any).__fixture.listingError = 'Connection interrupted. Reconnect and retry.\n'.repeat(18); });
  await go(page, 'B', 'right', false);
  await expect(pane(page)).toContainText('Connection interrupted');
  await expect(input(page)).toHaveValue('A');
  await expect(pane(page).locator('.file-name')).toHaveText(['A.txt']);
  const diagnostic = pane(page).locator('.notice.error');
  expect((await diagnostic.boundingBox())!.height).toBeLessThanOrEqual(120);
  expect(await diagnostic.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true);
  await expect(pane(page).getByRole('button', { name: t('newFolder'), exact: true })).toBeEnabled();
  await pane(page).getByRole('button', { name: t('newFolder'), exact: true }).click();
  await expect(page.getByRole('dialog').locator('.file-dialog-location')).toHaveText('research-drive:A');
  await page.getByRole('dialog').getByRole('button', { name: t('cancel'), exact: true }).click();
  await page.evaluate(() => { (window as any).__fixture.listingError = ''; });
  await pane(page).getByRole('button', { name: t('retry'), exact: true }).click();
  await expect(input(page)).toHaveValue('B');
  await expect(pane(page).locator('.file-name')).toHaveText(['B.txt']);
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('A');
});

test('explicit refresh discards a path draft while background refresh preserves its transfer guard', async ({ page }) => {
  await open(page);
  await go(page, 'A');
  for (const control of ['toolbar', 'pane-key', 'header-key'] as const) {
    await input(page).fill('Unsubmitted-B');
    await expect(page.locator('.start-button')).toBeDisabled();
    if (control === 'toolbar') await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
    else if (control === 'pane-key') await input(page).press('F5');
    else { await page.locator('.main-nav button').first().focus(); await page.keyboard.press('Control+r'); }
    await expect(input(page)).toHaveValue('A');
    await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    expect((await calls(page)).at(-1).args[0]).toEqual({ remote: 'research-drive', path: 'A' });
    await expect(page.locator('.start-button')).toBeEnabled();
  }
  await input(page).fill('Unsubmitted-B');
  const before = (await calls(page)).length;
  await page.evaluate(() => {
    const w = window as any, job = structuredClone(w.__fixture.job);
    job.id = 'draft-background-refresh'; job.request.destination = { remote: 'research-drive', path: 'A' };
    for (const status of ['running', 'completed']) { job.status = status; w.__rbnEvent({ type: 'jobUpdate', data: structuredClone(job) }); }
  });
  await expect.poll(async () => (await calls(page)).length).toBe(before + 1);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(input(page)).toHaveValue('Unsubmitted-B');
  await expect(page.locator('.start-button')).toBeDisabled();
  await expect(page.getByText(t('uncommittedPath'), { exact: true })).toBeVisible();
  await input(page).press('Escape');
  await expect(input(page)).toHaveValue('A');
  await page.locator('.start-button').click();
  await expect.poll(async () => (await calls(page, 'startTransfer')).length).toBe(1);
  expect((await calls(page, 'startTransfer'))[0].args[0].destination).toEqual({ remote: 'research-drive', path: 'A' });
});

test('all remote levels including empty folders use cache; local navigation stays fresh', async ({ page }) => {
  await open(page);
  await listings(page, { 'research-drive:A': [file('A.txt')], 'research-drive:A/B': [], 'research-drive:A/B/C': [file('C.txt')] });
  for (const path of ['A', 'A/B', 'A/B/C']) await go(page, path);
  const before = (await calls(page)).length;
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('A/B');
  await expect(pane(page).getByText(t('emptyFolder'), { exact: true })).toBeVisible();
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('A');
  await pane(page).getByRole('button', { name: t('forward'), exact: true }).click();
  await expect(input(page)).toHaveValue('A/B');
  expect((await calls(page)).length).toBe(before);
  await go(page, '/Users/test/Local', 'left');
  const localBefore = (await calls(page)).length;
  await pane(page, 'left').getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page, 'left')).toHaveValue('/Users/test');
  expect((await calls(page)).length).toBe(localBefore + 1);
});

test('explicit refresh clears every remote, layer and tab only in the initiating pane', async ({ page }) => {
  await open(page);
  await selectPlace(pane(page, 'left').locator('.location-trigger'), 'research-drive');
  await expect(pane(page, 'left').locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  for (const side of ['left', 'right'] as const) { await go(page, 'A', side); await go(page, 'B', side); }
  await pane(page, 'left').getByRole('button', { name: t('newTab'), exact: true }).click();
  await selectPlace(pane(page, 'left').locator('.location-trigger'), 'lab-nas');
  await go(page, 'NAS', 'left');
  await pane(page, 'left').getByRole('tab').first().click();
  await expect(input(page, 'left')).toHaveValue('B');
  const before = (await calls(page)).length;
  await pane(page, 'left').getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect.poll(async () => (await calls(page)).length).toBe(before + 1);
  await expect(pane(page, 'left').locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await pane(page, 'right').getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page, 'right')).toHaveValue('A');
  expect((await calls(page)).length).toBe(before + 1);
  await pane(page, 'left').getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page, 'left')).toHaveValue('A');
  expect((await calls(page)).length).toBe(before + 2);
  await pane(page, 'left').getByRole('tab').nth(1).click();
  await expect(input(page, 'left')).toHaveValue('NAS');
  expect((await calls(page)).length).toBe(before + 3);
});

test('F5 refresh retires a pending old epoch so its late result cannot refill the cleared cache', async ({ page }) => {
  await open(page);
  await gate(page, 'research-drive:B');
  await go(page, 'B', 'right', false); await waitHeld(page, 'research-drive:B');
  await input(page).press('F5');
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(input(page)).toHaveValue('/');
  await release(page, 'research-drive:B');
  const before = (await calls(page)).length;
  await go(page, 'B');
  expect((await calls(page)).length).toBe(before + 1);
});

test('request tokens and cancellation are independent across simultaneous panes', async ({ page }) => {
  await open(page);
  await gate(page, 'local:/Users/test/Slow'); await gate(page, 'research-drive:Slow');
  await go(page, '/Users/test/Slow', 'left', false);
  await go(page, 'Slow', 'right', false);
  await waitHeld(page, 'local:/Users/test/Slow'); await waitHeld(page, 'research-drive:Slow');
  const pending = (await calls(page)).slice(-2);
  expect(new Set(pending.map((call: any) => call.args[1].requestId)).size).toBe(2);
  await pane(page, 'left').getByRole('button', { name: t('cancelLoadingFolder'), exact: true }).focus();
  await page.keyboard.press('Escape');
  await expect(pane(page, 'left').locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'true');
  expect((await calls(page, 'cancelList')).map((call: any) => call.args[0])).toContain(pending[0].args[1].requestId);
  expect((await calls(page, 'cancelList')).map((call: any) => call.args[0])).not.toContain(pending[1].args[1].requestId);
  await release(page, 'research-drive:Slow'); await release(page, 'local:/Users/test/Slow');
  await expect(input(page)).toHaveValue('Slow');
  await expect(input(page, 'left')).toHaveValue('/Users/test');
});

test('a folder mutation invalidates related cached descendants without rereading an unrelated pane', async ({ page }) => {
  await open(page);
  await go(page, 'A'); await go(page, 'A/child');
  await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
  await expect(input(page)).toHaveValue('A');
  const before = (await calls(page)).length;
  await pane(page).getByRole('button', { name: t('newFolder'), exact: true }).click();
  await page.getByRole('dialog').getByLabel(t('name'), { exact: true }).fill('Created');
  await page.getByRole('dialog').getByRole('button', { name: t('create'), exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect.poll(async () => (await calls(page)).length).toBe(before + 1);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await go(page, 'A/child');
  expect((await calls(page)).length).toBe(before + 2);
  expect((await calls(page)).slice(before).every((call: any) => call.args[0].remote === 'research-drive')).toBe(true);
});

test('terminal move invalidates source and destination caches once, including a pending destination', async ({ page }) => {
  await open(page);
  await selectPlace(pane(page, 'left').locator('.location-trigger'), 'research-drive');
  await go(page, 'Source', 'left'); await go(page, 'Source/child', 'left');
  await go(page, 'Destination'); await go(page, 'Destination/child');
  await go(page, 'Source', 'left'); await go(page, 'Destination');
  await gate(page, 'research-drive:Destination/new');
  await go(page, 'Destination/new', 'right', false);
  await waitHeld(page, 'research-drive:Destination/new');
  const before = (await calls(page)).length;
  await page.evaluate(() => {
    const w = window as any, job = structuredClone(w.__fixture.job);
    job.request.source = {remote: 'research-drive', path: 'Source'};
    job.request.destination = {remote: 'research-drive', path: 'Destination'};
    job.request.mode = 'move';
    for (const status of ['running', 'completed', 'completed']) { job.status = status; w.__rbnEvent({ type: 'jobUpdate', data: structuredClone(job) }); }
  });
  await expect.poll(async () => (await calls(page)).length).toBe(before + 2);
  await expect.poll(() => page.evaluate(() => (window as any).__listingGates.get('research-drive:Destination/new')?.length || 0)).toBe(2);
  await release(page, 'research-drive:Destination/new');
  await expect(input(page)).toHaveValue('Destination/new');
  await expect(pane(page, 'left').locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await go(page, 'Source/child', 'left'); await go(page, 'Destination/child');
  expect((await calls(page)).length).toBe(before + 4);
});

for (const outcome of ['cancel', 'fail'] as const) {
  test(`an invalidated retained folder refreshes after unrelated navigation ${outcome} without changing its history`, async ({ page }) => {
    await open(page);
    await listings(page, { 'research-drive:A': [file('Before.txt')], 'research-drive:B': [file('B.txt')] });
    await go(page, 'A');
    await gate(page, 'research-drive:B');
    if (outcome === 'fail') await page.evaluate(() => { (window as any).__fixture.listingError = 'B is unavailable'; });
    await go(page, 'B', 'right', false);
    await waitHeld(page, 'research-drive:B');
    await page.evaluate(() => { (window as any).__fixture.listingError = ''; });
    await listings(page, { 'research-drive:A': [file('After.txt')] });
    const before = (await calls(page)).length;
    await page.evaluate(() => {
      const w = window as any, job = structuredClone(w.__fixture.job);
      job.id = 'retained-folder-changed'; job.request.destination = { remote: 'research-drive', path: 'A' };
      for (const status of ['running', 'completed']) { job.status = status; w.__rbnEvent({ type: 'jobUpdate', data: structuredClone(job) }); }
    });
    expect((await calls(page)).length).toBe(before);
    if (outcome === 'cancel') await pane(page).getByRole('button', { name: t('cancelLoadingFolder'), exact: true }).click();
    await release(page, 'research-drive:B');
    await expect(pane(page).locator('.file-name')).toHaveText(['After.txt']);
    await expect(input(page)).toHaveValue('A');
    await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    const refreshed = (await calls(page)).slice(before);
    expect(refreshed.map((call: any) => call.args[0])).toEqual([{ remote: 'research-drive', path: 'A' }]);
    if (outcome === 'fail') {
      await expect(pane(page)).toContainText('B is unavailable');
      await pane(page).getByRole('button', { name: t('retry'), exact: true }).click();
      await expect(input(page)).toHaveValue('B');
      await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
      await expect(input(page)).toHaveValue('A');
    }
    await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
    await expect(input(page)).toHaveValue('/');
    await expect(pane(page).getByRole('button', { name: t('back'), exact: true })).toBeDisabled();
    await pane(page).getByRole('button', { name: t('forward'), exact: true }).click();
    await expect(input(page)).toHaveValue('A');
  });
}

for (const scenario of ['pending invalidated folder', 'failed navigation target'] as const) {
  test(`closing the inactive tab cleans up its ${scenario}`, async ({ page }) => {
    await open(page);
    await listings(page, { 'research-drive:A': [file('Before.txt')], 'research-drive:B': [file('B.txt')] });
    await go(page, 'A');
    await pane(page).getByRole('button', { name: t('newTab'), exact: true }).click();
    await go(page, 'B');
    await pane(page).getByRole('tab').first().click();
    await expect(input(page)).toHaveValue('A');
    await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
    await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    await gate(page, 'research-drive:B');
    if (scenario === 'failed navigation target') await page.evaluate(() => { (window as any).__fixture.listingError = 'B is unavailable'; });
    await pane(page).getByRole('tab').nth(1).click();
    await waitHeld(page, 'research-drive:B');
    await page.evaluate(() => { (window as any).__fixture.listingError = ''; });
    const before = (await calls(page)).length;
    if (scenario === 'pending invalidated folder') {
      await listings(page, { 'research-drive:A': [file('After.txt')] });
      await page.evaluate(() => {
        const w = window as any, job = structuredClone(w.__fixture.job);
        job.id = 'retained-tab-changed'; job.request.destination = { remote: 'research-drive', path: 'A' };
        for (const status of ['running', 'completed']) { job.status = status; w.__rbnEvent({ type: 'jobUpdate', data: structuredClone(job) }); }
      });
    } else {
      await release(page, 'research-drive:B');
      await expect(pane(page).getByRole('button', { name: t('retry'), exact: true })).toBeVisible();
    }
    await pane(page).locator('.pane-tab').nth(1).locator('.tab-close').click();
    if (scenario === 'pending invalidated folder') await release(page, 'research-drive:B');
    await expect(pane(page).getByRole('tab')).toHaveCount(1);
    await expect(input(page)).toHaveValue('A');
    await expect(pane(page).locator('.file-name')).toHaveText([scenario === 'pending invalidated folder' ? 'After.txt' : 'Before.txt']);
    await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    await expect(pane(page).getByRole('button', { name: t('retry'), exact: true })).toHaveCount(0);
    expect((await calls(page)).slice(before).map((call: any) => call.args[0])).toEqual(scenario === 'pending invalidated folder' ? [{ remote: 'research-drive', path: 'A' }] : []);
    await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
    await expect(input(page)).toHaveValue('/');
    await expect(pane(page).getByRole('button', { name: t('back'), exact: true })).toBeDisabled();
  });
}

test('configuration changes clear both caches and selections before listings return', async ({ page }) => {
  await open(page);
  await selectPlace(pane(page, 'left').locator('.location-trigger'), 'research-drive');
  for (const side of ['left', 'right'] as const) { await go(page, 'A', side); await go(page, 'B', side); }
  await pane(page, 'left').getByRole('checkbox', { name: `${t('selected')} Documents`, exact: true }).check();
  await pane(page, 'left').getByRole('button', { name: t('newTab'), exact: true }).click();
  await pane(page, 'left').getByRole('tab').first().click();
  const before = (await calls(page)).length;
  await gate(page, 'research-drive:B');
  await page.evaluate(() => (window as any).__rbnEvent({ type: 'configurationChanged' }));
  await expect(pane(page, 'left').locator('.file-name')).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => (window as any).__listingGates.get('research-drive:B')?.length || 0)).toBe(2);
  await release(page, 'research-drive:B');
  await expect(pane(page, 'left').getByRole('checkbox', { name: `${t('selected')} Documents`, exact: true })).not.toBeChecked();
  await pane(page, 'left').getByRole('tab').nth(1).click();
  await expect(pane(page, 'left').getByRole('checkbox', { name: `${t('selected')} Documents`, exact: true })).not.toBeChecked();
  await go(page, 'A', 'left'); await go(page, 'A');
  expect((await calls(page)).length).toBe(before + 4);
});

test('bridge timeout sends scoped cancellation and cannot accept a delayed listing', async ({ page }) => {
  await open(page);
  await page.clock.install();
  await gate(page, 'research-drive:Slow');
  await go(page, 'Slow', 'right', false);
  const request = (await calls(page)).at(-1);
  await page.clock.fastForward(120_010);
  await expect(pane(page)).toContainText('程式回應逾時');
  expect((await calls(page, 'cancelList')).some((call: any) => call.args[0] === request.args[1].requestId)).toBe(true);
  await release(page, 'research-drive:Slow');
  await expect(input(page)).toHaveValue('/');
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
});

test('initial listing failure retries the desired remote instead of the blank initial endpoint', async ({ page }) => {
  await installHostFixture(page, { settings: { autoCheckUpdates: false } });
  await page.addInitScript(() => { (window as any).__fixture.listingError = 'First listing unavailable'; });
  await page.goto(url);
  await expect(pane(page).getByRole('button', { name: t('retry'), exact: true })).toBeVisible();
  await page.evaluate(() => { (window as any).__fixture.listingError = ''; });
  await pane(page).getByRole('button', { name: t('retry'), exact: true }).click();
  await expect(pane(page).locator('.file-name').first()).toBeVisible();
  expect((await calls(page)).at(-1).args[0]).toEqual({ remote: 'research-drive', path: '' });
  await expect(pane(page).locator('.location-trigger')).toContainText('research-drive');
});

test('cancelling the first remote listing still allows Refresh to retry its intended root', async ({ page }) => {
  await installHostFixture(page, { delays: { list: [2, 60_000] }, settings: { autoCheckUpdates: false } });
  await page.goto(url);
  await expect(pane(page, 'left').locator('.file-name').first()).toBeVisible();
  const button = pane(page).getByRole('button', { name: t('cancelLoadingFolder'), exact: true });
  await expect(button).toBeVisible();
  await expect(pane(page).getByRole('button', { name: t('newTab'), exact: true })).toBeDisabled();
  const before = (await calls(page)).length;
  await pane(page).getByRole('tab').click();
  expect((await calls(page)).length).toBe(before);
  await button.click();
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect(pane(page).locator('.file-name').first()).toBeVisible();
  expect((await calls(page)).length).toBe(before + 1);
  expect((await calls(page)).at(-1).args[0]).toEqual({ remote: 'research-drive', path: '' });
  await expect(pane(page).locator('.location-trigger')).toContainText('research-drive');
});

test('configuration reload waits for scoped cancellation before reloading the original current locations', async ({ page }) => {
  await open(page);
  await go(page, 'A');
  await gate(page, 'research-drive:Slow'); await gate(page, '', 'cancelList');
  await go(page, 'Slow', 'right', false); await waitHeld(page, 'research-drive:Slow');
  const before = (await calls(page, 'bootstrap')).length;
  await page.evaluate(() => (window as any).__rbnEvent({ type: 'configurationChanged' }));
  await waitHeld(page, 'cancelList');
  await expect(pane(page).locator('.file-name')).toHaveCount(0);
  await expect(page.locator('.start-button')).toBeDisabled();
  expect((await calls(page, 'bootstrap')).length).toBe(before);
  await release(page, 'cancelList');
  await expect.poll(async () => (await calls(page, 'bootstrap')).length).toBe(before + 1);
  await expect(pane(page).locator('.file-name').first()).toBeVisible();
  await expect(input(page)).toHaveValue('A');
  await release(page, 'research-drive:Slow');
  await expect(input(page)).toHaveValue('A');
});

test('hover reveals cancel while the ring rotates; Escape in the unchanged path box cancels', async ({ page }) => {
  await open(page);
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await gate(page, 'research-drive:Slow');
  await go(page, 'Slow', 'right', false);
  const button = pane(page).getByRole('button', { name: t('cancelLoadingFolder'), exact: true });
  await expect(button.locator('.folder-loading-ring')).toHaveCSS('animation-name', 'folder-reading');
  await expect(button.locator('.folder-loading-cross')).toHaveCSS('opacity', '0');
  await button.hover();
  await expect(button.locator('.folder-loading-cross')).toHaveCSS('opacity', '1');
  await input(page).focus(); await page.keyboard.press('Escape');
  await expect(pane(page).locator('.folder-loading-overlay')).toHaveCount(0);
  await release(page, 'research-drive:Slow');
  await expect(input(page)).toHaveValue('/');
});

for (const [language, theme] of [['zh-TW', 'purple-dark'], ['en', 'blue-light'], ['ja', 'green-dark'], ['zh-TW', 'purple-light'], ['en', 'blue-dark'], ['ja', 'green-light']] as [ResolvedLanguage, Theme][]) {
  test(`${language} ${theme}: compact loading control stays centered and keyboard accessible in a narrow pane`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 1024, height: 720 });
    await open(page, { settings: { language, theme } });
    const target = language === 'zh-TW' ? '正在備份的研究資料與跨部門共享檔案'.repeat(3) : language === 'ja' ? '研究資料とチームの共有フォルダ'.repeat(3) : 'Long folder name with research and shared files '.repeat(3).trim();
    await gate(page, `research-drive:${target}`);
    await go(page, target, 'right', false);
    const tx = translator(language), button = pane(page).getByRole('button', { name: tx('cancelLoadingFolder'), exact: true });
    await expect(button).toBeVisible();
    const content = await pane(page).locator('.file-list').boundingBox(), control = await button.boundingBox();
    expect(Math.abs(control!.x + control!.width / 2 - content!.x - content!.width / 2)).toBeLessThan(1);
    expect(Math.abs(control!.y + control!.height / 2 - content!.y - content!.height / 2)).toBeLessThan(1);
    expect(control!.width).toBeLessThanOrEqual(44);
    const caption = await pane(page).locator('.folder-loading-label').boundingBox();
    expect(caption!.x).toBeGreaterThanOrEqual(content!.x);
    expect(caption!.x + caption!.width).toBeLessThanOrEqual(content!.x + content!.width);
    if (theme === 'purple-dark') {
      await button.hover();
      await page.screenshot({ path: testInfo.outputPath('folder-reading-cancel.zh-TW.png') });
    }
    await button.focus(); await button.press('Enter');
    await expect(pane(page).locator('.folder-loading-overlay')).toHaveCount(0);
    await release(page, `research-drive:${target}`);
    await expect(input(page)).toHaveValue('/');
  });
}

test('the native scrollbar gutter stays uniform across empty, filtered, short and overflowing lists in all themes', async ({ page }, testInfo) => {
  await open(page);
  await listings(page, { 'research-drive:Empty': [], 'research-drive:Short': [file('One.txt')], 'research-drive:Long': Array.from({ length: 80 }, (_, index) => file(`File-${String(index).padStart(2, '0')}.txt`)) });
  const scroller = pane(page).locator('.file-list > [data-virtuoso-scroller], .file-list > .file-empty-scroller');
  const geometry = () => scroller.evaluate(element => {
    const box = element.getBoundingClientRect(), table = element.querySelector('table')?.getBoundingClientRect();
    const sample = document.createElement('span'); sample.style.color = 'var(--surface-subtle)'; element.append(sample);
    const track = getComputedStyle(sample).color; sample.remove();
    return { width: box.width, content: element.clientWidth, gutter: element.offsetWidth - element.clientWidth, height: element.clientHeight, scrollHeight: element.scrollHeight, tableLeft: table?.x, tableWidth: table?.width, track };
  });
  const samplePixels = async (dimensions: Awaited<ReturnType<typeof geometry>>) => {
    const png = await scroller.screenshot();
    return page.evaluate(async ({ png, gutter, content }) => {
      const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d')!; context.drawImage(image, 0, 0);
      const rgb = (x: number, y: number) => { const [r, g, b] = context.getImageData(Math.floor(x), y, 1, 1).data; return `rgb(${r}, ${g}, ${b})`; };
      return { track: [90, 127, 164, 201].filter(y => y < image.height - 20).map(y => rgb(image.width - gutter / 2, y)), rows: [rgb(content - 5, 90), rgb(content - 5, 127)] };
    }, { png: png.toString('base64'), gutter: dimensions.gutter, content: dimensions.content });
  };
  for (const theme of ['purple-dark', 'purple-light', 'blue-dark', 'blue-light', 'green-dark', 'green-light'] as Theme[]) {
    await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
    await go(page, 'Short');
    const short = await geometry();
    expect(short.gutter).toBeGreaterThan(0);
    expect(short.scrollHeight).toBe(short.height);
    const pixels = await samplePixels(short);
    expect(pixels.track.length).toBeGreaterThan(1);
    expect(pixels.track.every(color => color === short.track), `${theme}: ${JSON.stringify(pixels)}`).toBe(true);
    expect(pixels.rows[0]).not.toBe(pixels.rows[1]);
    if (theme === 'purple-dark') await pane(page).screenshot({ path: testInfo.outputPath('uniform-gutter-short.zh-TW.png') });
    await go(page, 'Long');
    const long = await geometry();
    expect(long.scrollHeight).toBeGreaterThan(long.height);
    expect(long.gutter).toBe(short.gutter);
    expect(long.content).toBe(short.content);
    expect(long.tableLeft).toBe(short.tableLeft);
    expect(long.tableWidth).toBe(short.tableWidth);
    if (theme === 'purple-dark') await pane(page).screenshot({ path: testInfo.outputPath('uniform-gutter-long.zh-TW.png') });
    await go(page, 'Empty');
    const empty = await geometry();
    expect(empty.gutter).toBe(short.gutter);
    expect(empty.content).toBe(short.content);
    expect(empty.scrollHeight).toBe(empty.height);
    expect((await samplePixels(empty)).track.every(color => color === empty.track)).toBe(true);
    await expect(pane(page).getByText(t('emptyFolder'), { exact: true })).toBeVisible();
    if (theme === 'purple-dark') await pane(page).screenshot({ path: testInfo.outputPath('uniform-gutter-empty.zh-TW.png') });
    await go(page, 'Short');
    expect((await geometry()).content).toBe(short.content);
    await pane(page).getByRole('textbox', { name: `${t('right')} ${t('search')}`, exact: true }).fill('no-such-file');
    await expect(pane(page).getByText(t('noMatches'), { exact: true })).toBeVisible();
    const filtered = await geometry();
    expect(filtered.gutter).toBe(short.gutter);
    expect(filtered.content).toBe(short.content);
    expect(filtered.scrollHeight).toBe(filtered.height);
    expect((await samplePixels(filtered)).track.every(color => color === filtered.track)).toBe(true);
    if (theme === 'purple-dark') await pane(page).screenshot({ path: testInfo.outputPath('uniform-gutter-filtered.zh-TW.png') });
    await pane(page).getByRole('textbox', { name: `${t('right')} ${t('search')}`, exact: true }).fill('');
    await expect(pane(page).locator('.file-name')).toHaveText(['One.txt']);
    expect((await geometry()).content).toBe(short.content);
  }
});
