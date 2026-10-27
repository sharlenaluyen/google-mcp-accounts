import fs from "fs";
import path from "path";

// Confines a server's local file reads and writes to one folder. Without
// this, a prompt-injected tool call could upload or attach any file you can
// read (e.g. ~/.ssh/id_rsa), or overwrite files anywhere. Each server picks
// its own folder; this is the one shared implementation of the check.
export function createFilesFolder(dir) {
  const FILES_DIR = path.resolve(dir);

  function filesRoot() {
    fs.mkdirSync(FILES_DIR, { recursive: true, mode: 0o700 });
    return fs.realpathSync(FILES_DIR);
  }

  // Compares real paths (symlinks resolved), so a link inside the folder that
  // points elsewhere doesn't get through.
  function assertInside(root, realPath, requested) {
    if (!realPath.startsWith(root + path.sep)) {
      throw new Error(
        `"${requested}" is outside the allowed files folder (${FILES_DIR}). Use a file inside that folder.`
      );
    }
  }

  // A relative path is taken relative to FILES_DIR; an absolute one must point inside it.
  function resolveReadablePath(requested) {
    const root = filesRoot();
    const resolved = path.resolve(root, requested);
    let real;
    try {
      real = fs.realpathSync(resolved);
    } catch {
      throw new Error(`File not found or not readable: ${resolved}`);
    }
    assertInside(root, real, requested);
    return real;
  }

  function resolveWritablePath(requested) {
    const root = filesRoot();
    const resolved = path.resolve(root, requested);
    let dir;
    try {
      dir = fs.realpathSync(path.dirname(resolved));
    } catch {
      throw new Error(`Destination folder doesn't exist: ${path.dirname(resolved)}`);
    }
    const target = path.join(dir, path.basename(resolved));
    assertInside(root, target, requested);
    if (fs.lstatSync(target, { throwIfNoEntry: false })?.isSymbolicLink()) {
      throw new Error(`Refusing to write through a symlink: ${target}`);
    }
    return target;
  }

  return { FILES_DIR, resolveReadablePath, resolveWritablePath };
}

// Checks the real file on disk rather than trusting any size a caller claims.
export function statRegularFile(realPath, maxBytes) {
  const stat = fs.statSync(realPath);
  if (!stat.isFile()) throw new Error(`Not a regular file: ${realPath}`);
  if (stat.size > maxBytes) {
    throw new Error(
      `File is ${(stat.size / 1024 / 1024).toFixed(1)}MB, over the ${(maxBytes / 1024 / 1024).toFixed(0)}MB limit.`
    );
  }
  return stat;
}
