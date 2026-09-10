import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const SKIP = new Set(['.git', '.build', 'node_modules', 'android', 'target', 'Vendor']);

export function src(basename) {
  const hits = [];
  function walk(dir) {
    let ents;
    try {
      ents = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of ents) {
      if (SKIP.has(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === basename) hits.push(p);
    }
  }
  walk(path.join(root, 'Sources'));
  if (!hits.length) walk(root);
  if (!hits.length) throw new Error(`source not found: ${basename}`);
  return fs.readFileSync(hits[0], 'utf8');
}
