'use strict';
// product.js against a stubbed Play: node --test Tools/Pricing/product.test.js
// The service account is a throwaway key in GPLAY_SERVICE_ACCOUNT, so the
// keychain is never read, and fetch is replaced before product.js runs.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const TOOL = path.join(__dirname, 'product.js');

// Answers Play's calls and records them in $RECORD.
const STUB = `
const fs = require('fs');
const calls = [];
globalThis.fetch = async (url, init = {}) => {
  calls.push({ url: String(url), method: init.method || 'GET', body: init.body ? String(init.body) : null });
  fs.writeFileSync(process.env.RECORD, JSON.stringify(calls));
  const reply = (status, body) => ({ status, json: async () => body, text: async () => JSON.stringify(body) });
  if (String(url).includes('/token')) return reply(200, { access_token: 'stub' });
  if (String(url).includes('convertRegionPrices')) {
    return reply(200, { regionVersion: { version: '2026/01' }, convertedRegionPrices: {
      US: { price: { currencyCode: 'USD' } }, DE: { price: { currencyCode: 'EUR' } }, FR: { price: { currencyCode: 'EUR' } } } });
  }
  if (init.method === undefined || init.method === 'GET') return reply(404, {});
  return reply(200, {});
};
`;

function game({ currency = 'EUR' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'product-'));
  const money = (units, nanos, code) => ({ currencyCode: code, units: String(units), nanos });
  fs.writeFileSync(path.join(dir, 'listing.json'), JSON.stringify({
    package: 'com.example.game',
    product: { productId: 'com.example.full', listings: {} },
    reward: { productId: 'com.example.reward', purchaseOptionId: 'reward', listings: { 'en-US': { title: 'Gift', description: 'Free' } } },
  }));
  fs.mkdirSync(path.join(dir, 'Monetization', 'iap'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'Monetization', 'iap', 'com.example.full.json'), JSON.stringify({
    packageName: 'com.example.game',
    productId: 'com.example.full',
    listings: [{ languageCode: 'en-US', title: 'Full', description: 'All of it' }],
    purchaseOptions: [{
      purchaseOptionId: 'buy',
      state: 'ACTIVE',
      regionalPricingAndAvailabilityConfigs: [
        { regionCode: 'US', price: money(4, 990000000, 'USD'), availability: 'AVAILABLE' },
        { regionCode: 'DE', price: money(4, 490000000, currency), availability: 'AVAILABLE' },
      ],
      newRegionsConfig: { usdPrice: money(4, 990000000, 'USD'), eurPrice: money(4, 990000000, 'EUR'), availability: 'AVAILABLE' },
    }],
  }));
  return dir;
}

function run(dir, ...args) {
  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const stub = path.join(dir, 'stub.js');
  fs.writeFileSync(stub, STUB);
  const record = path.join(dir, 'calls.json');
  const result = spawnSync(process.execPath, ['--require', stub, TOOL, ...args], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PLAY_DIR: dir,
      RECORD: record,
      GPLAY_SERVICE_ACCOUNT: JSON.stringify({
        client_email: 'stub@example.invalid',
        token_uri: 'https://example.invalid/token',
        private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
      }),
    },
  });
  return { ...result, calls: fs.existsSync(record) ? JSON.parse(fs.readFileSync(record, 'utf8')) : [] };
}

test('the plan reads Play only, converting the file\'s own US price', () => {
  const { status, stdout, calls } = run(game());
  assert.strictEqual(status, 0);
  assert.match(stdout, /Product com\.example\.full on com\.example\.game: missing, would be created/);
  assert.match(stdout, /Play regions the file leaves unavailable: FR/);
  assert.match(stdout, /Plan only\./);
  assert.deepStrictEqual(calls.map((c) => c.method), ['POST', 'POST', 'GET']);
  const conversion = calls.find((c) => c.url.includes('convertRegionPrices'));
  assert.deepStrictEqual(JSON.parse(conversion.body).price, { currencyCode: 'USD', units: '4', nanos: 990000000 });
});

test('a currency Play wouldn\'t bill stops it before anything is sent', () => {
  const { status, stdout, stderr, calls } = run(game({ currency: 'USD' }), '--send');
  assert.strictEqual(status, 1);
  assert.match(stdout, /DE: Play bills EUR, the file says USD/);
  assert.match(stderr, /nothing was sent/);
  assert.ok(!calls.some((c) => c.method === 'PATCH'));
});

test('--reward plans the reward from the product\'s file', () => {
  const { status, stdout } = run(game(), '--reward');
  assert.strictEqual(status, 0);
  assert.match(stdout, /Product com\.example\.reward on com\.example\.game/);
  assert.match(stdout, /listings: 1 languages \(en-US\)/);
});

test('it needs PLAY_DIR', () => {
  const result = spawnSync(process.execPath, [TOOL], { encoding: 'utf8', env: { ...process.env, PLAY_DIR: '' } });
  assert.strictEqual(result.status, 2);
  assert.match(result.stderr, /PLAY_DIR/);
});
