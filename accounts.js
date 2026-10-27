import { loadCredentials, loadAccounts, resolveAlias } from "./store.js";
import { shortScope } from "./scopes.js";

// One main alias per connected account - nicknames are not included, so
// anything that loops over these touches each account exactly once.
export function getConnectedAliases() {
  return Object.keys(loadAccounts());
}

// Accepts a main alias or a nickname. The returned info includes `alias`,
// the main alias it resolved to.
export function getAccountInfo(name) {
  const accounts = loadAccounts();
  const alias = resolveAlias(accounts, name);
  if (!alias) {
    const known =
      Object.keys(accounts)
        .flatMap((a) => [a, ...(accounts[a].nicknames || [])])
        .join(", ") || "(none connected)";
    throw new Error(`Unknown account alias "${name}". Connected aliases: ${known}`);
  }
  return { alias, nicknames: [], ...accounts[alias] };
}

// The scopes in `required` this account never granted. An entry with no
// recorded `scopes` (written by an older auth CLI) is treated as unknown and
// passes - Google's own 403 is then the fallback.
export function missingScopes(info, required) {
  if (!Array.isArray(info.scopes)) return [];
  return required.filter((scope) => !info.scopes.includes(scope));
}

export function hasScope(info, scope) {
  return Array.isArray(info.scopes) && info.scopes.includes(scope);
}

// An OAuth2 client for this account that refreshes its own access tokens.
// `OAuth2` is the caller's own google.auth.OAuth2 class, so the client
// matches the googleapis copy the server makes its API calls with. Throws a
// clear "re-run auth" error up front if the account lacks a needed scope.
export function createAuthClient(name, { OAuth2, requiredScopes = [] }) {
  const info = getAccountInfo(name);
  const missing = missingScopes(info, requiredScopes);
  if (missing.length) {
    throw new Error(
      `Account "${info.alias}" (${info.email}) hasn't granted ${missing.map(shortScope).join(", ")}. ` +
        `Re-authorize it once with: npx google-mcp-auth ${info.alias}  (run inside the google-mcp-accounts folder)`
    );
  }
  const { clientId, clientSecret, redirectUri } = loadCredentials();
  const client = new OAuth2(clientId, clientSecret, redirectUri);
  client.setCredentials({ refresh_token: info.refresh_token });
  return client;
}
