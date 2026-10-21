import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ locale: 'es-CO', viewport: { width: 390, height: 844 } });
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
console.log(await p.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => `${e.getAttribute('role')}|${e.getAttribute('aria-label')}|${[...e.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent).join('')}`).filter(x => x !== 'null|null|').join('\n')));
await b.close();
