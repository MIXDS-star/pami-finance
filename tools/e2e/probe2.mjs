import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ locale: 'es-CO' });
p.on('response', async (r) => { if (r.url().includes('54321')) console.log(r.status(), r.request().method(), r.url().slice(0, 100), r.status() >= 400 ? (await r.text().catch(() => '')).slice(0, 200) : ''); });
p.on('requestfailed', (r) => console.log('FAILED', r.url(), r.failure()?.errorText));
await p.goto('http://127.0.0.1:8080/');
await p.waitForSelector('flt-semantics-placeholder', { state: 'attached' });
await p.locator('flt-semantics-placeholder').dispatchEvent('click');
await p.waitForTimeout(800);
await p.getByRole('button', { name: 'Crear cuenta gratis' }).click();
await p.waitForTimeout(800);
for (const [l, v] of [['Nombre visible', 'X'], ['Correo electrónico', `x${Date.now()}@e2e.co`], ['Contraseña', 'Clave-segura-123']]) { const e = p.locator(`input[aria-label="${l}"]`); await e.click(); await e.fill(v); }
await p.getByRole('checkbox').click();
await p.getByRole('button', { name: 'Crear cuenta', exact: true }).click();
await p.waitForTimeout(3000);
await b.close();
