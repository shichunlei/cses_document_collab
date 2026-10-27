/**
 * Sync the installed desktop emoji catalog and CLDR Chinese names, without network access.
 * Run from any directory: node tool/sync_desktop_emoji_catalog.mjs /path/to/cses-client
 * The generated Dart and license notices must be updated together; do not edit the output.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const desktop = process.argv[2];
if (!desktop) throw new Error('Pass the desktop repository directory');
const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const library = path.resolve(desktop, 'node_modules/@ctrl/ngx-emoji-mart');
const ui = path.resolve(desktop, 'node_modules/@cses/ui');
const emojiPath = path.join(library, 'esm2022/ngx-emoji/data/emojis.mjs');
const categoryPath = path.join(library, 'esm2022/ngx-emoji/data/categories.mjs');
const chunks = (await readdir(path.join(ui, 'fesm2022'))).filter((name) => /^cses-ui-emoji-picker-zh-labels.*\.mjs$/.test(name));
if (chunks.length !== 1) throw new Error('Desktop UI Chinese-label chunk changed; inspect before syncing');
const namesPath = path.join(ui, 'fesm2022', chunks[0]);
const [{ emojis }, { categories }, namesSource, metadata] = await Promise.all([
  import(pathToFileURL(emojiPath).href), import(pathToFileURL(categoryPath).href),
  readFile(namesPath, 'utf8'), readFile(path.join(library, 'package.json'), 'utf8'),
]);
const { ZH_EMOJI_LABELS: names, ZH_EMOJI_PINYIN: pinyin } = await import(pathToFileURL(namesPath).href);
const uiSource = await readFile(path.join(ui, 'fesm2022/cses-ui.mjs'), 'utf8');
const aliasLiteral = uiSource.match(/const ZH_SEARCH_ALIASES = (\{[\s\S]*?\n\});/);
if (!aliasLiteral) throw new Error('Desktop search aliases changed; inspect before syncing');
// Evaluate only the extracted data literal, with no host bindings or imports.
const aliases = runInNewContext(`(${aliasLiteral[1]})`, Object.create(null), { timeout: 1000 });
if (!Object.values(aliases).every((values) => Array.isArray(values) && values.every((value) => typeof value === 'string'))) {
  throw new Error('Invalid desktop search aliases');
}
const unicodeNotice = namesSource.match(/^\/\*\*([\s\S]*?)\*\//)?.[1].replace(/^\s*\* ?/gm, '').trim();
if (!unicodeNotice?.includes('UNICODE LICENSE V3')) throw new Error('Missing Unicode license notice');
const uiVersion = JSON.parse(await readFile(path.join(ui, 'package.json'), 'utf8')).version;
const labels = {
  people: '表情与人物', nature: '动物与自然', foods: '食物与饮料', activity: '活动与运动',
  places: '旅行与地点', objects: '物品', symbols: '符号', flags: '旗帜',
};
const native = (unified) => String.fromCodePoint(...unified.split('-').map((part) => parseInt(part, 16)));
const quote = (value) => JSON.stringify(value).replaceAll('$', '\\$');
const seen = new Set();
let count = 0;
let variants = 0;
const groups = categories.map((category) => {
  if (!labels[category.id]) throw new Error(`Unknown desktop category: ${category.id}`);
  const entries = category.emojis.flatMap((id) => {
    const emoji = emojis.find((entry) => entry.unified === id);
    if (!emoji) throw new Error(`Missing emoji: ${id}`);
    const value = native(emoji.unified);
    if (emoji.obsoletedBy || seen.has(value)) return [];
    seen.add(value);
    count++;
    const label = names[emoji.shortName] ?? value;
    const phonetics = (pinyin[emoji.shortName] ?? []).flatMap((phrase) => {
      const syllables = phrase.split(' ');
      return [syllables.map((part) => part[0]).join(''), ...syllables.map((_, index) => syllables.slice(index).join(''))];
    });
    const keywords = [label, emoji.name, emoji.shortName, ...(emoji.shortNames ?? []),
      ...(emoji.keywords ?? []), ...(emoji.emoticons ?? []), ...phonetics,
      ...[emoji.shortName, ...(emoji.shortNames ?? [])].flatMap((name) => aliases[name] ?? [])].join(' ').toLowerCase();
    const tones = emoji.skinVariations?.length ? ['1F3FB', '1F3FC', '1F3FD', '1F3FE', '1F3FF'].map((tone) => {
      const variant = emoji.skinVariations.find((entry) => entry.unified.includes(tone));
      if (!variant) throw new Error(`Missing skin tone: ${id}/${tone}`);
      return native(variant.unified);
    }) : [];
    variants += tones.length;
    return [`    CollabEmoji(${quote(value)}, ${quote(label)}, ${quote(keywords)}${tones.length ? `, [${tones.map(quote).join(', ')}]` : ''}),`];
  });
  return `  CollabEmojiCategory(${quote(category.id)}, ${quote(labels[category.id])}, [\n${entries.join('\n')}\n  ]),`;
});
const hashes = {};
for (const [label, filename] of [['emojis', emojiPath], ['categories', categoryPath], ['names', namesPath], ['ui', path.join(ui, 'fesm2022/cses-ui.mjs')]]) {
  hashes[label] = createHash('sha256').update(await readFile(filename)).digest('hex');
}
const version = JSON.parse(metadata).version;
const notices = [
  ['ngx-emoji-mart', await readFile(path.join(library, 'LICENSE'), 'utf8')],
  ['Unicode CLDR', unicodeNotice],
];
await writeFile(path.join(root, 'lib/src/model/collab_emoji_catalog.g.dart'),
  `// GENERATED CODE - DO NOT MODIFY BY HAND.\n// Source: @ctrl/ngx-emoji-mart ${version}; @cses/ui ${uiVersion} CsEmojiPicker CLDR zh labels/pinyin.\n// Regenerate: node tool/sync_desktop_emoji_catalog.mjs /path/to/cses-client\n// ${count} base emoji, ${variants} skin-tone sequences. See third_party/emoji/ for licenses.\n// SHA256: ${JSON.stringify(hashes)}\npart of 'collab_emoji_catalog.dart';\n\nconst _desktopEmojiCategories = <CollabEmojiCategory>[\n${groups.join('\n')}\n];\n\nconst _desktopEmojiLicenseNotices = <(String, String)>[\n${notices.map(([name, license]) => `  (${quote(name)}, ${quote(license)}),`).join('\n')}\n];\n`);
await mkdir(path.join(root, 'third_party/emoji'), { recursive: true });
await writeFile(path.join(root, 'third_party/emoji/ngx-emoji-mart-LICENSE.txt'), await readFile(path.join(library, 'LICENSE')));
await writeFile(path.join(root, 'third_party/emoji/Unicode-LICENSE.txt'), unicodeNotice + '\n');
await writeFile(path.join(root, 'third_party/emoji/README.md'),
  `# 表情数据来源\n\n同步桌面实际Callout/图标使用的 \`@cses/ui ${uiVersion}\` CsEmojiPickerComponent：其引擎为 \`@ctrl/ngx-emoji-mart ${version}\`（Unicode 14目录），中文名称、别名与拼音来自同版UI发布产物的CLDR release-48数据。保留目录顺序，去除废弃别名，输出${count}个默认表情及${variants}个肤色序列；不复制图片、运行时代码或业务记录。\n\n原始数据许可见同目录MIT及Unicode-3.0文件。同步输入SHA-256记录于生成文件头部。\n\n重新生成：\n\n\`\`\`sh\nnode tool/sync_desktop_emoji_catalog.mjs /path/to/cses-client\n\`\`\`\n`);
process.stdout.write(`${count} emoji, ${variants} skin-tone sequences, ${groups.length} categories\n`);
