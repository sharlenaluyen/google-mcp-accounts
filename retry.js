// --- Retry with backoff -------------------------------------------------
// Google APIs return 429 (rate limit) and transient 5xx errors under load.
// Retrying a *read* is always safe; callers apply this wrapper only to
// idempotent calls (reads, label changes, trashing). Anything another person
// would see or be notified about - a send, a share, an event invite, a
// document edit - is deliberately never silently retried, to avoid doing it
// twice on a flaky connection.
export function isRetryableError(err) {
  const status = err?.code || err?.response?.status;
  return status === 429 || (status >= 500 && status < 600);
}

export async function withRetry(fn, { retries = 3, baseDelayMs = 300 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (!isRetryableError(err) || attempt === retries) break;
      const delay = baseDelayMs * 2 ** attempt + Math.random() * 100;
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
  throw lastErr;
}
