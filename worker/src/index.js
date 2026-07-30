// UNUSED as of 2026-07-29. Lineform no longer sends diagram reports — the feature was removed
// because it was the only thing in the app that transmitted document content off the device.
// This Worker may still be deployed; nothing in the app or the release process calls it, and it
// can be torn down. Kept only so a deployed service is not left without source.
//
// Lineform diagram-failure report Worker.
// Accepts POST { source, error, appVersion } and files/comments a private GitHub issue.
// The GitHub token is a Worker secret (GITHUB_TOKEN); IPs are used only for transient rate
// limiting and are never stored, logged, or written into issues.

const REPO = "carlostarrats/lineform-reports";
const MAX_BODY_BYTES = 64 * 1024;
const RATE_LIMIT_PER_HOUR = 10;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    // Size guard (declared and actual, in bytes).
    const declared = Number(request.headers.get("content-length") || "0");
    if (declared > MAX_BODY_BYTES) {
      return json({ error: "payload too large" }, 413);
    }
    const bodyBytes = await request.arrayBuffer();
    if (bodyBytes.byteLength > MAX_BODY_BYTES) {
      return json({ error: "payload too large" }, 413);
    }
    const raw = new TextDecoder().decode(bodyBytes);

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return json({ error: "invalid json" }, 400);
    }
    const source = payload && payload.source;
    const errorText = payload && payload.error;
    const appVersion = payload && payload.appVersion;
    if (typeof source !== "string" || typeof errorText !== "string" || typeof appVersion !== "string"
        || source.length === 0) {
      return json({ error: "invalid payload" }, 400);
    }

    // Per-IP rate limit (transient; the IP is a KV key only, never persisted elsewhere).
    // KV read-then-write is best-effort, not atomic; GitHub's own secondary limits backstop it.
    if (!env.RATE_LIMIT) {
      return json({ error: "reporting not configured" }, 503);
    }
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const key = `rl:${ip}:${new Date().getUTCHours()}`;
    const current = Number((await env.RATE_LIMIT.get(key)) || "0");
    if (current >= RATE_LIMIT_PER_HOUR) {
      return json({ error: "rate limited" }, 429);
    }
    await env.RATE_LIMIT.put(key, String(current + 1), { expirationTtl: 3600 });

    if (!env.GITHUB_TOKEN) {
      return json({ error: "reporting not configured" }, 503);
    }

    const hash = await sha256Hex(source);
    try {
      await fileOrComment({ token: env.GITHUB_TOKEN, hash, source, error: errorText, appVersion });
    } catch (e) {
      console.error(e);
      return json({ error: "github request failed" }, 502);
    }
    return json({ ok: true }, 200);
  },
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const GH = "https://api.github.com";

function ghHeaders(token) {
  return {
    "authorization": `Bearer ${token}`,
    "accept": "application/vnd.github+json",
    "user-agent": "lineform-diagram-report",
    "x-github-api-version": "2022-11-28",
  };
}

async function fileOrComment({ token, hash, source, error, appVersion }) {
  // GitHub label names max out at 50 chars; 160 bits of hash still dedups safely.
  const label = `hash:${hash.slice(0, 40)}`;
  // Look for an existing OPEN issue with this hash label.
  const searchURL = `${GH}/repos/${REPO}/issues?state=open&labels=${encodeURIComponent(label)}&per_page=1`;
  const existing = await fetch(searchURL, { headers: ghHeaders(token) });
  if (!existing.ok) throw new Error(`list issues ${existing.status}`);
  const issues = await existing.json();

  if (Array.isArray(issues) && issues.length > 0) {
    const number = issues[0].number;
    const commentURL = `${GH}/repos/${REPO}/issues/${number}/comments`;
    const commentVersion = appVersion.slice(0, 100).replace(/[`\r\n]/g, "'");
    const res = await fetch(commentURL, {
      method: "POST",
      headers: { ...ghHeaders(token), "content-type": "application/json" },
      body: JSON.stringify({ body: `Reported again (app \`${commentVersion}\`).` }),
    });
    if (!res.ok) throw new Error(`comment ${res.status}`);
    return;
  }

  // The reporter controls source/error, so neutralize Markdown: cap the error and
  // render it as inline code, and use a fence longer than any backtick run in source
  // so the mermaid block cannot be broken out of.
  const safeError = error.slice(0, 500).replace(/[`\r\n]/g, "'");
  const backtickRuns = source.match(/`+/g) || [];
  const fence = "`".repeat(Math.max(3, ...backtickRuns.map((r) => r.length + 1)));
  const safeVersion = appVersion.slice(0, 100).replace(/[`\r\n]/g, "'");
  const body = [
    `**Error:** \`${safeError}\``,
    `**App version:** \`${safeVersion}\``,
    `**Hash:** \`${hash}\``,
    "",
    `${fence}mermaid`,
    source,
    fence,
  ].join("\n");
  const res = await fetch(`${GH}/repos/${REPO}/issues`, {
    method: "POST",
    headers: { ...ghHeaders(token), "content-type": "application/json" },
    body: JSON.stringify({
      title: `Diagram render failure (${hash.slice(0, 8)})`,
      body,
      labels: [label],
    }),
  });
  if (!res.ok) throw new Error(`create issue ${res.status}`);
}
