#!/usr/bin/env node
'use strict';
// Creates or updates a game's one-time product on Google Play from
// Monetization/iap/<productId>.json (written by play.py), straight through
// the Android Publisher API: gplay's `iap apply` lists the catalogue first
// and can't read an empty one ("decode response: unexpected end of JSON
// input"), so it can't create the first product. Once the product exists,
// Tools/Play/play.js's `product` step keeps it.
//
// The game runs it through a two-line product.js in its Play directory
// (PLAY_DIR, beside listing.json):
//
//   node Tools/guard.js 12 -- node <Play dir>/product.js           # the plan
//   node Tools/guard.js 12 -- node <Play dir>/product.js --send    # make it so
//   node Tools/guard.js 12 -- node <Play dir>/product.js --verify  # read it back against the file
//
// With --reward, the same for a pre-registration reward (listing.json
// `reward`: `productId`, `purchaseOptionId`, `listings`).
//
// For a game with more than listing.json's one product:
//
//   node <Play dir>/product.js --file <body.json> [--send|--verify]
//       the same for a whole oneTimeProduct body (its productId, listings and
//       purchaseOptions) in place of the product's file; a product that
//       exists keeps its listings when the body has none.
//   node <Play dir>/product.js --get <productId>
//       prints the product as Play holds it (JSON), or {"missing": true}.
//
// The plan reads Play only: the product as it stands (if any), and Play's own
// conversion of the file's US price for new regions (pricing:convertRegionPrices,
// which computes and changes nothing), whose answer names the current regions
// version and the currency of every region, so a region or currency Play
// wouldn't take shows up here rather than in a failed send. --send then:
//
//   1. monetization.onetimeproducts.patch with allowMissing: the listings and
//      the one purchase option, every region at a fixed price (no automatic
//      conversion), new regions at the file's fixed USD and EUR prices;
//   2. purchaseOptions:batchUpdateStates: activates the purchase option.
//
// Credentials are gplay's: GPLAY_SERVICE_ACCOUNT (a path or the JSON) when
// set, else the service account gplay keeps in the login keychain (service
// "gplay", account = its active account). The key is read into memory to sign
// one token and never written or printed.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

if (!process.env.PLAY_DIR) {
  console.error('Set PLAY_DIR to the game\'s Play directory (its product.js does).');
  process.exit(2);
}
const HERE = path.resolve(process.env.PLAY_DIR);
const SOURCE = JSON.parse(fs.readFileSync(path.join(HERE, 'listing.json'), 'utf8'));
const PACKAGE = SOURCE.package;
// --reward: Play's pre-registration reward (listing.json `reward`), which
// Play grants free to whoever pre-registered and the game never sells. It
// is built from the product's file (the same regions at the same prices,
// so it is no cheaper way in) with its own id, purchase option and copy.
const REWARD = process.argv.includes('--reward');
const argument = (flag) => {
  const at = process.argv.indexOf(flag);
  return at >= 0 ? process.argv[at + 1] : undefined;
};
// --file: a whole product body of the game's own; --get: read one product.
const BODY_FILE = argument('--file');
const GET = argument('--get');
// Those two need only listing.json's package, not its one product.
const productFile = () => path.join(HERE, 'Monetization', 'iap', `${SOURCE.product.productId}.json`);
const PRODUCT_ID = GET ?? (BODY_FILE ? JSON.parse(fs.readFileSync(BODY_FILE, 'utf8')).productId
  : REWARD ? SOURCE.reward.productId : SOURCE.product.productId);
const FILE = GET ? undefined : BODY_FILE ?? productFile();
const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3';
const send = process.argv.includes('--send');

function serviceAccount() {
  const env = process.env.GPLAY_SERVICE_ACCOUNT;
  if (env) return JSON.parse(env.trim().startsWith('{') ? env : fs.readFileSync(env, 'utf8'));
  const status = JSON.parse(execFileSync('gplay', ['auth', 'status', '--output', 'json'], { encoding: 'utf8' }));
  let secret = execFileSync('security', ['find-generic-password', '-s', 'gplay', '-a', status.name, '-w'], { encoding: 'utf8' }).trim();
  if (!secret.startsWith('{')) {
    // go-keyring stores some values base64-encoded behind a prefix.
    secret = Buffer.from(secret.replace(/^go-keyring-base64:/, ''), 'base64').toString('utf8');
  }
  return JSON.parse(secret);
}

async function token() {
  const account = serviceAccount();
  const now = Math.floor(Date.now() / 1000);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: account.token_uri || 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), account.private_key).toString('base64url');
  const response = await fetch(account.token_uri || 'https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${signature}` }),
  });
  const body = await response.json();
  if (!body.access_token) throw new Error(`no access token: ${JSON.stringify(body).slice(0, 300)}`);
  return body.access_token;
}

async function call(bearer, method, url, body) {
  const response = await fetch(`${API}/${url}`, {
    method,
    headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { error: `${method} ${url}: ${text.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 200)}` };
  }
  return { status: response.status, body: parsed };
}

const amount = (money) => Number(money.units) + (money.nanos ?? 0) / 1e9;

function readProduct() {
  const product = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  if (!REWARD) return product;
  product.productId = PRODUCT_ID;
  product.listings = Object.entries(SOURCE.reward.listings)
    .map(([languageCode, { title, description }]) => ({ languageCode, title, description }));
  product.purchaseOptions = product.purchaseOptions.slice(0, 1)
    .map((option) => ({ ...option, purchaseOptionId: SOURCE.reward.purchaseOptionId }));
  return product;
}

async function main() {
  const product = readProduct();
  const option = product.purchaseOptions[0];
  const regions = option.regionalPricingAndAvailabilityConfigs;
  const bearer = await token();

  // Play's own conversion of the US price: its regions version and every
  // region's currency, to check the file against before anything is sent.
  const { currencyCode, units, nanos } = option.newRegionsConfig.usdPrice;
  const converted = await call(bearer, 'POST', `applications/${PACKAGE}/pricing:convertRegionPrices`,
    { price: { currencyCode, units, nanos } });
  if (converted.status !== 200) throw new Error(`convertRegionPrices: ${converted.status} ${JSON.stringify(converted.body).slice(0, 400)}`);
  const version = converted.body.regionVersion?.version;
  const play = converted.body.convertedRegionPrices ?? {};
  const problems = [];
  for (const config of regions) {
    const known = play[config.regionCode];
    if (!known) problems.push(`${config.regionCode}: not a region Play prices in version ${version}`);
    else if (known.price.currencyCode !== config.price.currencyCode) {
      problems.push(`${config.regionCode}: Play bills ${known.price.currencyCode}, the file says ${config.price.currencyCode}`);
    }
  }
  const missing = Object.keys(play).filter((code) => !regions.some((c) => c.regionCode === code));

  const existing = await call(bearer, 'GET', `applications/${PACKAGE}/oneTimeProducts/${PRODUCT_ID}`);
  const exists = existing.status === 200;
  if (!exists && existing.status !== 404) throw new Error(`reading the product: ${existing.status} ${JSON.stringify(existing.body).slice(0, 300)}`);

  if (!(product.listings ?? []).length) {
    if (!exists) problems.push('a new product needs listings');
    product.listings = exists ? existing.body.listings ?? [] : [];
  }
  console.log(`Product ${PRODUCT_ID} on ${PACKAGE}: ${exists ? 'exists, would be updated' : 'missing, would be created'}`);
  console.log(`  listings: ${product.listings.length} languages (${product.listings.map((l) => l.languageCode).join(', ')})`);
  console.log(`  purchase option "${option.purchaseOptionId}": buy, legacy-compatible, one at a time, then activated`);
  console.log(`  regions: ${regions.length} at fixed prices; new regions at ${amount(option.newRegionsConfig.usdPrice)} USD / ${amount(option.newRegionsConfig.eurPrice)} EUR`);
  for (const code of ['US', 'GB', 'DE', 'JP', 'IN', 'BR', 'AR']) {
    const config = regions.find((c) => c.regionCode === code);
    if (config) console.log(`    ${code}  ${amount(config.price).toLocaleString('en')} ${config.price.currencyCode}`);
  }
  console.log(`  regions version: ${version} (from Play's own price conversion)`);
  if (missing.length) console.log(`  Play regions the file leaves unavailable: ${missing.join(', ')}`);
  if (problems.length) {
    console.log(`  problems (${problems.length}):\n    ${problems.join('\n    ')}`);
    throw new Error('the product file disagrees with Play; nothing was sent');
  }
  if (!send) {
    console.log('Plan only. Pass --send to create it.');
    return;
  }

  const body = JSON.parse(JSON.stringify(product));
  for (const o of body.purchaseOptions) delete o.state;
  const query = new URLSearchParams({
    updateMask: 'listings,purchaseOptions',
    allowMissing: 'true',
    'regionsVersion.version': version,
  });
  const patched = await call(bearer, 'PATCH', `applications/${PACKAGE}/onetimeproducts/${PRODUCT_ID}?${query}`, body);
  if (patched.status !== 200) throw new Error(`creating the product: ${patched.status} ${JSON.stringify(patched.body).slice(0, 800)}`);
  console.log(`${exists ? 'Updated' : 'Created'} ${PRODUCT_ID}.`);

  const activated = await call(bearer, 'POST', `applications/${PACKAGE}/oneTimeProducts/${PRODUCT_ID}/purchaseOptions:batchUpdateStates`, {
    requests: [{ activatePurchaseOptionRequest: { packageName: PACKAGE, productId: PRODUCT_ID, purchaseOptionId: option.purchaseOptionId } }],
  });
  if (activated.status !== 200) throw new Error(`activating the purchase option: ${activated.status} ${JSON.stringify(activated.body).slice(0, 800)}`);
  console.log(`Purchase option "${option.purchaseOptionId}" is active.`);
}

if (GET) {
  // Read-only: one product as Play holds it.
  (async () => {
    const live = await call(await token(), 'GET', `applications/${PACKAGE}/oneTimeProducts/${GET}`);
    if (live.status === 404) return console.log(JSON.stringify({ missing: true }));
    if (live.status !== 200) throw new Error(`reading ${GET}: ${live.status} ${JSON.stringify(live.body).slice(0, 300)}`);
    console.log(JSON.stringify(live.body));
  })().catch((error) => { console.error(error.message); process.exit(1); });
} else if (process.argv.includes('--verify')) {
  // Read-only: the product as Play holds it, against the file.
  (async () => {
    const bearer = await token();
    const live = await call(bearer, 'GET', `applications/${PACKAGE}/oneTimeProducts/${PRODUCT_ID}`);
    if (live.status !== 200) throw new Error(`reading the product: ${live.status}`);
    const want = readProduct().purchaseOptions[0];
    const got = live.body.purchaseOptions?.[0] ?? {};
    const held = new Map((got.regionalPricingAndAvailabilityConfigs ?? []).map((c) => [c.regionCode, c]));
    const differ = want.regionalPricingAndAvailabilityConfigs.filter((c) => {
      const h = held.get(c.regionCode);
      return !h || h.price.currencyCode !== c.price.currencyCode || amount(h.price) !== amount(c.price) || h.availability !== c.availability;
    });
    console.log(`${PRODUCT_ID}: option "${got.purchaseOptionId}" ${got.state}, ${held.size} regions, ${live.body.listings?.length ?? 0} listings`);
    console.log(differ.length ? `differs from the file: ${differ.map((c) => c.regionCode).join(', ')}` : 'every region matches the file');
  })().catch((error) => { console.error(error.message); process.exit(1); });
} else main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
