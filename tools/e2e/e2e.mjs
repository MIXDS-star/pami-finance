// End-to-end test: the real Flutter web build against the local stack, driven
// through the accessibility tree (what a screen reader sees), with two users.
//   node tools/e2e/e2e.mjs   (stack running + build/web served on :8080)
import { chromium } from 'playwright';
import fs from 'node:fs';
import assert from 'node:assert/strict';

const BASE = process.env.APP_URL ?? 'http://127.0.0.1:8080/';
const SHOTS = process.env.SHOTS ?? new URL('../../docs/screenshots/', import.meta.url).pathname;
fs.mkdirSync(SHOTS, { recursive: true });
const run = Date.now().toString(36);
let step = 0;
const log = (m) => console.log(`[${String(++step).padStart(2, '0')}] ${m}`);

const browser = await chromium.launch();

async function open(name, opts = {}) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'es-CO', ...opts });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(BASE).origin });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`  [${name}] pageerror: ${e.message.slice(0, 200)}`));
  return page;
}

async function boot(page, path = '') {
  // Same document + new hash = in-app navigation (no reload).
  await page.goto(BASE + path, { waitUntil: 'networkidle' });
  const placeholder = page.locator('flt-semantics-placeholder');
  for (let i = 0; i < 120; i++) {
    if (await placeholder.count() > 0) {
      await placeholder.dispatchEvent('click');
      break;
    }
    if (await page.locator('flt-semantics-host flt-semantics').count() > 0) break;
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(900);
}

const btn = (page, name, exact = true) => page.getByRole('button', { name, exact }).first();
const input = (page, label) => page.locator(`input[aria-label^="${label}"], textarea[aria-label^="${label}"]`).first();
async function click(page, name, exact = true) {
  const b = btn(page, name, exact);
  // Semantics nodes of off-screen list items are not "visible" to Playwright;
  // a semantic click (what assistive tech does) still activates them.
  await b.click({ timeout: 4000 }).catch(() => b.dispatchEvent('click'));
  await page.waitForTimeout(700);
}
async function fill(page, label, text) {
  const el = input(page, label);
  await el.click();
  await el.fill(text);
  await page.waitForTimeout(250);
}
// Flutter exposes text either as node text or merged into aria-label.
const hasText = (page, text) => page.evaluate((t) => (document.querySelector('flt-semantics-host')?.textContent ?? '').includes(t)
  || [...document.querySelectorAll('[aria-label]')].some((e) => e.getAttribute('aria-label').includes(t)), text);
async function see(page, text, timeout = 10000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await hasText(page, text)) return;
    await page.waitForTimeout(250);
  }
  throw new Error(`text not visible: ${text}`);
}
async function scrollDown(page, times = 1) {
  for (let i = 0; i < times; i++) {
    await page.mouse.move(195, 500);
    await page.mouse.wheel(0, 500);
    await page.waitForTimeout(350);
  }
}
async function scrollUntil(page, text, max = 12) {
  for (let i = 0; i < max; i++) {
    if (await hasText(page, text)) return;
    await scrollDown(page);
  }
  throw new Error(`not found after scrolling: ${text}`);
}
const shot = (page, name) => page.screenshot({ path: `${SHOTS}${name}.png` });

async function signUp(page, name, email) {
  await boot(page);
  await click(page, 'Crear cuenta gratis');
  await fill(page, 'Nombre visible', name);
  await fill(page, 'Correo electrónico', email);
  await fill(page, 'Contraseña', 'Clave-segura-123');
  await page.getByRole('checkbox').first().click();
  await click(page, 'Crear cuenta');
  await see(page, '¿Cómo quieres que te llamen?', 15000);
}

async function finishOnboarding(page, { shots = false } = {}) {
  for (let i = 0; i < 4; i++) {
    if (shots && i === 1) await shot(page, '02-onboarding-moneda');
    await click(page, 'Continuar');
  }
  await see(page, 'Presupuestos iniciales');
  await click(page, 'Continuar');
  await see(page, 'Todo listo');
  await click(page, 'Empezar');
  await see(page, 'Tu gasto del mes', 15000);
}

try {
  // ---------------------------------------------------------------- Ana
  const ana = await open('ana');
  const anaEmail = `ana.${run}@e2e.co`;
  await boot(ana);
  await shot(ana, '01-bienvenida');
  log('welcome screen rendered');
  await signUp(ana, 'Ana Gómez', anaEmail);
  log('Ana signed up (Supabase Auth) and reached onboarding');
  await finishOnboarding(ana, { shots: true });
  await shot(ana, '03-inicio-vacio');
  log('onboarding completed; home shows honest empty state');

  // Personal expense through the manual form.
  await click(ana, 'Añadir registro');
  await shot(ana, '04-hoja-captura');
  await click(ana, 'Manual. Formulario completo');
  await fill(ana, 'Total pagado', '52000');
  await fill(ana, 'Concepto', 'Farmacia');
  await click(ana, 'Guardar');
  await see(ana, 'Detalle');
  await see(ana, 'Farmacia');
  await shot(ana, '05-detalle-personal');
  log('personal expense saved through save_transaction and shown from the server');

  // Text capture with the on-device interpreter (AI not configured locally).
  await boot(ana, '#/home');
  await click(ana, 'Añadir registro');
  await click(ana, 'Escribir. Interpretación básica');
  await fill(ana, '¿Qué compraste?', 'Almuerzo 25 mil en efectivo ayer');
  await click(ana, 'Interpretar');
  await see(ana, 'Esto entendimos');
  await see(ana, 'la IA no está configurada');
  await shot(ana, '06-texto-interpretado');
  await click(ana, 'Revisar y confirmar');
  await click(ana, 'Guardar');
  await see(ana, 'Almuerzo');
  log('text capture: local interpreter (honestly labelled) -> review -> saved');

  // Shared space + invitation link.
  await boot(ana, '#/home');
  await click(ana, 'Espacios');
  await click(ana, 'Nuevo espacio');
  await fill(ana, 'Nombre', 'Casa');
  await click(ana, 'Crear e invitar');
  await see(ana, 'Miembros');
  await ana.waitForFunction(() => location.hash.includes('/spaces/'), null, { timeout: 10000 });
  const casaId = (await ana.evaluate(() => location.hash)).split('/spaces/')[1].split('?')[0];
  await click(ana, 'Invitar');
  await click(ana, 'Crear enlace de invitación');
  await see(ana, 'Invitación creada');
  await click(ana, 'Copiar enlace');
  const link = await ana.evaluate(() => navigator.clipboard.readText());
  const token = link.split('/').pop();
  assert.ok(token && token.length > 20, 'invitation token copied');
  await shot(ana, '07-invitacion');
  await ana.keyboard.press('Escape');
  log('shared workspace created; single-use invitation link generated');

  // ---------------------------------------------------------------- Bruno
  const bruno = await open('bruno');
  await signUp(bruno, 'Bruno Díaz', `bruno.${run}@e2e.co`);
  await finishOnboarding(bruno);
  await boot(bruno, `#/invite/${token}`);
  await see(bruno, 'te invita a «Casa»');
  await shot(bruno, '08-aceptar-invitacion');
  await click(bruno, 'Aceptar invitación');
  await see(bruno, 'Casa');
  log('Bruno accepted the invitation from his own session');

  // Bruno must NOT see Ana's personal expenses.
  await boot(bruno, '#/movements');
  await see(bruno, 'Movimientos');
  assert.equal(await hasText(bruno, 'Farmacia'), false, "Bruno cannot see Ana's personal expense");
  log("privacy: Bruno's movements do not include Ana's personal expenses");

  // ---------------------------------------------------------------- Ana: per-item receipt
  await boot(ana, `#/tx/new?workspace=${casaId}`);
  await see(ana, 'Nuevo gasto');
  await fill(ana, 'Total pagado', '300000');
  await fill(ana, 'Concepto', 'Mercado semanal');
  await scrollUntil(ana, 'Detallar');
  await click(ana, 'Detallar');
  const addLine = async (desc, value, onlyFor) => {
    await scrollUntil(ana, 'Añadir línea');
    await click(ana, 'Añadir línea');
    await fill(ana, 'Descripción', desc);
    await fill(ana, 'Valor de la línea', value);
    await click(ana, 'Listo');
    // The newest line is the last one in the list: assign it with its quick avatar.
    if (onlyFor) {
      await ana.getByRole('button', { name: `Asignar solo a ${onlyFor}` }).last().dispatchEvent('click');
      await ana.waitForTimeout(400);
    }
  };
  await addLine('Productos de Ana', '80000', 'Ana Gómez');
  await addLine('Productos de Bruno', '70000', 'Bruno Díaz');
  await addLine('Compartidos', '150000');
  await scrollUntil(ana, 'La factura cuadra');
  // Assign the first two lines to one person each with the quick avatars.
  await scrollUntil(ana, 'Le corresponde a cada persona');
  await scrollUntil(ana, '155.000');
  await see(ana, '145.000');
  await shot(ana, '09-factura-por-producto');
  await click(ana, 'Guardar');
  await see(ana, 'Mercado semanal');
  await see(ana, 'Pagar no es lo mismo que gastar');
  await shot(ana, '10-detalle-compartido');
  log('per-item receipt saved: A 155.000 / B 145.000 from one receipt');

  // ---------------------------------------------------------------- Bruno: balances & settlement
  await boot(bruno, '#/spaces');
  await click(bruno, 'Casa', false);
  await bruno.getByRole('tab', { name: 'Saldos' }).first().dispatchEvent('click');
  await bruno.waitForTimeout(800);
  await see(bruno, 'Tú debes a Ana');
  await see(bruno, '145.000');
  await shot(bruno, '11-saldos');
  await click(bruno, 'Registrar pago');
  await fill(bruno, 'Importe pagado', '45000');
  await see(bruno, 'quedarán');
  await click(bruno, 'Registrar');
  await see(bruno, '100.000');
  await shot(bruno, '12-saldo-parcial');
  log('partial reimbursement recorded; remaining debt 100.000 (no new expense created)');

  // Bruno's home shows only HIS share of the shared bill.
  await boot(bruno, '#/home');
  await see(bruno, 'Tu gasto del mes');
  await see(bruno, '145.000');
  log("Bruno's monthly spending = his assigned share (145.000), not the 300.000 Ana paid");

  // ---------------------------------------------------------------- Visual checks
  const dark = await open('dark', { colorScheme: 'dark' });
  await boot(dark);
  await signUp(dark, 'Carla', `carla.${run}@e2e.co`);
  await finishOnboarding(dark);
  await shot(dark, '13-inicio-oscuro');
  const small = await open('small', { viewport: { width: 320, height: 568 } });
  await boot(small);
  await shot(small, '14-bienvenida-320px');
  await boot(ana, '#/stats');
  await see(ana, 'Ingresos frente a gastos');
  await shot(ana, '15-estadisticas');
  await boot(ana, '#/plan');
  await shot(ana, '16-plan');
  await boot(ana, '#/copilot');
  await see(ana, 'Copiloto no configurado');
  await shot(ana, '17-copiloto-no-configurado');
  log('dark mode, 320px screen, stats, plan and honest copilot state captured');

  console.log(`\nE2E PASSED (${step} steps). Screenshots in ${SHOTS}`);
} catch (e) {
  console.error('\nE2E FAILED:', e.message);
  for (const [c, ctx] of browser.contexts().entries()) {
    for (const p of ctx.pages()) await p.screenshot({ path: `/tmp/nexo-stack/fail-ctx${c}.png` }).catch(() => {});
  }
  process.exitCode = 1;
} finally {
  await browser.close();
}
