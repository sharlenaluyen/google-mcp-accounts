import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";
import { createFilesFolder, statRegularFile } from "../files.js";

// Always a throwaway directory - never a real Downloads folder.
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "gmcp-files-")));
const filesDir = path.join(tmp, "files");
const { FILES_DIR, resolveReadablePath, resolveWritablePath } = createFilesFolder(filesDir);
const outside = path.join(tmp, "secret.txt");
fs.writeFileSync(outside, "do not upload");

test("the files folder is created on demand", () => {
  assert.equal(FILES_DIR, filesDir);
  resolveWritablePath("x.pdf");
  assert.ok(fs.statSync(filesDir).isDirectory());
});

test("files inside the folder resolve, by relative or absolute path", () => {
  fs.writeFileSync(path.join(filesDir, "ok.txt"), "hi");
  assert.equal(resolveReadablePath("ok.txt"), path.join(filesDir, "ok.txt"));
  assert.equal(resolveReadablePath(path.join(filesDir, "ok.txt")), path.join(filesDir, "ok.txt"));
  assert.equal(resolveWritablePath("new.pdf"), path.join(filesDir, "new.pdf"));
});

test("reading outside the folder is refused, including via ../ and symlinks", () => {
  assert.throws(() => resolveReadablePath(outside), /outside the allowed files folder/);
  assert.throws(() => resolveReadablePath("../secret.txt"), /outside the allowed files folder/);
  fs.symlinkSync(outside, path.join(filesDir, "link.txt"));
  assert.throws(() => resolveReadablePath("link.txt"), /outside the allowed files folder/);
  assert.throws(() => resolveReadablePath(path.join(os.homedir(), ".ssh", "id_rsa")), /outside|not found/);
});

test("writing outside the folder or through a symlink is refused", () => {
  assert.throws(() => resolveWritablePath(path.join(tmp, "evil.sh")), /outside the allowed files folder/);
  assert.throws(() => resolveWritablePath("../evil.sh"), /outside the allowed files folder/);
  assert.throws(() => resolveWritablePath("link.txt"), /symlink/);
  assert.throws(() => resolveWritablePath("missing-dir/x.pdf"), /Destination folder doesn't exist/);
});

test("the folder itself is not a valid file path (prefix match is on root + separator)", () => {
  const sibling = filesDir + "-evil";
  fs.mkdirSync(sibling);
  fs.writeFileSync(path.join(sibling, "x.txt"), "x");
  assert.throws(() => resolveReadablePath(path.join(sibling, "x.txt")), /outside the allowed files folder/);
});

test("statRegularFile checks the real size and type on disk", () => {
  const f = path.join(filesDir, "five.bin");
  fs.writeFileSync(f, Buffer.alloc(5));
  assert.equal(statRegularFile(f, 10).size, 5);
  assert.throws(() => statRegularFile(f, 4), /over the/);
  assert.throws(() => statRegularFile(filesDir, 10), /Not a regular file/);
});
