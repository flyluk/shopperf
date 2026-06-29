import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Counter, Trend } from 'k6/metrics';

// 409 = user already exists during setup re-runs; 204 = cart delete.
http.setResponseCallback(http.expectedStatuses(200, 201, 204, 409));

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const TEST_PASSWORD = __ENV.TEST_PASSWORD || 'k6pass123';
const TEST_EMAIL_DOMAIN = __ENV.TEST_EMAIL_DOMAIN || 'example.com';
const TEST_RUN_ID = __ENV.TEST_ID || __ENV.TEST_RUN_ID || String(Date.now());
const TEST_EMAIL_PREFIX_BASE = __ENV.TEST_EMAIL_PREFIX_BASE || 'k6user';
// Always tied to testid: k6user-{runId}-vu{N}@domain
const TEST_EMAIL_PREFIX = `${TEST_EMAIL_PREFIX_BASE}-${TEST_RUN_ID}`;

const K6_VUS = Number(__ENV.K6_VUS || 5);
const K6_RAMP_UP = __ENV.K6_RAMP_UP || '5s';
const K6_HOLD = __ENV.K6_HOLD || '25s';
const K6_RAMP_DOWN = __ENV.K6_RAMP_DOWN || '5s';
const K6_SLEEP = Number(__ENV.K6_SLEEP || 0);
const K6_HTTP_TIMEOUT = __ENV.K6_HTTP_TIMEOUT || '10s';
// add_remove restores stock via API delete (sustainable load). add = stock runs out → 400s.
const K6_CART_MODE = (__ENV.K6_CART_MODE || 'add_remove').toLowerCase();
const K6_NO_CONNECTION_REUSE = __ENV.K6_NO_CONNECTION_REUSE === 'true' || __ENV.K6_NO_CONNECTION_REUSE === '1';
const K6_CART_RETRIES = Number(__ENV.K6_CART_RETRIES || 1);

const checkoutErrors = new Counter('shop_checkout_errors');
const cartFailures = new Counter('shop_cart_failures');
const failAddTimeout = new Counter('shop_fail_add_timeout');
const failRemoveTimeout = new Counter('shop_fail_remove_timeout');
const failAdd400Stock = new Counter('shop_fail_add_400_stock');
const failAdd5xx = new Counter('shop_fail_add_5xx');
const failRemove5xx = new Counter('shop_fail_remove_5xx');
const failAddOther = new Counter('shop_fail_add_other');
const failRemoveOther = new Counter('shop_fail_remove_other');
const failAddNoItemId = new Counter('shop_fail_add_no_item_id');

const FAILURE_COUNTERS = {
  add_timeout: failAddTimeout,
  remove_timeout: failRemoveTimeout,
  add_400_stock: failAdd400Stock,
  add_5xx: failAdd5xx,
  remove_5xx: failRemove5xx,
  add_no_item_id: failAddNoItemId,
};

const iterationDuration = new Trend('shop_iteration_ms', true);
// Successful cart adds only — excludes timeouts and stale-socket ~29s outliers.
const cartAddOkMs = new Trend('shop_cart_add_ok_ms', true);

function recordCartFailure(reason, status) {
  const tags = { reason };
  if (status !== undefined && status !== null && status !== '') {
    tags.status = String(status);
  }
  cartFailures.add(1, tags);
  const counter = FAILURE_COUNTERS[reason];
  if (counter) {
    counter.add(1);
  } else if (reason.startsWith('add_')) {
    failAddOther.add(1);
  } else if (reason.startsWith('remove_')) {
    failRemoveOther.add(1);
  }
}

function classifyHttpFailure(res, step) {
  if (!res || res.status === 0) {
    return `${step}_timeout`;
  }
  if (res.status === 400) {
    return `${step}_400_stock`;
  }
  if (res.status >= 500) {
    return `${step}_5xx`;
  }
  if (res.status >= 400) {
    return `${step}_4xx_${res.status}`;
  }
  return `${step}_status_${res.status}`;
}

function responseDetail(res) {
  if (!res) {
    return 'no response';
  }
  if (res.error) {
    return `error=${res.error}`;
  }
  if (res.body && res.body.length > 0 && res.body.length <= 200) {
    return `body=${res.body}`;
  }
  if (res.body && res.body.length > 200) {
    return `body=${res.body.slice(0, 200)}...`;
  }
  return 'no body';
}

function thresholdRule(stat, envKey, defaultMs) {
  const raw = __ENV[envKey];
  if (raw === 'off' || raw === 'false' || raw === 'disable') {
    return null;
  }
  const ms = raw || (defaultMs !== undefined ? String(defaultMs) : null);
  if (!ms) {
    return null;
  }
  return `${stat}<${ms}`;
}

function buildDurationThresholds(envPrefix, defaults = {}) {
  const rules = [
    thresholdRule('avg', `${envPrefix}_AVG_MS`, defaults.avg),
    thresholdRule('min', `${envPrefix}_MIN_MS`, defaults.min),
    thresholdRule('max', `${envPrefix}_MAX_MS`, defaults.max),
    thresholdRule('p(95)', `${envPrefix}_P95_MS`, defaults.p95),
    thresholdRule('p(99)', `${envPrefix}_P99_MS`, defaults.p99),
  ];
  return rules.filter(Boolean);
}

const httpDurationThresholds = buildDurationThresholds('K6_THRESHOLD_HTTP', {
  avg: 500,
  max: 30000,
  p95: 2000,
  p99: 5000,
});

const iterationThresholds = buildDurationThresholds('K6_THRESHOLD_ITER', {
  avg: 500,
  max: 30000,
  p95: 2000,
  p99: 5000,
});

function withEndpointThresholds(base, name, envPrefix, defaults) {
  const rules = buildDurationThresholds(envPrefix, defaults);
  if (rules.length) {
    base[name] = rules;
  }
  return base;
}

function buildFailedThreshold() {
  const raw = __ENV.K6_THRESHOLD_HTTP_FAILED;
  if (raw === 'off' || raw === 'false' || raw === 'disable') {
    return {};
  }
  const rate = raw || '0.05';
  return { checks: [`rate>${1 - Number(rate)}`] };
}

const thresholds = withEndpointThresholds(
  {
    ...buildFailedThreshold(),
    ...(httpDurationThresholds.length
      ? { 'http_req_duration{expected_response:true}': httpDurationThresholds }
      : {}),
    ...(iterationThresholds.length ? { shop_iteration_ms: iterationThresholds, shop_cart_add_ok_ms: iterationThresholds } : {}),
  },
  'http_req_duration{name:products_list}',
  'K6_THRESHOLD_PRODUCTS',
  { p95: 500 }
);
withEndpointThresholds(thresholds, 'http_req_duration{name:cart_add,expected_response:true}', 'K6_THRESHOLD_CART_ADD', { p95: 1000 });
withEndpointThresholds(thresholds, 'http_req_duration{name:cart_get}', 'K6_THRESHOLD_CART_GET', { p95: 500 });
withEndpointThresholds(thresholds, 'http_req_duration{name:cart_remove}', 'K6_THRESHOLD_CART_REMOVE', { p95: 500 });
withEndpointThresholds(thresholds, 'http_req_duration{name:auth_register}', 'K6_THRESHOLD_AUTH_REGISTER', { p95: 3000 });
withEndpointThresholds(thresholds, 'http_req_duration{name:auth_login}', 'K6_THRESHOLD_AUTH_LOGIN', { p95: 1000 });

export const options = {
  tags: {
    testid: TEST_RUN_ID,
  },
  // Omit max — one hung socket at test end can report ~29750ms while med/p95 stay ~10ms.
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)'],
  scenarios: {
    browse_and_cart: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: K6_RAMP_UP, target: K6_VUS },
        { duration: K6_HOLD, target: K6_VUS },
        { duration: K6_RAMP_DOWN, target: 0 },
      ],
      // Let in-flight requests finish during ramp-down (avoids ~29s interrupted outliers).
      gracefulRampDown: '2s',
      gracefulStop: '1s',
    },
  },
  thresholds,
  noConnectionReuse: K6_NO_CONNECTION_REUSE,
};

function jsonHeaders(token) {
  const headers = { 'Content-Type': 'application/json' };
  // Only force close when disabling reuse — otherwise k6 keep-alive cuts Docker→LAN TCP churn.
  if (K6_NO_CONNECTION_REUSE) {
    headers.Connection = 'close';
  }
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { headers, timeout: K6_HTTP_TIMEOUT };
}

function isRetryableResponse(res) {
  return !res || res.status === 0;
}

function cartPost(token, productId) {
  const params = { ...jsonHeaders(token), tags: { name: 'cart_add' } };
  const body = JSON.stringify({ product_id: productId, quantity: 1 });
  const url = `${BASE_URL}/api/cart/items`;
  let res = http.post(url, body, params);
  for (let attempt = 0; attempt < K6_CART_RETRIES && isRetryableResponse(res); attempt += 1) {
    res = http.post(url, body, params);
  }
  return res;
}

function vuEmail(vu) {
  return `${TEST_EMAIL_PREFIX}-vu${vu}@${TEST_EMAIL_DOMAIN}`;
}

function parseProducts(response) {
  if (!response.body || response.body.length === 0) {
    throw new Error(
      `GET /api/products failed: status=${response.status} error=${response.error || 'empty body'}`
    );
  }
  const body = response.json();
  return Array.isArray(body) ? body : (body.products || []);
}

function registerNewUser(vu) {
  const email = vuEmail(vu);

  const registerRes = http.post(
    `${BASE_URL}/api/auth/register`,
    JSON.stringify({ email, password: TEST_PASSWORD }),
    { ...jsonHeaders(), tags: { name: 'auth_register' } }
  );

  if (registerRes.status !== 201 && registerRes.status !== 409) {
    return null;
  }

  const loginRes = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ email, password: TEST_PASSWORD }),
    { ...jsonHeaders(), tags: { name: 'auth_login' } }
  );

  if (loginRes.status !== 200) {
    return null;
  }

  return loginRes.json('access_token');
}

function removeCartItem(token, cartItemId) {
  const params = { ...jsonHeaders(token), tags: { name: 'cart_remove' } };
  const url = `${BASE_URL}/api/cart/items/${cartItemId}`;
  let res = http.del(url, null, params);
  for (let attempt = 0; attempt < K6_CART_RETRIES && isRetryableResponse(res); attempt += 1) {
    res = http.del(url, null, params);
  }
  return res;
}

function pickProduct(products, vu, iter, offset) {
  const count = products.length;
  if (K6_CART_MODE === 'add_remove') {
    // One product per VU — less row lock contention; delete restores stock each iter.
    return products[(vu - 1) % count];
  }
  return products[(iter + vu + offset) % count];
}

function addToCart(token, products, vu, iter) {
  const count = products.length;
  const maxTries = K6_CART_MODE === 'add_remove' ? 1 : Math.min(count, 3);
  let lastRes = null;
  let lastProduct = null;

  for (let offset = 0; offset < maxTries; offset += 1) {
    const product = pickProduct(products, vu, iter, offset);
    lastProduct = product;
    const addRes = cartPost(token, product.id);
    lastRes = addRes;

    if (addRes.status === 200 || addRes.status === 201) {
      if (K6_CART_MODE === 'add_remove') {
        const cartItemId = addRes.json('id');
        let totalMs = addRes.timings.duration;
        if (!cartItemId) {
          const reason = 'add_no_item_id';
          recordCartFailure(reason, addRes.status);
          return { addRes, delRes: null, durationMs: totalMs, ok: false, failureReason: reason, productId: product.id };
        }
        const delRes = removeCartItem(token, cartItemId);
        totalMs += delRes.timings.duration;
        if (delRes.status !== 204 && delRes.status !== 200) {
          const reason = classifyHttpFailure(delRes, 'remove');
          recordCartFailure(reason, delRes.status);
          return {
            addRes,
            delRes,
            durationMs: totalMs,
            ok: false,
            failureReason: reason,
            productId: product.id,
            detail: responseDetail(delRes),
          };
        }
        return { addRes, delRes, durationMs: totalMs, ok: true, failureReason: null, productId: product.id };
      }
      return { addRes, delRes: null, durationMs: addRes.timings.duration, ok: true, failureReason: null, productId: product.id };
    }

    if (addRes.status !== 400) {
      const reason = classifyHttpFailure(addRes, 'add');
      recordCartFailure(reason, addRes.status);
      return {
        addRes,
        delRes: null,
        durationMs: addRes.timings.duration,
        ok: false,
        failureReason: reason,
        productId: product.id,
        detail: responseDetail(addRes),
      };
    }
  }

  const reason = classifyHttpFailure(lastRes, 'add');
  recordCartFailure(reason, lastRes ? lastRes.status : 0);
  return {
    addRes: lastRes,
    delRes: null,
    durationMs: lastRes ? lastRes.timings.duration : 0,
    ok: false,
    failureReason: reason,
    productId: lastProduct ? lastProduct.id : null,
    detail: responseDetail(lastRes),
  };
}

export function setup() {
  const health = http.get(`${BASE_URL}/health`, { tags: { name: 'health' }, timeout: K6_HTTP_TIMEOUT });
  check(health, { 'health check ok': (r) => r.status === 200 });

  const productsRes = http.get(`${BASE_URL}/api/products`, {
    tags: { name: 'products_list' },
    timeout: K6_HTTP_TIMEOUT,
  });
  if (productsRes.status !== 200) {
    throw new Error(
      `GET /api/products returned ${productsRes.status}: ${productsRes.body || productsRes.error || 'no body'}`
    );
  }
  const products = parseProducts(productsRes);
  if (!products.length) {
    throw new Error('No products returned from API');
  }

  const tokens = {};
  for (let vu = 1; vu <= K6_VUS; vu += 1) {
    const token = registerNewUser(vu);
    if (!token) {
      throw new Error(
        `Failed to register/login user for VU ${vu}: ${vuEmail(vu)} (check API is reachable and password meets min length)`
      );
    }
    tokens[String(vu)] = token;
  }

  return { tokens, products, testid: TEST_RUN_ID, startedAt: new Date().toISOString() };
}

export default function (data) {
  const token = data.tokens[String(__VU)];
  if (!token || !data.products.length) {
    checkoutErrors.add(1);
    recordCartFailure(!token ? 'no_token' : 'no_products', '');
    return;
  }

  group('browse and cart', () => {
    const result = addToCart(token, data.products, __VU, __ITER);
    const { addRes, durationMs, ok, failureReason, productId, detail } = result;
    check(addRes, { 'cart add ok': () => ok });
    if (ok) {
      cartAddOkMs.add(addRes.timings.duration);
      iterationDuration.add(durationMs);
    } else if (addRes && addRes.status === 400) {
      checkoutErrors.add(1);
    }
    if (!ok && failureReason && __ITER < 5) {
      console.warn(
        `[cart fail] vu=${__VU} iter=${__ITER} reason=${failureReason} product=${productId ?? 'n/a'} ` +
          `add_status=${addRes ? addRes.status : 'n/a'} ${detail || ''}`
      );
    }
  });

  if (K6_SLEEP > 0) {
    sleep(K6_SLEEP);
  }
}

function metricValues(data, name) {
  return data.metrics[name]?.values || {};
}

function formatMs(values, key) {
  const v = values[key];
  return v === undefined ? 'n/a' : `${Number(v).toFixed(2)}ms`;
}

function collectFailureCounts(data) {
  const metricNames = [
    ['shop_fail_add_timeout', 'add_timeout'],
    ['shop_fail_remove_timeout', 'remove_timeout'],
    ['shop_fail_add_400_stock', 'add_400_stock'],
    ['shop_fail_add_5xx', 'add_5xx'],
    ['shop_fail_remove_5xx', 'remove_5xx'],
    ['shop_fail_add_no_item_id', 'add_no_item_id'],
    ['shop_fail_add_other', 'add_other'],
    ['shop_fail_remove_other', 'remove_other'],
  ];
  const rows = [];
  for (const [metric, label] of metricNames) {
    const count = data.metrics[metric]?.values?.count;
    if (count) {
      rows.push({ tags: label, count });
    }
  }
  rows.sort((a, b) => b.count - a.count || a.tags.localeCompare(b.tags));
  return rows;
}

function formatFailureSummary(data) {
  const rows = collectFailureCounts(data);
  const checkout = data.metrics.shop_checkout_errors?.values?.count ?? 0;
  const checkFails = data.metrics.checks?.values?.fails;
  const lines = ['Cart failure breakdown (shop_cart_failures):'];

  if (!rows.length) {
    lines.push('  (none recorded — failures may be from setup health check only)');
  } else {
    for (const row of rows) {
      lines.push(`  ${row.count}x  {${row.tags}}`);
    }
  }

  lines.push(`shop_checkout_errors (add 400): ${checkout}`);
  if (checkFails !== undefined) {
    lines.push(`checks failed: ${checkFails}`);
  }
  lines.push('');
  lines.push('Reason codes: add_timeout/remove_timeout=HTTP timeout (retried once), add_400_stock=stock.');
  lines.push('First 5 failures per VU are logged to stderr during the run.');
  lines.push('');

  return lines.join('\n');
}

function formatHumanSummary(data) {
  const iter = metricValues(data, 'shop_iteration_ms');
  const cartOk = metricValues(data, 'shop_cart_add_ok_ms');
  const cartAdd = metricValues(data, 'http_req_duration{name:cart_add,expected_response:true}');
  const cartRemove = metricValues(data, 'http_req_duration{name:cart_remove}');
  const blocked = metricValues(data, 'http_req_blocked');
  const connecting = metricValues(data, 'http_req_connecting');
  const httpOk = metricValues(data, 'http_req_duration{expected_response:true}');
  const failed = data.metrics.http_req_failed?.values?.rate;
  const checkRate = data.metrics.checks?.values?.rate;
  const iterations = data.metrics.iterations?.values?.count;
  const vus = data.metrics.vus_max?.values?.max;
  const setupProducts = data.setup_data?.products || [];
  const stockLevels = setupProducts.map((p) => p.stock).filter((s) => s !== undefined);
  const stockSummary = stockLevels.length
    ? `min=${Math.min(...stockLevels)} max=${Math.max(...stockLevels)} (n=${stockLevels.length})`
    : 'n/a';

  return [
    `=== k6 summary (testid=${TEST_RUN_ID}) ===`,
    `VUs: ${vus ?? 'n/a'} | iterations: ${iterations ?? 'n/a'} | cart mode: ${K6_CART_MODE}`,
    `Product stock at setup: ${stockSummary}`,
    '',
    'Per-iteration (successful only, shop_iteration_ms):',
    `  med=${formatMs(iter, 'med')}  avg=${formatMs(iter, 'avg')}  p95=${formatMs(iter, 'p(95)')}`,
    '',
    'cart_add successful only (shop_cart_add_ok_ms — use this in Grafana):',
    `  med=${formatMs(cartOk, 'med')}  p95=${formatMs(cartOk, 'p(95)')}`,
    '',
    'cart_add http (expected_response:true):',
    `  med=${formatMs(cartAdd, 'med')}  p95=${formatMs(cartAdd, 'p(95)')}`,
    ...(K6_CART_MODE === 'add_remove'
      ? [`cart_remove http_req_duration:`, `  med=${formatMs(cartRemove, 'med')}  p95=${formatMs(cartRemove, 'p(95)')}`]
      : []),
    '',
    'Client connect wait (high = k6/Docker TCP pressure, not app CPU):',
    `  blocked p95=${formatMs(blocked, 'p(95)')}  connecting p95=${formatMs(connecting, 'p(95)')}`,
    '',
    'All successful HTTP (expected_response:true):',
    `  med=${formatMs(httpOk, 'med')}  p95=${formatMs(httpOk, 'p(95)')}`,
    '',
    `http_req_failed rate: ${failed === undefined ? 'n/a' : `${(failed * 100).toFixed(2)}%`}`,
    `checks pass rate: ${checkRate === undefined ? 'n/a' : `${(checkRate * 100).toFixed(2)}%`}`,
    '',
    formatFailureSummary(data),
    'Use add_remove mode (default) so delete restores stock. High add_400_stock = stock/contention.',
    '',
  ].join('\n');
}

function stripSummaryMax(data) {
  const copy = JSON.parse(JSON.stringify(data));
  for (const metric of Object.values(copy.metrics || {})) {
    if (metric.type === 'trend' && metric.values) {
      delete metric.values.max;
      delete metric.values.min;
    }
  }
  return copy;
}

export function handleSummary(data) {
  return {
    stdout: `${formatHumanSummary(data)}\n${JSON.stringify(stripSummaryMax(data), null, 2)}`,
  };
}
