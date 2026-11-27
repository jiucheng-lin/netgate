/**
 * NetGate anonymous telemetry collector (Cloudflare Worker + KV)
 *
 * Endpoints:
 *   POST /ingest   - accept a JSON array of anonymous events
 *   GET  /stats    - aggregated counters (requires ?token=)
 *   GET  /health   - health check
 *
 * Privacy: only event name, outcome flag, coarse OS version and an anonymous
 * rotating id are accepted. Paths, filenames, IPs and usernames are discarded.
 */

const ALLOWED_EVENTS = new Set([
  'app_start', 'block', 'unblock', 'enable', 'disable',
  'scan', 'export', 'import', 'reset', 'error'
]);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store'
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: CORS });
}

function dayKey(d = new Date()) {
  return d.toISOString().slice(0, 10);
}

function clampInt(v, max = 1000) {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(max, Math.floor(n)));
}

function sanitizeEvent(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const e = String(raw.e || '');
  if (!ALLOWED_EVENTS.has(e)) return null;
  return {
    e,
    r: raw.r === 0 || raw.r === false ? 0 : 1,
    os: String(raw.os || '').slice(0, 24),
    t: clampInt(raw.t, 9999999999),
    id: String(raw.id || '').slice(0, 64)
  };
}

async function bumpCounter(env, key, amount = 1) {
  const cur = await env.NETGATE_KV.get(key, 'json');
  const next = (cur && typeof cur.n === 'number' ? cur.n : 0) + amount;
  await env.NETGATE_KV.put(key, JSON.stringify({ n: next, u: Date.now() }));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }

    if (path === '/health') {
      return json({ ok: true, service: 'netgate-telemetry', v: 1 });
    }

    if (path === '/ingest' && request.method === 'POST') {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ ok: false, error: 'invalid_json' }, 400);
      }
      const events = Array.isArray(body) ? body : [body];
      if (events.length > 100) {
        return json({ ok: false, error: 'too_many' }, 413);
      }

      const clean = events.map(sanitizeEvent).filter(Boolean);
      if (clean.length === 0) {
        return json({ ok: false, error: 'no_valid_events' }, 400);
      }

      // Do work in background so the client is not kept waiting.
      const writes = [];
      for (const ev of clean) {
        writes.push(bumpCounter(env, `event:${ev.e}`));
        if (ev.r === 0) writes.push(bumpCounter(env, `fail:${ev.e}`));
        writes.push(bumpCounter(env, `day:${dayKey()}:${ev.e}`));
      }
      // Track unique anonymous ids per day (best-effort, KV set semantics).
      const ids = [...new Set(clean.map(e => e.id).filter(Boolean))];
      for (const id of ids) {
        writes.push(env.NETGATE_KV.put(`uid:${dayKey()}:${id.slice(0, 16)}`, '1'));
      }
      ctx.waitUntil(Promise.all(writes));

      return json({ ok: true, accepted: clean.length });
    }

    if (path === '/stats' && request.method === 'GET') {
      const token = url.searchParams.get('token');
      if (!env.STATS_TOKEN || token !== env.STATS_TOKEN) {
        return json({ ok: false, error: 'unauthorized' }, 401);
      }

      const names = [...ALLOWED_EVENTS];
      const totals = {};
      const fails = {};
      for (const n of names) {
        const t = await env.NETGATE_KV.get(`event:${n}`, 'json');
        const f = await env.NETGATE_KV.get(`fail:${n}`, 'json');
        totals[n] = t && typeof t.n === 'number' ? t.n : 0;
        fails[n] = f && typeof f.n === 'number' ? f.n : 0;
      }

      // Last 7 days daily breakdown.
      const daily = {};
      for (let i = 0; i < 7; i++) {
        const d = new Date(Date.now() - i * 86400000);
        const k = dayKey(d);
        const row = {};
        for (const n of names) {
          const v = await env.NETGATE_KV.get(`day:${k}:${n}`, 'json');
          row[n] = v && typeof v.n === 'number' ? v.n : 0;
        }
        daily[k] = row;
      }

      return json({ ok: true, totals, failures: fails, daily });
    }

    return json({ ok: false, error: 'not_found' }, 404);
  }
};
