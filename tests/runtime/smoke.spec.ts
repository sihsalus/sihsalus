import { expect, test } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const fixture = JSON.parse(fs.readFileSync(path.join(process.env.SMOKE_STATE!, 'fixture.json'), 'utf8'));
if (fixture.baseURL !== 'http://127.0.0.1' || !['local', 'keycloak'].includes(fixture.mode)) {
  throw new Error('Runtime smoke accepts only its isolated loopback fixture');
}

test('published core serves its SPA, authenticates, and ends the synthetic session', async ({ page, context }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  const session = async () => {
    const response = await context.request.get('/openmrs/ws/rest/v1/session');
    expect(response.status()).toBe(200);
    return response.json();
  };
  await test.step('anonymous REST session and packaged frontend provenance', async () => {
    expect((await session()).authenticated).toBe(false);
    const response = await context.request.get('/openmrs/spa/build-info.json');
    expect(response.status()).toBe(200);
    const build = await response.json();
    expect(build.gitSha).toMatch(/^[a-f0-9]{40}$/);
    console.log(JSON.stringify({ mode: fixture.mode, frontendCommit: build.gitSha }));
  });

  await test.step('render the configured login and authenticate through its UI', async () => {
    await page.goto('/openmrs/spa/login');
    if (fixture.mode === 'keycloak') {
      await expect(page).toHaveURL(/\/keycloak\/realms\/openmrs\//);
      await page.locator('#username').fill('admin');
      await page.locator('#password').fill(fixture.initialPassword);
      await page.locator('#kc-login').click();
      // The actual realm imports a temporary password: exercise the required
      // change instead of disabling that policy or altering realm metadata.
      await page.locator('#password-new').fill(fixture.replacementPassword);
      await page.locator('#password-confirm').fill(fixture.replacementPassword);
      await page.locator('form [type="submit"]').click();
      await page.waitForURL(url => url.pathname.startsWith('/openmrs/'), { timeout: 60_000 });
    } else {
      await page.locator('#username').fill('admin');
      if (!(await page.locator('#password').isVisible())) {
        await page.locator('form [type="submit"]').click();
      }
      await page.locator('#password').fill(fixture.initialPassword);
      await page.locator('form [type="submit"]').click();
    }
  });

  await test.step('complete required account/location steps and mount the home page', async () => {
    await expect.poll(() => new URL(page.url()).pathname).toMatch(
      /^\/openmrs\/(?:spa\/(?:home|login\/location)|admin\/users\/changePassword.form)/,
    );
    if (new URL(page.url()).pathname === '/openmrs/admin/users/changePassword.form') {
      // Legacy UI 2.2.0 owns this supported forced-password form.
      await page.locator('[name="oldPassword"]').fill(fixture.initialPassword);
      await page.locator('[name="password"]').fill(fixture.replacementPassword);
      await page.locator('[name="confirmPassword"]').fill(fixture.replacementPassword);
      await page.locator('#saveButton').click();
      await expect.poll(() => new URL(page.url()).pathname).toMatch(/^\/openmrs\/spa\/(home|login\/location)/);
    }
    if (new URL(page.url()).pathname === '/openmrs/spa/login/location') {
      await page.getByRole('radio').first().check();
      await page.locator('form [type="submit"]').click();
    }
    await expect(page).toHaveURL(/\/openmrs\/spa\/home(?:[/?#]|$)/);
    await expect(page.getByRole('banner').first()).toBeVisible();
    const current = await session();
    expect(current.authenticated).toBe(true);
    expect(current.user.username).toBe('admin');
    expect(errors).toEqual([]);
  });

  await test.step('logout invalidates the server session and requires login again', async () => {
    await page.goto('/openmrs/spa/logout');
    if (fixture.mode === 'keycloak') {
      const confirmation = page.locator('#kc-logout');
      await Promise.race([
        confirmation.waitFor({ state: 'visible' }),
        page.locator('#username').waitFor({ state: 'visible' }),
      ]);
      if (await confirmation.isVisible()) await confirmation.click();
    }
    await expect.poll(async () => (await session()).authenticated).toBe(false);
    await page.goto('/openmrs/spa/home');
    await expect(page.locator('#username')).toBeVisible();
    expect((await session()).authenticated).toBe(false);
  });
  console.log(JSON.stringify({ mode: fixture.mode, spa: 'passed', login: 'passed', logout: 'passed', patientWrites: 0 }));
});
