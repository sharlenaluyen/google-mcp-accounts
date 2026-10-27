import test from "node:test";
import assert from "node:assert/strict";
import { withRetry, isRetryableError } from "../retry.js";

test("withRetry retries on a 429 and eventually succeeds", async () => {
  let calls = 0;
  const result = await withRetry(
    async () => {
      calls++;
      if (calls < 3) throw Object.assign(new Error("rate limited"), { code: 429 });
      return "ok";
    },
    { baseDelayMs: 1 }
  );
  assert.equal(result, "ok");
  assert.equal(calls, 3);
});

test("withRetry retries a 5xx reported on err.response.status", async () => {
  let calls = 0;
  await withRetry(
    async () => {
      calls++;
      if (calls < 2) throw Object.assign(new Error("backend"), { response: { status: 503 } });
    },
    { baseDelayMs: 1 }
  );
  assert.equal(calls, 2);
});

test("withRetry does not retry a non-retryable error", async () => {
  let calls = 0;
  await assert.rejects(
    withRetry(
      async () => {
        calls++;
        throw Object.assign(new Error("forbidden"), { code: 403 });
      },
      { baseDelayMs: 1 }
    ),
    /forbidden/
  );
  assert.equal(calls, 1);
});

test("withRetry gives up after the retry budget and rethrows the last error", async () => {
  let calls = 0;
  await assert.rejects(
    withRetry(
      async () => {
        calls++;
        throw Object.assign(new Error(`fail ${calls}`), { code: 500 });
      },
      { retries: 2, baseDelayMs: 1 }
    ),
    /fail 3/
  );
  assert.equal(calls, 3);
});

test("isRetryableError covers 429 and 5xx only", () => {
  assert.ok(isRetryableError({ code: 429 }));
  assert.ok(isRetryableError({ code: 500 }));
  assert.ok(isRetryableError({ response: { status: 502 } }));
  assert.ok(!isRetryableError({ code: 400 }));
  assert.ok(!isRetryableError({ code: 404 }));
  assert.ok(!isRetryableError(new Error("network")));
  assert.ok(!isRetryableError(undefined));
});
