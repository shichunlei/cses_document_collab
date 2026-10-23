// Rebuild native vector catalogs from the desktop package's public geometry data.
// Usage: node tool/generate_snapshot_presets.mjs /absolute/path/to/desktop/node_modules
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

const dependencyRoot = process.argv[2];
if (!dependencyRoot || !path.isAbsolute(dependencyRoot)) throw new Error('Pass the absolute desktop node_modules directory');
await import(pathToFileURL(path.join(dependencyRoot, '@angular/compiler/fesm2022/compiler.mjs')));
const root = path.join(dependencyRoot, '@ccc/blockcraft');
const source = path.join(root, 'fesm2022/ccc-blockcraft.mjs');
const bc = await import(pathToFileURL(source));
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const digest = createHash('sha256').update(fs.readFileSync(source)).digest('hex');
const shapes = bc.SHAPE_DEFINITIONS.map(value => `  ${JSON.stringify(value.type)}: r'''${value.path}''',`).join('\n');
const stickers = bc.STICKER_PRESETS.map(value => {
  const url = bc.renderStickerDataUrl(value.id, value.version, {});
  if (!url) throw new Error(`Invalid sticker ${value.id}`);
  const svg = decodeURIComponent(url.substring(url.indexOf(',') + 1));
  return `  ${JSON.stringify(value.id)}: {"svg": r'''${svg}''', "colors": ${JSON.stringify(value.colors)}},`;
}).join('\n');
const output = `// GENERATED CODE - DO NOT MODIFY BY HAND.\n// Generator: tool/generate_snapshot_presets.mjs\n// Source: @ccc/blockcraft ${version}, fesm2022 SHA-256 ${digest}\n// Geometry and sticker attribution retained through this source identifier.\n\nconst snapshotShapePaths = <String, String>{\n${shapes}\n};\n\nconst snapshotStickerPresets = <String, Map<String, Object>>{\n${stickers}\n};\n`;
fs.writeFileSync(fileURLToPath(new URL('../lib/src/editor/blockcraft_snapshot_presets.g.dart', import.meta.url)), output);
process.stdout.write(JSON.stringify({version, digest, shapes: bc.SHAPE_DEFINITIONS.length, stickers: bc.STICKER_PRESETS.length})+'\n');
