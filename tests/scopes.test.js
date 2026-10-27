import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_SCOPES,
  DRIVE_READONLY_SCOPE,
  REQUIRED_SCOPES,
  scopesToRequest,
  shortScope,
} from "../scopes.js";

const short = (list) => list.map(shortScope);

test("the default request is the union of every server's scopes", () => {
  assert.deepEqual(short(scopesToRequest()), [
    "gmail.readonly",
    "gmail.send",
    "gmail.modify",
    "gmail.labels",
    "calendar.events",
    "calendar.calendarlist.readonly",
    "drive.file",
    "documents",
    "spreadsheets",
    "presentations",
  ]);
});

test("whole-Drive and whole-Calendar scopes are never requested by default", () => {
  const scopes = short(DEFAULT_SCOPES);
  for (const broad of [
    "drive",
    "drive.readonly",
    "calendar",
    "calendar.readonly",
    "https://mail.google.com/",
  ]) {
    assert.ok(!scopes.includes(broad), `${broad} should not be in the default request`);
  }
});

test("drive.readonly is added only when explicitly asked for", () => {
  assert.ok(!scopesToRequest().includes(DRIVE_READONLY_SCOPE));
  assert.ok(scopesToRequest({ driveReadonly: true }).includes(DRIVE_READONLY_SCOPE));
});

test("every scope a server requires is part of the default request", () => {
  for (const [product, required] of Object.entries(REQUIRED_SCOPES)) {
    for (const scope of required) assert.ok(DEFAULT_SCOPES.includes(scope), `${product}: ${scope}`);
  }
});
