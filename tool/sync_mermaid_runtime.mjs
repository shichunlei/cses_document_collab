// Refresh the pinned offline runtime and its license from the desktop dependency.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const desktopRoot = process.argv[2];
if (!desktopRoot) throw Error('Usage: node tool/sync_mermaid_runtime.mjs <desktop-root>');
const source = path.join(desktopRoot, 'node_modules/mermaid');
const version = JSON.parse(fs.readFileSync(path.join(source, 'package.json'))).version;
if (version !== '11.13.0') throw Error(`Review runtime compatibility before changing pinned 11.13.0 to ${version}`);
const target=fileURLToPath(new URL('../assets/mermaid/',import.meta.url));
for(const [from,to] of [['dist/mermaid.min.js','mermaid.min.js'],['LICENSE','LICENSE']])fs.copyFileSync(path.join(source,from),path.join(target,to));
const sha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(target,'mermaid.min.js'))).digest('hex');
fs.writeFileSync(path.join(target,'runtime.json'),JSON.stringify({package:'mermaid',version,source:'dist/mermaid.min.js',sha256,license:'MIT'},null,2)+'\n');
console.log(JSON.stringify({version,sha256}));
