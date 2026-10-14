"""Generate Flutter cover data from the desktop static catalog (no network).

Usage: python3 tool/sync_document_cover_catalog.py /path/to/doc-image-picker.catalog.ts
"""

import json
from pathlib import Path
import re
import subprocess
import sys


source = Path(sys.argv[1]).read_text()
base = re.search(r"const CDN_BASE_URL = '([^']+)'", source)
preview = re.search(r"previewUrl: `([^`]+)`", source)
groups = list(re.finditer(
    r"id:\s*'([^']+)',\s*title:\s*'([^']+)',\s*items:\s*\[([^\]]+)\]",
    source,
))
if base is None or preview is None or not groups:
    raise ValueError("Desktop cover catalog format changed; inspect before syncing")

def quote(value):
    return json.dumps(value, ensure_ascii=False).replace('$', r'\$')
entries = []
ids = set()
for group in groups:
    items = re.findall(
        r"cover\('([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)'\)",
        group[3],
    )
    if not items or len(items) != group[3].count('cover('):
        raise ValueError("Unrecognized desktop cover entry")
    rows = []
    for item_id, label, preview_name, file_name in items:
        if item_id in ids:
            raise ValueError(f"Duplicate cover id: {item_id}")
        ids.add(item_id)
        preview_url = preview[1].replace('${previewName}', preview_name)
        url = f'{base[1]}/{file_name}'
        if '${' in preview_url:
            raise ValueError("Unrecognized desktop preview URL template")
        rows.append('    DocumentCoverImage(' + ', '.join(map(quote, (
            item_id, label, preview_url, url,
        ))) + '),')
    entries.append('  DocumentCoverGroup(' + quote(group[1]) + ', ' +
                   quote(group[2]) + ', [\n' + '\n'.join(rows) + '\n  ]),')

if source.count('cover(') != len(ids) + 1:
    raise ValueError('Unrecognized desktop catalog group; inspect before syncing')

output = Path(__file__).resolve().parent.parent / 'lib/src/model/document_cover_catalog.dart'
output.write_text('''// Generated from cses-client/packages/docs/src/document-content/metadata/
// components/doc-image-picker.catalog.ts. Do not edit the image list by hand.
// Update with tool/sync_document_cover_catalog.py and the desktop source path.

/// 桌面图库物料，不拥有网络资源；previewUrl用于缩略图，url用于业务保存。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
/// final image = documentCoverGroups.first.items.first;
/// final selectedUrl = image.url;
/// ```
class DocumentCoverImage {
  /// [id] 是稳定清单ID，[label] 是展示名称，[previewUrl] 为缩略图，[url] 为CSES原图。
  /// 参数来自桌面静态清单，本记录不校验网络可达性。
  const DocumentCoverImage(this.id, this.label, this.previewUrl, this.url);
  /// 稳定物料ID，用于点击键与清单核对。
  final String id;
  /// 展示名称，在缩略图加载失败时仍显示。
  final String label;
  /// 桌面缩略图URL，仅用于预览，不写入banner。
  final String previewUrl;
  /// CSES原图URL，选择后交给业务保存。
  final String url;
}

/// 桌面静态物料组，保留桌面顺序与名称；不拥有滚动或选择状态。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
/// final groups = documentCoverGroups;
/// final spaceImages = groups.first.items;
/// ```
class DocumentCoverGroup {
  /// [id] 是分组ID，[title] 为分组名称，[items] 为按桌面顺序排列的常量物料。
  const DocumentCoverGroup(this.id, this.title, this.items);
  /// 桌面稳定分组ID。
  final String id;
  /// 展示用分组名称。
  final String title;
  /// 分组内静态物料；生成清单为常量列表。
  final List<DocumentCoverImage> items;
}

/// 构建前从桌面源码同步的完整图库；更新由同步工具生成，运行时不查询图库接口。
const documentCoverGroups = <DocumentCoverGroup>[
''' + '\n'.join(entries) + '\n];\n')
subprocess.run(['dart', 'format', str(output)], check=True)
print(f'Synced {len(groups)} groups, {len(ids)} covers from desktop')
