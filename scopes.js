// The OAuth scopes auth.js requests, grouped by the server that needs them.
// One consent screen grants the union, so every account is authorized once
// for all four servers.
const G = "https://www.googleapis.com/auth/";

export const PRODUCT_SCOPES = {
  // gmail.modify alone covers everything multi-gmail-mcp does; the narrower
  // three are listed too so the consent screen spells each capability out.
  gmail: [`${G}gmail.readonly`, `${G}gmail.send`, `${G}gmail.modify`, `${G}gmail.labels`],
  // calendar.events can read and write events but can't list calendars;
  // calendarList.list needs calendar.calendarlist.readonly (the narrowest
  // scope that allows it - read-only, and only the list of subscriptions).
  calendar: [`${G}calendar.events`, `${G}calendar.calendarlist.readonly`],
  // Only files this OAuth client created or opened - not your whole Drive.
  drive: [`${G}drive.file`],
  docs: [`${G}documents`],
  sheets: [`${G}spreadsheets`],
  slides: [`${G}presentations`],
};

// The minimum each server checks for before making calls (via
// createAuthClient's requiredScopes) - what makes an account "usable" for it.
// Accounts imported from the old multi-gmail-mcp only have gmail.modify,
// which is all multi-gmail-mcp needs.
export const REQUIRED_SCOPES = {
  gmail: [`${G}gmail.modify`],
  calendar: [`${G}calendar.events`],
  calendarList: [`${G}calendar.calendarlist.readonly`],
  drive: [`${G}drive.file`],
  docs: [`${G}documents`],
  sheets: [`${G}spreadsheets`],
  slides: [`${G}presentations`],
};

// Opt-in escalation (auth.js --with-drive-readonly): lets multi-gdrive-mcp
// search and download files this app didn't create. Never requested by default.
export const DRIVE_READONLY_SCOPE = `${G}drive.readonly`;

export const DEFAULT_SCOPES = Object.values(PRODUCT_SCOPES).flat();

export function scopesToRequest({ driveReadonly = false } = {}) {
  return driveReadonly ? [...DEFAULT_SCOPES, DRIVE_READONLY_SCOPE] : [...DEFAULT_SCOPES];
}

// "https://www.googleapis.com/auth/drive.file" -> "drive.file", for messages.
export function shortScope(scope) {
  return scope.startsWith(G) ? scope.slice(G.length) : scope;
}
