import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ locale: 'es-CO', viewport: { width: 390, height: 844 } });
let trace = false;
p.on('response', async (r) => { if (trace && r.url().includes('54321')) console.log(r.status(), r.request().method(), r.url().slice(30, 120), r.status() >= 400 ? (await r.text().catch(() => '')).slice(0, 300) : ''); });
p.on('pageerror', (e) => console.log('pageerror', e.message.slice(0, 300)));
p.on('console', (m) => { if (m.type() === 'error') console.log('console', m.text().slice(0, 300)); });
await p.goto('http://127.0.0.1:8080/');
await p.waitForSelector('flt-semantics-placeholder', { state: 'attached' });
await p.locator('flt-semantics-placeholder').dispatchEvent('click');
await p.waitForTimeout(800);
await p.getByRole('button', { name: 'Crear cuenta gratis' }).click();
await p.waitForTimeout(800);
for (const [l, v] of [['Nombre visible', 'X'], ['Correo electrónico', `x${Date.now()}@e2e.co`], ['Contraseña', 'Clave-segura-123']]) { const e = p.locator(`input[aria-label="${l}"]`); await e.click(); await e.fill(v); }
await p.getByRole('checkbox').click();
await p.getByRole('button', { name: 'Crear cuenta', exact: true }).click();
await p.waitForTimeout(2500);
for (let i = 0; i < 5; i++) { await p.getByRole('button', { name: 'Continuar', exact: true }).click(); await p.waitForTimeout(600); }
trace = true;
await p.getByRole('button', { name: 'Empezar', exact: true }).click();
await p.waitForTimeout(4000);
console.log('hash', await p.evaluate(() => location.hash));
await b.close();
