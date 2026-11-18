// Browser-level pin for the PRF eval input format (run separately from npm
// test): drives the REAL client/web/device_binding.mjs against Chromium's
// WebAuthn with a virtual authenticator. Before the fix, prf.eval was passed
// as a bare BufferSource and Chromium failed dict parsing on the required
// `first` member ("Required member is undefined") before any authenticator
// round-trip. With the spec format the call must reach the authenticator and
// surface the HONEST prf_unavailable outcome (the virtual authenticator does
// not compute PRF results). Usage:
//   node tools/prf-browser-check.mjs node_modules/playwright-core [edge|chromium]
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const webRoot = path.resolve(serverRoot, '..', 'client', 'web');
const require2 = createRequire(import.meta.url);
const pkgDir = path.dirname(require2.resolve('playwright-core/package.json'));
const { chromium } = await import(pathToFileURL(path.join(pkgDir, 'index.mjs')));

const server = http.createServer(async (req, res) => {
  const file = req.url === '/' ? '/probe.html' : req.url;
  try {
    const body = file === '/probe.html' ? `<!doctype html><html><body><script type="module">
window.check = async () => {
  const { createDeviceBinding, bindingErrorText } = await import('/device_binding.mjs');
  try {
    const { binding, passphrase } = await createDeviceBinding('probe_user');
    return { ok: true, method: binding.method, passphraseLength: passphrase.length };
  } catch (error) {
    return { ok: false, message: error.message, mapped: bindingErrorText(error) };
  }
};
</script></body></html>`
      : await fs.readFile(path.join(webRoot, file));
    res.writeHead(200, { 'content-type': file.endsWith('.mjs') ? 'text/javascript' : 'text/html' });
    res.end(body);
  } catch { res.writeHead(404); res.end('not found'); }
}).listen(0);
const origin = `http://localhost:${server.address().port}`;

const engine = process.argv[3] || 'edge';
const browser = await chromium.launch({ channel: engine === 'edge' ? 'msedge' : undefined, headless: true });
try {
  const page = await browser.newPage();
  await page.goto(origin);
  const session = await page.context().newCDPSession(page);
  await session.send('WebAuthn.enable');
  await session.send('WebAuthn.addVirtualAuthenticator', { options: {
    protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
  const result = await page.evaluate(() => window.check());
  // The verdict is about the INPUT FORMAT: the Chromium dict-parsing TypeError
  // would surface here verbatim if prf.eval ever regresses to a bare BufferSource.
  assert.ok(!/Required member is undefined/.test(result.message || ''),
    `PRF eval input format regressed: ${result.message}`);
  if (result.ok) {
    assert.equal(result.method, 'prf');
    assert.ok(result.passphraseLength >= 16);
    console.log('PASS virtual authenticator produced PRF results; binding created');
  } else {
    assert.equal(result.message, 'prf_unavailable');
    assert.ok(result.mapped && result.mapped.includes('PRF') && !result.mapped.includes('Failed to execute'));
    console.log('PASS input format accepted; honest prf_unavailable fallback surfaced:', result.mapped);
  }
} finally {
  await browser.close();
  server.close();
}
