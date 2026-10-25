use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use yrs::sync::{Awareness, AwarenessUpdate, Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{
    types::Attrs, Any, Array, ArrayRef, Doc, GetString, Map, MapRef, OffsetKind, Options, Out,
    ReadTxn, StateVector, Text, Transact, Update,
};

#[path = "blockcraft.rs"]
mod blockcraft;
use super::block_locks;
#[path = "document_bootstrap.rs"]
mod document_bootstrap;
#[path = "document_history.rs"]
pub mod history;
#[path = "paragraph_style.rs"]
mod paragraph_style;

const BLOCK_ORDER_NAME: &str = "cses_mobile_block_order";
const BLOCK_META_NAME: &str = "cses_mobile_block_meta";
const BLOCK_CHECKED_NAME: &str = "cses_mobile_block_checked";
const BLOCK_ALIGN_NAME: &str = "cses_mobile_block_align";
const BLOCK_INDENT_NAME: &str = "cses_mobile_block_indent";
const BLOCK_COLORS_NAME: &str = "cses_mobile_block_colors";
const BLOCK_TEXT_PREFIX: &str = "cses_mobile_block_text:";
const LEGACY_TEXT_NAME: &str = "cses_demo_text";
const LEGACY_BLOCK_ID: &str = "legacy-shared-text";

static ENGINE: Lazy<Mutex<Option<CollabEngine>>> = Lazy::new(|| Mutex::new(None));

/// 富文本片段投影；行内公式以单个对象替换字符占据一个 UTF-16 光标位置。
/// `inline_latex` 只携带桌面 embed 原文，不作为 Y.Text 格式属性保存。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollabTextSegment {
    /// 白名单字体、字号和字距的JSON；None 表示继承，不携带链接或业务属性。
    pub typography: Option<String>,
    /// 正文或单个对象替换字符；长度采用 UTF-16，与 Yjs/Flutter 光标一致。
    pub text: String,
    /// Optional original link target; formal documents map it to a:link, None means unlinked.
    pub href: Option<String>,
    /// 是否加粗。
    pub bold: bool,
    /// 是否斜体。
    pub italic: bool,
    /// 是否有下划线。
    pub underline: bool,
    /// 是否有删除线。
    pub strikethrough: bool,
    /// 是否使用行内代码格式。
    pub code: bool,
    /// 显式文字颜色原值；None 表示继承。
    pub text_color: Option<String>,
    /// Inline background/highlight color encoded as an ARGB string.
    ///
    /// This stays distinct from `text_color` so peers can independently merge
    /// foreground and background formatting on the same Yrs text range.
    pub background_color: Option<String>,
    /// 是否为上标。
    pub superscript: bool,
    /// 是否为下标。
    pub subscript: bool,
    /// 行内公式的 LaTeX 原文；Some 时 text 必须是单个 U+FFFC，None 为普通文本。
    /// 空字符串的桌面 embed 可读取；本地编辑为空按桌面语义删除对象。
    pub inline_latex: Option<String>,
    /// 用户、会议、任务或文档显示名；Some 时 text 为 U+FFFC，与 inline_latex 互斥。
    pub inline_mention: Option<String>,
    /// 用户或业务实体稳定 ID；与 inline_mention 成对使用，不保存头像或宿主认证。
    pub mention_id: Option<String>,
    /// None 兼容已有用户投影；meeting/task/doc按各自实体语义展示，其他值拒绝写入。
    pub mention_type: Option<String>,
    /// 四类提及原始属性的稳定JSON，用于宿主点击及删除后恢复完整扩展字段。
    /// 不作为可编辑业务补丁；既有同身份对象以原生属性为准，最多65536字节。
    pub mention_attributes: Option<String>,
}

/// 图片题注的编辑投影；正文仍属于原 caption 块的 Y.Text，格式与未知元数据留在 Doc 中。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollabImageCaption {
    pub id: String,
    pub text: String,
}

/// 图片布局与题注投影。尺寸为可选原始属性，None 不等于自动写入默认值。
/// wr 为相对正文宽度百分比，ar 为宽高比；width/height 为旧版像素尺寸，rotation 为角度。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CollabImage {
    pub width_ratio: Option<f64>,
    pub aspect_ratio: Option<f64>,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub rotation: Option<f64>,
    pub captions: Vec<CollabImageCaption>,
}

/// 正式有序列表投影；order 为零基，start 为归一化的一基起始编号。
/// heading/depth 共同划分计数器；既有同类型快照只读，只有 numbering_edit 能改变设置。
/// 新身份类型替换可从 numbering 初始化历史设置，order 仍由结构重算，不扩展 WS 协议。
#[derive(Debug, Clone, PartialEq)]
pub struct CollabOrdered {
    pub order: u32,
    pub start: Option<u32>,
    pub heading: u32,
    pub marker_style: Option<String>,
    pub needs_repair: bool,
    /// 仅 start/continuePrevious 的原始 JSON，保留缺失、null、0 和历史数值类型供撤销恢复。
    pub numbering: String,
    /// 显式设置事务的一次性输入；投影恒为 None，不把自动序号或旧设置当作用户命令。
    pub numbering_edit: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CollabCode {
    pub language: String,
    pub name: String,
    pub collapsed: bool,
    /// lang/blockName/collapse 原值，保留缺失和 null 以支持精确撤销。
    pub properties: String,
    /// 仅显式字段事务携带补丁；普通投影恒为 None。
    pub property_edits: Option<String>,
}

/// 资源块已建模属性的只读投影；只有显式字段补丁可写入原生 props。
#[derive(Debug, Clone, PartialEq)]
pub struct CollabResource {
    pub properties: String,
    pub property_edits: Option<String>,
}

pub(super) fn is_resource_block_type(kind: &str) -> bool {
    matches!(
        kind,
        "attachment" | "audio" | "bookmark" | "embed" | "juejin-embed" | "figma-embed"
    )
}

#[derive(Debug, Clone, PartialEq)]
pub struct CollabBlock {
    /// 段落族属性原始投影；既有块仅消费显式字段补丁，避免旧快照覆盖远端设置。
    pub paragraph_style: Option<CollabResource>,
    pub id: String,
    pub block_type: String,
    pub text: String,
    pub segments: Vec<CollabTextSegment>,
    pub checked: bool,
    pub alignment: String,
    pub indent: u32,
    /// 仅正式图片块携带；离线草稿与其他块为 None，不把题注展平为根子块。
    pub image: Option<CollabImage>,
    /// 仅正式 ordered 块携带；普通快照不覆盖设置，显式 numbering_edit 只写 start/continuePrevious。
    pub ordered: Option<CollabOrdered>,
    /// 代码块头部投影；只有 property_edits 可修改原生属性。
    pub code: Option<CollabCode>,
    pub resource: Option<CollabResource>,
    /// 本地类型转换的新身份所替换的旧 ID；成功后投影清空，不进入共享属性。
    pub replaces_id: Option<String>,
    /// 桌面 props.backColor / borderColor；CSS 原值，独立于行内高亮。
    pub block_background_color: Option<String>,
    pub block_border_color: Option<String>,
    /// 已适配高亮或表格结构的父 ID；根级为 None，正文保留独立 Y.Text。
    pub parent_id: Option<String>,
    /// 对应桌面 callout.props.prefix / color，不与行内格式混用。
    pub callout_prefix: Option<String>,
    pub block_text_color: Option<String>,
}

#[derive(Debug, Clone)]
pub struct OpenDocumentResult {
    pub blocks: Vec<CollabBlock>,
    pub persisted_update_count: u32,
    pub shared_type_name: String,
}

#[derive(Debug, Clone)]
pub struct BlockChangeResult {
    pub blocks: Vec<CollabBlock>,
    pub outbound_message: Vec<u8>,
    /// 未套 y-websocket 消息头的 Yjs V1 update，供 PaaS JSON 协议编码为 Base64。
    pub v1_update: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct WireMessageResult {
    pub blocks: Vec<CollabBlock>,
    pub reply: Vec<u8>,
    pub changed: bool,
    pub message_kind: String,
}

struct CollabEngine {
    /// Session-local history; the controller enables it after opening the document.
    history: Option<history::NativeHistory>,
    /// Borrowed local command context, cleared on either successful or failed apply.
    history_input: Option<history::HistoryInput>,
    document_id: String,
    database_path: String,
    doc: Doc,
    awareness: Awareness,
    block_order: ArrayRef,
    block_meta: MapRef,
    block_checked: MapRef,
    block_align: MapRef,
    block_indent: MapRef,
    block_colors: MapRef,
    connection: Connection,
    /// Some 时使用正式 blocks 根；值是业务 docId，不能以本机哈希缓存键替代。
    blockcraft_root_id: Option<String>,
    /// 本机初始化标记的正式根，打开时读取一次，避免每个协同增量查询SQLite。
    bootstrap_root_id: Option<String>,
}

impl CollabEngine {
    fn open(document_id: String, database_path: String) -> Result<(Self, u32), String> {
        if let Some(parent) = Path::new(&database_path).parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "cannot create local storage directory {}: {error}",
                    parent.display()
                )
            })?;
        }

        let connection = Connection::open(&database_path)
            .map_err(|error| format!("cannot open SQLite update log: {error}"))?;
        connection
            .execute_batch(
                "
                PRAGMA journal_mode = WAL;
                PRAGMA foreign_keys = ON;
                CREATE TABLE IF NOT EXISTS document_updates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    document_id TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_document_updates_document
                    ON document_updates(document_id, sequence);
                ",
            )
            .map_err(|error| format!("cannot initialize SQLite update log: {error}"))?;

        let doc = create_compatible_doc();
        let block_order = doc.get_or_insert_array(BLOCK_ORDER_NAME);
        let block_meta = doc.get_or_insert_map(BLOCK_META_NAME);
        let block_checked = doc.get_or_insert_map(BLOCK_CHECKED_NAME);
        let block_align = doc.get_or_insert_map(BLOCK_ALIGN_NAME);
        let block_indent = doc.get_or_insert_map(BLOCK_INDENT_NAME);
        let block_colors = doc.get_or_insert_map(BLOCK_COLORS_NAME);
        let updates = load_updates(&connection, &document_id)?;
        for payload in &updates {
            let update = Update::decode_v1(payload)
                .map_err(|error| format!("invalid persisted Yjs V1 update: {error}"))?;
            doc.transact_mut()
                .apply_update(update)
                .map_err(|error| format!("cannot apply persisted Yjs update: {error}"))?;
        }

        let bootstrap_root_id = document_bootstrap::protected_root(&connection, &document_id)?;
        let mut engine = Self {
            history: None,
            history_input: None,
            document_id,
            database_path,
            awareness: Awareness::new(doc.clone()),
            doc,
            block_order,
            block_meta,
            block_checked,
            block_align,
            block_indent,
            block_colors,
            connection,
            blockcraft_root_id: None,
            bootstrap_root_id,
        };
        let mut persisted_update_count = updates.len() as u32;
        // 仅清理旧私有草稿头部，正式 BlockCraft 的 blocks 共享类型完全不动。
        if engine.remove_legacy_headers()? {
            persisted_update_count += 1;
        }
        if engine.migrate_legacy_text()? {
            persisted_update_count += 1;
        }

        Ok((engine, persisted_update_count))
    }

    /// 读取正式文档或旧草稿投影，标题统一到 H1~H6，不改写旧块类型元数据。
    /// 旧草稿的缺失文字键仍取得共享文本句柄，正式文档读取交给 BlockCraft 投影。
    fn blocks(&self) -> Vec<CollabBlock> {
        if let Some(root_id) = &self.blockcraft_root_id {
            return blockcraft::project(&self.doc, root_id).blocks;
        }
        let ids = self.raw_block_ids();
        let text_refs = ids
            .iter()
            .map(|id| self.doc.get_or_insert_text(block_text_name(id)))
            .collect::<Vec<_>>();
        let transaction = self.doc.transact();
        let mut seen = HashSet::new();
        ids.into_iter()
            .zip(text_refs)
            .filter_map(|(id, text_ref)| {
                if !seen.insert(id.clone()) {
                    return None;
                }
                let block_type = out_string(self.block_meta.get(&transaction, &id))
                    .map(|kind| {
                        kind.strip_prefix("heading_")
                            .and_then(|level| level.parse::<u32>().ok())
                            .filter(|level| *level > 0)
                            .map(|level| format!("heading_{}", level.min(6)))
                            .unwrap_or(kind)
                    })
                    .filter(|value| is_supported_block_type(value))
                    .unwrap_or_else(|| "paragraph".to_owned());
                let checked = block_type == "todo_list"
                    && out_bool(self.block_checked.get(&transaction, &id)).unwrap_or(false);
                let alignment = out_string(self.block_align.get(&transaction, &id))
                    .filter(|value| is_supported_alignment(value))
                    .unwrap_or_else(|| "left".to_owned());
                let indent = if is_indentable_block_type(&block_type) {
                    out_u32(self.block_indent.get(&transaction, &id))
                        .unwrap_or(0)
                        .min(6)
                } else {
                    0
                };
                Some(CollabBlock {
                    paragraph_style: out_string(
                        self.block_colors
                            .get(&transaction, &format!("{id}:paragraph")),
                    )
                    .map(|properties| CollabResource {
                        properties,
                        property_edits: None,
                    }),
                    id: id.clone(),
                    block_type,
                    text: text_ref.get_string(&transaction),
                    segments: text_segments(&text_ref, &transaction),
                    checked,
                    alignment,
                    indent,
                    image: None,
                    ordered: None,
                    parent_id: out_string(
                        self.block_colors.get(&transaction, &format!("{id}:parent")),
                    ),
                    callout_prefix: out_string(
                        self.block_colors.get(&transaction, &format!("{id}:prefix")),
                    ),
                    block_text_color: out_string(
                        self.block_colors.get(&transaction, &format!("{id}:text")),
                    ),
                    code: None,
                    resource: out_string(
                        self.block_colors
                            .get(&transaction, &format!("{id}:resource")),
                    )
                    .map(|properties| CollabResource {
                        properties,
                        property_edits: None,
                    }),
                    replaces_id: None,
                    block_background_color: out_string(
                        self.block_colors
                            .get(&transaction, &format!("{id}:background")),
                    ),
                    block_border_color: out_string(
                        self.block_colors.get(&transaction, &format!("{id}:border")),
                    ),
                })
            })
            .collect()
    }

    /// Stage a metadata-only lock command, persist it, then advance the authoritative Doc.
    fn set_block_lock(
        &mut self,
        block_id: String,
        locked: bool,
        user_id: String,
        grant: bool,
        expected_owner: Option<String>,
        expected_template: bool,
    ) -> Result<BlockChangeResult, String> {
        let root = self
            .blockcraft_root_id
            .as_deref()
            .ok_or("BLOCK_LOCK_DENIED: 草稿不支持共享锁")?;
        blockcraft::validate(&self.doc, root)?;
        if let Some(reason) = blockcraft::project(&self.doc, root).reason {
            return Err(format!("READ_ONLY_DOCUMENT: {reason}"));
        }
        let before = self.doc.transact().state_vector();
        let staged = self.staged_document()?;
        block_locks::set(
            &staged,
            root,
            &block_id,
            locked,
            &user_id,
            grant,
            expected_owner.as_deref(),
            expected_template,
        )?;
        let update = staged.transact().encode_state_as_update_v1(&before);
        self.persist_and_apply_update(&update)?;
        Ok(BlockChangeResult {
            blocks: self.blocks(),
            v1_update: update.clone(),
            outbound_message: Message::Sync(SyncMessage::Update(update)).encode_v1(),
        })
    }

    fn raw_block_ids(&self) -> Vec<String> {
        let transaction = self.doc.transact();
        (0..self.block_order.len(&transaction))
            .filter_map(|index| out_string(self.block_order.get(&transaction, index)))
            .collect()
    }

    fn sync_step1(&self) -> Vec<u8> {
        let state_vector = self.doc.transact().state_vector();
        Message::Sync(SyncMessage::SyncStep1(state_vector)).encode_v1()
    }

    /// 在隔离文档生成 `blocks` 的更新，落盘成功后才推进权威Doc。
    /// 校验或SQLite失败不改变当前文档、向量及Awareness；返回成功快照及可上行增量。
    fn apply_block_snapshot(
        &mut self,
        blocks: Vec<CollabBlock>,
    ) -> Result<BlockChangeResult, String> {
        validate_blocks(&blocks, self.blockcraft_root_id.is_some())?;
        if let Some(root_id) = &self.blockcraft_root_id {
            let before = self.doc.transact().state_vector();
            let (staged, recording) = self.stage_local_history(&blocks)?;
            blockcraft::apply(&staged, root_id, &blocks)?;
            let update = staged.transact().encode_state_as_update_v1(&before);
            self.commit_local_history(staged, recording, &update)?;
            return Ok(BlockChangeResult {
                blocks: self.blocks(),
                v1_update: update.clone(),
                outbound_message: Message::Sync(SyncMessage::Update(update)).encode_v1(),
            });
        }
        let current_blocks = self.blocks();
        for block in &blocks {
            if !current_blocks.iter().any(|b| b.id == block.id) {
                if let Some(style) = &block.paragraph_style {
                    paragraph_style::parse(&style.properties, true)?;
                }
            }
        }
        let current_order = self.raw_block_ids();
        let desired_order = blocks
            .iter()
            .map(|block| block.id.clone())
            .collect::<Vec<_>>();
        if current_blocks == blocks && current_order == desired_order {
            return Ok(BlockChangeResult {
                blocks,
                outbound_message: Vec::new(),
                v1_update: Vec::new(),
            });
        }

        let (staged, recording) = self.stage_local_history(&blocks)?;
        let block_order = staged.get_or_insert_array(BLOCK_ORDER_NAME);
        let block_meta = staged.get_or_insert_map(BLOCK_META_NAME);
        let block_checked = staged.get_or_insert_map(BLOCK_CHECKED_NAME);
        let block_align = staged.get_or_insert_map(BLOCK_ALIGN_NAME);
        let block_indent = staged.get_or_insert_map(BLOCK_INDENT_NAME);
        let block_colors = staged.get_or_insert_map(BLOCK_COLORS_NAME);
        let text_refs = blocks
            .iter()
            .map(|block| staged.get_or_insert_text(block_text_name(&block.id)))
            .collect::<Vec<_>>();
        let (current_texts, current_segments) = {
            let transaction = staged.transact();
            let texts = text_refs
                .iter()
                .map(|text_ref| text_ref.get_string(&transaction))
                .collect::<Vec<_>>();
            let segments = text_refs
                .iter()
                .map(|text_ref| text_segments(text_ref, &transaction))
                .collect::<Vec<_>>();
            (texts, segments)
        };
        let before = staged.transact().state_vector();
        {
            let mut transaction = staged.transact_mut();
            reconcile_order(
                &block_order,
                &mut transaction,
                &current_order,
                &desired_order,
            );

            let desired_ids = desired_order.iter().cloned().collect::<HashSet<_>>();
            for id in current_order {
                if !desired_ids.contains(&id) {
                    block_meta.remove(&mut transaction, &id);
                    block_checked.remove(&mut transaction, &id);
                    block_align.remove(&mut transaction, &id);
                    block_indent.remove(&mut transaction, &id);
                    block_colors.remove(&mut transaction, &format!("{id}:background"));
                    block_colors.remove(&mut transaction, &format!("{id}:border"));
                    for suffix in ["parent", "prefix", "text", "resource", "paragraph"] {
                        block_colors.remove(&mut transaction, &format!("{id}:{suffix}"));
                    }
                }
            }

            for (((block, text_ref), current_text), current_segments) in blocks
                .iter()
                .zip(text_refs.iter())
                .zip(current_texts.iter())
                .zip(current_segments.iter())
            {
                block_meta.try_update(&mut transaction, block.id.clone(), block.block_type.clone());
                block_checked.try_update(&mut transaction, block.id.clone(), block.checked);
                block_align.try_update(&mut transaction, block.id.clone(), block.alignment.clone());
                block_indent.try_update(&mut transaction, block.id.clone(), block.indent as i64);
                for (suffix, color) in [
                    ("background", &block.block_background_color),
                    ("border", &block.block_border_color),
                    ("parent", &block.parent_id),
                    ("prefix", &block.callout_prefix),
                    ("text", &block.block_text_color),
                ] {
                    let key = format!("{}:{suffix}", block.id);
                    if let Some(color) = color {
                        block_colors.try_update(&mut transaction, key, color.clone());
                    } else {
                        block_colors.remove(&mut transaction, &key);
                    }
                }
                if let Some(style) = &block.paragraph_style {
                    let key = format!("{}:paragraph", block.id);
                    let before = out_string(block_colors.get(&transaction, &key))
                        .unwrap_or_else(|| "{}".into());
                    let mut values: std::collections::BTreeMap<String, Any> =
                        serde_json::from_str(&before).unwrap_or_default();
                    let edits = if current_blocks.iter().any(|b| b.id == block.id) {
                        style
                            .property_edits
                            .as_deref()
                            .map(|s| paragraph_style::parse(s, false))
                            .transpose()?
                    } else {
                        Some(paragraph_style::parse(&style.properties, true)?)
                    };
                    if let Some(edits) = edits {
                        for (key, value) in edits {
                            if let Some(v) = value {
                                values.insert(key, v);
                            } else {
                                values.remove(&key);
                            }
                        }
                        block_colors.try_update(
                            &mut transaction,
                            key,
                            serde_json::to_string(&values).unwrap(),
                        );
                    }
                }
                let key = format!("{}:resource", block.id);
                if let Some(resource) = &block.resource {
                    block_colors.try_update(&mut transaction, key, resource.properties.clone());
                } else {
                    block_colors.remove(&mut transaction, &key);
                }
                let delta = compute_text_delta(current_text, &block.text);
                if delta.delete_length > 0 {
                    text_ref.remove_range(&mut transaction, delta.index, delta.delete_length);
                }
                if !delta.insert_text.is_empty() {
                    text_ref.insert(&mut transaction, delta.index, &delta.insert_text);
                }
                if current_segments != block.segments.as_slice() {
                    apply_text_segments(text_ref, &mut transaction, block);
                }
            }
        }

        let update = staged.transact().encode_state_as_update_v1(&before);
        self.commit_local_history(staged, recording, &update)?;
        Ok(BlockChangeResult {
            blocks: self.blocks(),
            v1_update: update.clone(),
            outbound_message: Message::Sync(SyncMessage::Update(update)).encode_v1(),
        })
    }

    /// 在隔离 Doc 中验证结构，再应用正文。正式模式保留 blocks 和修订等辅助根，
    /// 不能完整表达的内容投影为只读；旧 Demo 模式继续使用独立根名称的边界检查。
    ///
    /// 未写入内容的旧引擎可在第一次收到合法 BlockCraft 根时识别正式模型。
    /// 校验失败不改变当前 Doc/SQLite，正式业务 docId 与缓存键由打开 API 分别提供。
    fn apply_cses_update(&mut self, payload: Vec<u8>) -> Result<WireMessageResult, String> {
        document_bootstrap::guard_remote(self, &payload)?;
        let probe = create_compatible_doc();
        let local = self
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        {
            let mut txn = probe.transact_mut();
            txn.apply_update(Update::decode_v1(&local).map_err(|error| error.to_string())?)
                .map_err(|error| error.to_string())?;
            txn.apply_update(
                Update::decode_v1(&payload)
                    .map_err(|error| format!("invalid Yjs V1 update: {error}"))?,
            )
            .map_err(|error| format!("cannot validate remote update: {error}"))?;
        }
        let root_id = self.blockcraft_root_id.clone().or_else(|| {
            if !probe
                .transact()
                .root_refs()
                .any(|(name, _)| name == blockcraft::ROOT_NAME)
            {
                return None;
            }
            let txn = probe.transact();
            if txn
                .get_map(blockcraft::ROOT_NAME)
                .is_some_and(|blocks| blocks.len(&txn) > 0)
                && self.raw_block_ids().is_empty()
            {
                Some(self.document_id.clone())
            } else {
                None
            }
        });
        if let Some(root_id) = root_id {
            blockcraft::validate(&probe, &root_id)?;
            return self.apply_remote_update(payload, "collabUpdate", Some(root_id));
        }
        let compatible = probe.transact().root_refs().all(|(name, _)| {
            matches!(
                name,
                BLOCK_ORDER_NAME
                    | BLOCK_META_NAME
                    | BLOCK_CHECKED_NAME
                    | BLOCK_ALIGN_NAME
                    | BLOCK_INDENT_NAME
                    | BLOCK_COLORS_NAME
                    | LEGACY_TEXT_NAME
            ) || name.starts_with(BLOCK_TEXT_PREFIX)
        });
        if !compatible {
            return Err(
                "UNSUPPORTED_DOCUMENT_SCHEMA: 本地草稿不能混入未知正文结构，请使用正式文档模式"
                    .to_owned(),
            );
        }
        self.apply_remote_update(payload, "collabUpdate", None)
    }

    fn handle_wire_message(&mut self, bytes: Vec<u8>) -> Result<WireMessageResult, String> {
        let message = Message::decode_v1(&bytes)
            .map_err(|error| format!("invalid y-websocket message: {error}"))?;

        match message {
            Message::Sync(SyncMessage::SyncStep1(remote_state_vector)) => {
                let update = self
                    .doc
                    .transact()
                    .encode_state_as_update_v1(&remote_state_vector);
                Ok(WireMessageResult {
                    blocks: self.blocks(),
                    reply: Message::Sync(SyncMessage::SyncStep2(update)).encode_v1(),
                    changed: false,
                    message_kind: "sync-step-1".to_owned(),
                })
            }
            Message::Sync(SyncMessage::SyncStep2(update)) => {
                self.apply_remote_update(update, "sync-step-2", None)
            }
            Message::Sync(SyncMessage::Update(update)) => {
                self.apply_remote_update(update, "sync-update", None)
            }
            Message::Awareness(_) => Ok(self.ignored_message("awareness")),
            Message::AwarenessQuery => Ok(self.ignored_message("awareness-query")),
            Message::Auth(reason) => {
                if let Some(reason) = reason {
                    Err(format!("server denied y-websocket access: {reason}"))
                } else {
                    Ok(self.ignored_message("auth-granted"))
                }
            }
            Message::Custom(tag, _) => Ok(self.ignored_message(&format!("custom-{tag}"))),
        }
    }

    /// 将已校验的 `payload` 先落盘再应用，按 `message_kind` 返回投影结果。
    /// `root_id` 为首次识别的正式根；None保留当前模型，落盘失败不切换模型或推进向量。
    fn apply_remote_update(
        &mut self,
        payload: Vec<u8>,
        message_kind: &str,
        root_id: Option<String>,
    ) -> Result<WireMessageResult, String> {
        let before = self.blocks();
        self.persist_and_apply_update(&payload)?;
        if let Some(root_id) = root_id {
            self.blockcraft_root_id = Some(root_id);
        }
        let blocks = self.blocks();
        Ok(WireMessageResult {
            changed: blocks != before,
            blocks,
            reply: Vec::new(),
            message_kind: message_kind.to_owned(),
        })
    }

    fn ignored_message(&self, message_kind: &str) -> WireMessageResult {
        WireMessageResult {
            blocks: self.blocks(),
            reply: Vec::new(),
            changed: false,
            message_kind: message_kind.to_owned(),
        }
    }

    // 从旧草稿的原始类型识别头部，不能按 ID 删除，避免误删同名正文。
    // 通过已有快照事务清理顺序及属性并持久化；正文富文本和父子关系原样保留。
    fn remove_legacy_headers(&mut self) -> Result<bool, String> {
        let removed = {
            let txn = self.doc.transact();
            self.raw_block_ids()
                .into_iter()
                .filter(|id| {
                    matches!(
                        out_string(self.block_meta.get(&txn, id)).as_deref(),
                        Some("document_cover" | "document_title")
                    )
                })
                .collect::<HashSet<_>>()
        };
        if removed.is_empty() {
            return Ok(false);
        }
        let body = self
            .blocks()
            .into_iter()
            .filter(|block| !removed.contains(&block.id))
            .collect();
        self.apply_block_snapshot(body)?;
        Ok(true)
    }

    fn migrate_legacy_text(&mut self) -> Result<bool, String> {
        if !self.blocks().is_empty() {
            return Ok(false);
        }
        let legacy_text = self.doc.get_or_insert_text(LEGACY_TEXT_NAME);
        let text = legacy_text.get_string(&self.doc.transact());
        if text.is_empty() {
            return Ok(false);
        }
        self.apply_block_snapshot(vec![CollabBlock {
            paragraph_style: None,
            id: LEGACY_BLOCK_ID.to_owned(),
            block_type: "paragraph".to_owned(),
            text,
            segments: Vec::new(),
            checked: false,
            alignment: "left".to_owned(),
            indent: 0,
            image: None,
            ordered: None,
            parent_id: None,
            callout_prefix: None,
            block_text_color: None,
            code: None,
            resource: None,
            replaces_id: None,
            block_background_color: None,
            block_border_color: None,
        }])?;
        Ok(true)
    }

    /// 复制当前完整状态及待整合增量以隔离本地编辑；UTF-16、GC及clientID与权威Doc一致。
    /// 保留原生历史的恢复关联；临时副本不发布Awareness或网络消息。
    /// 系统写入只整合落盘更新，显式历史写入则在提交后安装完整候选Doc及历史。
    fn staged_document(&self) -> Result<Doc, String> {
        self.doc.fork_for_history()
    }

    /// 解码已校验的 `payload`，SQLite成功后在同一引擎锁内推进权威Doc。
    /// 空字节无操作；落盘失败不消费更新。成功落盘但异常整合失败时保留日志供重开恢复。
    fn persist_and_apply_update(&mut self, payload: &[u8]) -> Result<(), String> {
        if payload.is_empty() {
            return Ok(());
        }
        let update = Update::decode_v1(payload)
            .map_err(|error| format!("invalid Yjs V1 update: {error}"))?;
        self.persist_update(payload)?;
        self.doc
            .transact_mut_with(history::REMOTE_ORIGIN)
            .apply_update(update)
            .map_err(|error| format!("cannot apply persisted Yjs update: {error}"))
    }

    /// 将 `payload` 追加到当前缓存分区；成功返回后SQLite已提交，失败不改变Doc。
    fn persist_update(&self, payload: &[u8]) -> Result<(), String> {
        if payload.is_empty() {
            return Ok(());
        }
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|error| format!("cannot persist Yjs update: {error}"))?;
        transaction
            .execute(
                "INSERT INTO document_updates(document_id, payload) VALUES (?1, ?2)",
                params![self.document_id, payload],
            )
            .map_err(|error| format!("cannot persist Yjs update: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("cannot persist Yjs update: {error}"))?;
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
struct TextDelta {
    index: u32,
    delete_length: u32,
    insert_text: String,
}

fn compute_text_delta(current: &str, next: &str) -> TextDelta {
    let current_chars = current.chars().collect::<Vec<_>>();
    let next_chars = next.chars().collect::<Vec<_>>();
    let mut prefix = 0;
    while prefix < current_chars.len()
        && prefix < next_chars.len()
        && current_chars[prefix] == next_chars[prefix]
    {
        prefix += 1;
    }

    let mut suffix = 0;
    while suffix < current_chars.len().saturating_sub(prefix)
        && suffix < next_chars.len().saturating_sub(prefix)
        && current_chars[current_chars.len() - 1 - suffix]
            == next_chars[next_chars.len() - 1 - suffix]
    {
        suffix += 1;
    }

    TextDelta {
        index: utf16_len(&current_chars[..prefix]),
        delete_length: utf16_len(&current_chars[prefix..current_chars.len() - suffix]),
        insert_text: next_chars[prefix..next_chars.len() - suffix]
            .iter()
            .collect(),
    }
}

fn utf16_len(chars: &[char]) -> u32 {
    chars
        .iter()
        .map(|character| character.len_utf16() as u32)
        .sum()
}

fn reconcile_order(
    order: &ArrayRef,
    transaction: &mut yrs::TransactionMut<'_>,
    current: &[String],
    desired: &[String],
) {
    if current == desired {
        return;
    }
    let mut prefix = 0;
    while prefix < current.len() && prefix < desired.len() && current[prefix] == desired[prefix] {
        prefix += 1;
    }

    let mut suffix = 0;
    while suffix < current.len().saturating_sub(prefix)
        && suffix < desired.len().saturating_sub(prefix)
        && current[current.len() - 1 - suffix] == desired[desired.len() - 1 - suffix]
    {
        suffix += 1;
    }

    let remove_length = current.len() - prefix - suffix;
    if remove_length > 0 {
        order.remove_range(transaction, prefix as u32, remove_length as u32);
    }
    order.insert_range(
        transaction,
        prefix as u32,
        desired[prefix..desired.len() - suffix].iter().cloned(),
    );
}

fn block_text_name(block_id: &str) -> String {
    if block_id == LEGACY_BLOCK_ID {
        LEGACY_TEXT_NAME.to_owned()
    } else {
        format!("{BLOCK_TEXT_PREFIX}{block_id}")
    }
}

fn out_string(value: Option<Out>) -> Option<String> {
    match value? {
        Out::Any(Any::String(value)) => Some(value.to_string()),
        _ => None,
    }
}

fn out_bool(value: Option<Out>) -> Option<bool> {
    match value? {
        Out::Any(Any::Bool(value)) => Some(value),
        _ => None,
    }
}

fn out_u32(value: Option<Out>) -> Option<u32> {
    match value? {
        Out::Any(Any::BigInt(value)) if value >= 0 => u32::try_from(value).ok(),
        Out::Any(Any::Number(value)) if value >= 0.0 => Some(value as u32),
        _ => None,
    }
}

fn text_segments<T: ReadTxn>(text_ref: &yrs::TextRef, transaction: &T) -> Vec<CollabTextSegment> {
    text_segments_for_schema(text_ref, transaction, false)
}

/// 共同的富文本投影；formal 选择 BlockCraft 的 a:/s: 键，未建模属性仍留在原 Y.Text。
fn text_segments_for_schema<T: ReadTxn>(
    text_ref: &yrs::TextRef,
    transaction: &T,
    formal: bool,
) -> Vec<CollabTextSegment> {
    let mut segments = text_ref
        .diff(transaction, |_| ())
        .into_iter()
        .filter_map(|chunk| {
            let inline_latex = formal.then(|| inline_latex_value(&chunk.insert)).flatten();
            let mention = formal
                .then(|| inline_mention_identity(&chunk.insert, chunk.attributes.as_deref()))
                .flatten();
            let text = match chunk.insert {
                Out::Any(Any::String(value)) => value.to_string(),
                _ if inline_latex.is_some() || mention.is_some() => "\u{fffc}".into(),
                _ => return None,
            };
            let attributes = chunk.attributes.as_deref();
            Some(CollabTextSegment {
                typography: paragraph_style::read_typography(chunk.attributes.as_deref()),
                href: attribute_string(attributes, schema_attribute("href", formal)),
                inline_latex,
                inline_mention: mention.as_ref().map(|m| m.0.clone()),
                mention_id: mention.as_ref().map(|m| m.1.clone()),
                mention_type: mention
                    .as_ref()
                    .and_then(|m| (m.2 != "user").then(|| m.2.clone())),
                mention_attributes: mention
                    .as_ref()
                    .map(|_| serialized_mention_attributes(chunk.attributes.as_deref())),
                text,
                bold: attribute_enabled(attributes, schema_attribute("bold", formal)),
                italic: attribute_enabled(attributes, schema_attribute("italic", formal)),
                underline: attribute_enabled(attributes, schema_attribute("underline", formal)),
                strikethrough: attribute_enabled(
                    attributes,
                    schema_attribute("strikethrough", formal),
                ),
                code: attribute_enabled(attributes, schema_attribute("code", formal)),
                text_color: attribute_string(attributes, schema_attribute("textColor", formal)),
                // The collaborative schema uses a stable camelCase name while
                // Flutter maps it to AppFlowy's package-specific `bg_color`.
                background_color: attribute_string(
                    attributes,
                    schema_attribute("backgroundColor", formal),
                ),
                superscript: attribute_enabled(
                    attributes,
                    schema_attribute("cses_superscript", formal),
                ),
                subscript: attribute_enabled(
                    attributes,
                    schema_attribute("cses_subscript", formal),
                ),
            })
        })
        .collect::<Vec<_>>();
    if !segments.iter().any(CollabTextSegment::is_styled) {
        segments.clear();
    }
    segments
}

/// 识别桌面唯一键为 latex 的字符串 embed，其他对象不进入可编辑投影。
fn inline_latex_value(value: &Out) -> Option<String> {
    match value {
        Out::Any(Any::Map(values)) if values.len() == 1 => match values.get("latex") {
            Some(Any::String(latex)) => Some(latex.to_string()),
            _ => None,
        },
        _ => None,
    }
}

/// 单键 mention 字符串按明确 user/meeting/task/doc 类型及稳定身份读取，兼容历史 d: 前缀。
/// 未知类型、缺身份或过大的实体属性继续交由段落级保护处理。
fn inline_mention_identity(value: &Out, attrs: Option<&Attrs>) -> Option<(String, String, String)> {
    let Out::Any(Any::Map(values)) = value else {
        return None;
    };
    if values.len() != 1 {
        return None;
    }
    let Some(Any::String(name)) = values.get("mention") else {
        return None;
    };
    let kind = attribute_string(attrs, "mentionType")
        .filter(|v| !v.is_empty())
        .or_else(|| attribute_string(attrs, "d:mentionType"))?;
    let id = attribute_string(attrs, "mentionId")
        .filter(|v| !v.is_empty())
        .or_else(|| attribute_string(attrs, "d:mentionId"))?;
    if !matches!(kind.as_str(), "user" | "meeting" | "task" | "doc")
        || id.is_empty()
        || serialized_mention_attributes(attrs).len() > 65_536
    {
        return None;
    }
    Some((name.to_string(), id, kind))
}

/// 借用原始属性并按键排序编码，避免同一元数据因哈希迭代顺序造成伪冲突。
fn serialized_mention_attributes(attrs: Option<&Attrs>) -> String {
    let sorted: std::collections::BTreeMap<_, _> =
        attrs.into_iter().flat_map(|a| a.iter()).collect();
    let value = serde_json::to_value(&sorted).expect("Yrs原子属性可编码JSON");
    serde_json::to_string(&canonical_mention_value(value)).expect("JSON值可重新编码")
}

/// 对嵌套对象递归排序，状态等子对象不因HashMap迭代顺序产生虚假的历史冲突。
fn canonical_mention_value(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => {
            let sorted: std::collections::BTreeMap<_, _> = map
                .into_iter()
                .map(|(k, v)| (k, canonical_mention_value(v)))
                .collect();
            serde_json::Value::Object(sorted.into_iter().collect())
        }
        serde_json::Value::Array(values) => {
            serde_json::Value::Array(values.into_iter().map(canonical_mention_value).collect())
        }
        other => other,
    }
}

/// 只在新插入/历史恢复实体时使用完整属性；现存对象不接受投影覆盖业务元数据。
fn restored_mention_attributes(segment: &CollabTextSegment) -> Attrs {
    segment
        .mention_attributes
        .as_ref()
        .and_then(|v| serde_json::from_str(v).ok())
        .unwrap_or_default()
}

/// 检查四类提及的属性快照与声明身份一致，拒绝缺失、超限或伪造类型/ID。
fn valid_entity_attributes(segment: &CollabTextSegment) -> bool {
    let Some(data) = segment
        .mention_attributes
        .as_ref()
        .filter(|v| v.len() <= 65_536)
    else {
        return false;
    };
    let Ok(attrs) = serde_json::from_str::<Attrs>(data) else {
        return false;
    };
    let kind = attribute_string(Some(&attrs), "mentionType")
        .filter(|v| !v.is_empty())
        .or_else(|| attribute_string(Some(&attrs), "d:mentionType"));
    let id = attribute_string(Some(&attrs), "mentionId")
        .filter(|v| !v.is_empty())
        .or_else(|| attribute_string(Some(&attrs), "d:mentionId"));
    kind.as_deref() == Some(segment.mention_type.as_deref().unwrap_or("user"))
        && id == segment.mention_id
}

/// 原生行内对象的完整语义身份，用于差量对齐；不把 U+FFFC 文本当成对象。
#[derive(Debug, Clone, PartialEq, Eq)]
enum InlineEmbed {
    Latex(String),
    User(String, String),
    Entity(String, String, String),
}

/// 从借用的原生值/属性提取已支持的对象身份。
fn inline_embed(value: &Out, attrs: Option<&Attrs>) -> Option<InlineEmbed> {
    inline_latex_value(value)
        .map(InlineEmbed::Latex)
        .or_else(|| {
            inline_mention_identity(value, attrs).map(|(name, id, kind)| {
                if kind != "user" {
                    InlineEmbed::Entity(kind, name, id)
                } else {
                    InlineEmbed::User(name, id)
                }
            })
        })
}

/// 从已验证的片段提取对象身份。
fn segment_embed(segment: &CollabTextSegment) -> Option<InlineEmbed> {
    segment
        .inline_latex
        .clone()
        .map(InlineEmbed::Latex)
        .or_else(|| {
            let name = segment.inline_mention.clone()?;
            let id = segment.mention_id.clone()?;
            Some(
                if let Some(kind @ ("meeting" | "task" | "doc")) = segment.mention_type.as_deref() {
                    InlineEmbed::Entity(kind.into(), name, id)
                } else {
                    InlineEmbed::User(name, id)
                },
            )
        })
}

/// 将对象恢复为桌面单键map；同身份属性原样保留历史键形态，新对象补齐实体身份。
fn embed_value(embed: &InlineEmbed, attrs: &mut Attrs) -> Any {
    let (key, value) = match embed {
        InlineEmbed::Latex(latex) => ("latex", latex),
        InlineEmbed::User(name, id) | InlineEmbed::Entity(_, name, id) => {
            let kind = match embed {
                InlineEmbed::Entity(kind, _, _) => kind.as_str(),
                _ => "user",
            };
            let current_kind = attribute_string(Some(attrs), "mentionType")
                .filter(|v| !v.is_empty())
                .or_else(|| attribute_string(Some(attrs), "d:mentionType"));
            let current_id = attribute_string(Some(attrs), "mentionId")
                .filter(|v| !v.is_empty())
                .or_else(|| attribute_string(Some(attrs), "d:mentionId"));
            if current_kind.as_deref() != Some(kind) || current_id.as_ref() != Some(id) {
                attrs.insert("mentionType".into(), Any::String(kind.into()));
                if attrs.contains_key("d:mentionType") {
                    attrs.insert("d:mentionType".into(), Any::String(kind.into()));
                }
                attrs.insert("mentionId".into(), Any::String(id.clone().into()));
                if attrs.contains_key("d:mentionId") {
                    attrs.insert("d:mentionId".into(), Any::String(id.clone().into()));
                }
            }
            ("mention", name)
        }
    };
    Any::Map(std::sync::Arc::new(std::collections::HashMap::from([(
        key.into(),
        Any::String(value.clone().into()),
    )])))
}

/// 将混合 Y.Text 投影为 UTF-16 定位文本；每个非文字对象占一个 U+FFFC。
/// 未适配对象仍由调用方施加只读保护，此函数不解包或覆盖它们。
fn projected_inline_text<T: ReadTxn>(text: &yrs::TextRef, txn: &T) -> String {
    text.diff(txn, |_| ())
        .into_iter()
        .map(|chunk| match chunk.insert {
            Out::Any(Any::String(value)) => value.to_string(),
            _ => "\u{fffc}".into(),
        })
        .collect()
}

fn attribute_enabled(attributes: Option<&Attrs>, key: &str) -> bool {
    matches!(
        attributes.and_then(|attributes| attributes.get(key)),
        Some(Any::Bool(true))
    )
}

fn attribute_string(attributes: Option<&Attrs>, key: &str) -> Option<String> {
    match attributes.and_then(|attributes| attributes.get(key)) {
        Some(Any::String(value)) => Some(value.to_string()),
        _ => None,
    }
}

impl CollabTextSegment {
    fn is_styled(&self) -> bool {
        self.typography.is_some()
            || self.href.is_some()
            || self.bold
            || self.italic
            || self.underline
            || self.strikethrough
            || self.code
            || self.text_color.is_some()
            || self.background_color.is_some()
            || self.superscript
            || self.subscript
            || self.inline_latex.is_some()
            || self.inline_mention.is_some()
    }

    fn attributes(&self) -> Attrs {
        let mut attributes =
            paragraph_style::typography(self.typography.as_deref()).unwrap_or_default();
        if let Some(href) = &self.href {
            attributes.insert("href".into(), Any::String(href.clone().into()));
        }
        for (key, enabled) in [
            ("bold", self.bold),
            ("italic", self.italic),
            ("underline", self.underline),
            ("strikethrough", self.strikethrough),
            ("code", self.code),
            ("cses_superscript", self.superscript),
            ("cses_subscript", self.subscript),
        ] {
            if enabled {
                attributes.insert(key.into(), Any::Bool(true));
            }
        }
        if let Some(text_color) = &self.text_color {
            attributes.insert("textColor".into(), Any::String(text_color.clone().into()));
        }
        if let Some(background_color) = &self.background_color {
            // Preserve the alpha channel in the string value; Yrs treats the
            // color as opaque metadata and does not reinterpret the payload.
            attributes.insert(
                "backgroundColor".into(),
                Any::String(background_color.clone().into()),
            );
        }
        attributes
    }
}

fn apply_text_segments(
    text_ref: &yrs::TextRef,
    transaction: &mut yrs::TransactionMut<'_>,
    block: &CollabBlock,
) {
    apply_text_segments_for_schema(text_ref, transaction, block, false);
}

/// 受支持格式（含链接）只清除自己的键；字体、提及或其他未知属性保持原样。
fn apply_text_segments_for_schema(
    text_ref: &yrs::TextRef,
    transaction: &mut yrs::TransactionMut<'_>,
    block: &CollabBlock,
    formal: bool,
) {
    let length = block.text.encode_utf16().count() as u32;
    if length == 0 {
        return;
    }
    let mut clear_attributes: Attrs = Attrs::from([
        // Every supported rich-text attribute is explicitly cleared before
        // replaying canonical segments, preventing removed remote highlights
        // from surviving on a peer that previously formatted the same range.
        ("href".into(), Any::Null),
        ("bold".into(), Any::Null),
        ("italic".into(), Any::Null),
        ("underline".into(), Any::Null),
        ("strikethrough".into(), Any::Null),
        ("code".into(), Any::Null),
        ("textColor".into(), Any::Null),
        ("backgroundColor".into(), Any::Null),
        ("cses_superscript".into(), Any::Null),
        ("cses_subscript".into(), Any::Null),
    ])
    .into_iter()
    .map(|(key, value)| (schema_attribute(&key, formal).into(), value))
    .collect();
    for key in paragraph_style::TYPOGRAPHY_KEYS {
        clear_attributes.insert((*key).into(), Any::Null);
    }
    text_ref.format(transaction, 0, length, clear_attributes);

    let mut offset = 0;
    for segment in &block.segments {
        let segment_length = segment.text.encode_utf16().count() as u32;
        if segment_length > 0 && segment.is_styled() {
            let attributes = segment
                .attributes()
                .into_iter()
                .map(|(key, value)| (schema_attribute(&key, formal).into(), value))
                .collect();
            text_ref.format(transaction, offset, segment_length, attributes);
        }
        offset += segment_length;
    }
}

/// 两种编辑器的格式命名映射；其余键保持原样，不创建第二份正文。
fn schema_attribute(key: &str, formal: bool) -> &str {
    if !formal {
        return key;
    }
    match key {
        "href" => "a:link",
        "bold" => "a:bold",
        "italic" => "a:italic",
        "underline" => "a:underline",
        "strikethrough" => "a:strike",
        "code" => "a:code",
        "textColor" => "s:color",
        "backgroundColor" => "s:background",
        "cses_superscript" => "a:sup",
        "cses_subscript" => "a:sub",
        _ => key,
    }
}

/// 在事务之前验证投影身份、父子顺序和块专属约束，失败不会修改共享状态。
/// Mermaid 使用唯一的纯文本源码子块，容器及源码仅用于正式文档；KR引用同样仅用于正式文档且无正文。
fn validate_blocks(blocks: &[CollabBlock], allow_placeholders: bool) -> Result<(), String> {
    let by_id: HashMap<_, _> = blocks.iter().map(|b| (b.id.as_str(), b)).collect();
    let mut by_parent = HashMap::<&str, Vec<&CollabBlock>>::new();
    for block in blocks {
        if let Some(parent) = block.parent_id.as_deref() {
            by_parent.entry(parent).or_default().push(block);
        }
    }
    let mut ids = HashSet::new();
    let mut ancestors = Vec::<&str>::new();
    for block in blocks {
        for segment in &block.segments {
            paragraph_style::typography(segment.typography.as_deref())?;
        }
        if let Some(style) = &block.paragraph_style {
            if let Some(edits) = &style.property_edits {
                paragraph_style::parse(edits, false)?;
            }
        }
        if block.id.trim().is_empty() {
            return Err("block id must not be empty".to_owned());
        }
        if !ids.insert(block.id.as_str()) {
            return Err(format!("duplicate block id: {}", block.id));
        }
        if let Some(parent) = block.parent_id.as_deref() {
            let position = ancestors
                .iter()
                .position(|id| *id == parent)
                .ok_or("INVALID_BLOCK_PARENT: 父块必须是前序已适配容器")?;
            ancestors.truncate(position + 1);
        } else {
            ancestors.clear();
        }
        if matches!(
            block.block_type.as_str(),
            "date-card" | "divider" | "page-divider" | "formula" | "meeting" | "task" | "kr-list"
        ) && (!block.text.is_empty() || !block.segments.is_empty())
        {
            return Err(if block.block_type == "date-card" {
                "INVALID_DATE_CARD: 日期卡片不能存储正文".into()
            } else if block.block_type == "page-divider" {
                "INVALID_PAGE_DIVIDER: 分页符不能存储正文".into()
            } else if block.block_type == "kr-list" {
                "INVALID_KR_LIST: KR引用不能存储正文".into()
            } else if block.block_type == "task" {
                "INVALID_TASK: 任务卡片不能存储正文".into()
            } else if block.block_type == "meeting" {
                "INVALID_MEETING: 会议卡片不能存储正文".into()
            } else if block.block_type == "formula" {
                "INVALID_FORMULA: 公式不能存储正文".into()
            } else {
                "INVALID_DIVIDER: 分割线不能存储正文".into()
            });
        }
        if block.block_type == "page-divider" && (!allow_placeholders || block.parent_id.is_some())
        {
            return Err("INVALID_PAGE_DIVIDER: 分页符仅用于正式文档根节点".into());
        }
        if matches!(
            block.block_type.as_str(),
            "table" | "table-row" | "table-cell" | "mermaid" | "mermaid-textarea" | "kr-list"
        ) && !allow_placeholders
        {
            return Err("UNSUPPORTED_BLOCK_TYPE: 表格和代码绘图仅用于正式文档".into());
        }
        if matches!(
            block.block_type.as_str(),
            "callout" | "table" | "table-row" | "table-cell" | "mermaid"
        ) {
            if !block.text.is_empty() || !block.segments.is_empty() || ancestors.len() >= 256 {
                return Err("INVALID_CALLOUT: 高亮容器不能直接存储正文或超出嵌套限制".into());
            }
            ancestors.push(&block.id);
        } else if block.callout_prefix.is_some() || block.block_text_color.is_some() {
            return Err("INVALID_CALLOUT: 表情和容器文字颜色仅适用于高亮块".into());
        }
        if block.callout_prefix.as_ref().is_some_and(|v| v.len() > 256) {
            return Err("INVALID_CALLOUT: 表情过长".into());
        }
        if block.block_type == "mermaid" {
            let children = by_parent
                .get(block.id.as_str())
                .map_or(&[][..], Vec::as_slice);
            if children.len() != 1 || children[0].block_type != "mermaid-textarea" {
                return Err("INVALID_MERMAID: 绘图必须包含一个源码子块".into());
            }
        }
        if block.block_type == "mermaid-textarea" {
            if !block
                .parent_id
                .as_ref()
                .and_then(|id| by_id.get(id.as_str()))
                .is_some_and(|b| b.block_type == "mermaid")
                || block.text.encode_utf16().count() > 100_000
                || block
                    .segments
                    .iter()
                    .any(|s| s.inline_latex.is_some() || s.inline_mention.is_some())
            {
                return Err("INVALID_MERMAID: 源码父块、长度或内容无效".into());
            }
        }
        if !is_supported_block_type(&block.block_type)
            && !(allow_placeholders && block.block_type == blockcraft::UNSUPPORTED_BLOCK_TYPE)
        {
            return Err(format!("UNSUPPORTED_BLOCK_TYPE: {}", block.block_type));
        }
        if block
            .ordered
            .as_ref()
            .is_some_and(|ordered| ordered.heading > 6)
        {
            return Err("INVALID_HEADING_LEVEL: 标题级别不能超过6".into());
        }
        if block.segments.iter().any(|segment| {
            segment.inline_latex.as_ref().is_some_and(|latex| {
                segment.text != "\u{fffc}"
                    || latex.encode_utf16().count() > 20_000
                    || block.block_type == "code"
            })
        }) {
            return Err("INVALID_INLINE_FORMULA: 行内公式位置或长度无效".into());
        }
        if block.segments.iter().any(|s| {
            s.inline_mention.is_some() != s.mention_id.is_some()
                || s.mention_type.as_ref().is_some_and(|kind| {
                    !matches!(kind.as_str(), "user" | "meeting" | "task" | "doc")
                })
                || (s.mention_type.is_some() && s.inline_mention.is_none())
                || (s.mention_attributes.is_some() && !valid_entity_attributes(s))
                || (matches!(s.mention_type.as_deref(), Some("meeting" | "task" | "doc"))
                    && !valid_entity_attributes(s))
                || s.inline_mention.as_ref().is_some_and(|name| {
                    s.text != "\u{fffc}"
                        || name.encode_utf16().count() > 20_000
                        || s.mention_id
                            .as_ref()
                            .is_none_or(|id| id.is_empty() || id.len() > 512)
                        || s.inline_latex.is_some()
                        || block.block_type == "code"
                })
        }) {
            return Err("INVALID_INLINE_MENTION: 实体提及位置或身份无效".into());
        }
        if !allow_placeholders && block.segments.iter().any(|s| segment_embed(s).is_some()) {
            return Err("INVALID_INLINE_FORMULA: 行内公式仅用于正式文档".into());
        }
        if !block.segments.is_empty()
            && block
                .segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<String>()
                != block.text
        {
            return Err(format!(
                "rich-text segments do not match block text: {}",
                block.id
            ));
        }
        if block
            .segments
            .iter()
            .any(|segment| segment.superscript && segment.subscript)
        {
            return Err(format!(
                "text cannot be superscript and subscript together: {}",
                block.id
            ));
        }
        if block.block_type != "todo_list" && block.checked {
            return Err(format!(
                "only todo_list blocks can be checked: {}",
                block.id
            ));
        }
        if !is_supported_alignment(&block.alignment) {
            return Err(format!(
                "unsupported block alignment {}: {}",
                block.alignment, block.id
            ));
        }
        if block.indent > 6 {
            return Err(format!("block indent exceeds 6: {}", block.id));
        }
        if !is_indentable_block_type(&block.block_type) && block.indent != 0 {
            return Err(format!("only list blocks can be indented: {}", block.id));
        }
    }
    Ok(())
}

/// 返回手机可写的块类型；[block_type] 是投影类型而非桌面 flavour，标题仅允许 H1~H6。
fn is_supported_block_type(block_type: &str) -> bool {
    is_resource_block_type(block_type)
        || matches!(
            block_type,
            "paragraph"
            | "heading_1"
            | "heading_2"
            | "heading_3"
            | "heading_4"
            | "heading_5"
            | "heading_6"
            | "bulleted_list"
            | "numbered_list"
            | "todo_list"
            | "quote"
            | "code"
            | "callout"
            | "mermaid"
            | "mermaid-textarea"
            | "table"
            | "table-row"
            | "table-cell"
            | "date-card"
            | "divider"
            | "page-divider"
            | "formula"
            | "meeting"
            | "task"
            | "kr-list"
            // URL-backed blocks reuse the existing per-block Y.Text payload:
            // their `text` contains the resource URL rather than editable
            // paragraph content. This preserves convergence without a schema
            // migration or an additional bridge field.
            | "link"
            | "image"
            | "video"
        )
}

fn is_supported_alignment(alignment: &str) -> bool {
    matches!(
        alignment,
        "left" | "center" | "right" | "justify" | "distributed"
    )
}

fn is_indentable_block_type(block_type: &str) -> bool {
    matches!(block_type, "bulleted_list" | "numbered_list" | "todo_list")
}

fn create_compatible_doc() -> Doc {
    Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        skip_gc: true,
        ..Options::default()
    })
}

fn load_updates(connection: &Connection, document_id: &str) -> Result<Vec<Vec<u8>>, String> {
    let mut statement = connection
        .prepare(
            "SELECT payload FROM document_updates
             WHERE document_id = ?1
             ORDER BY sequence ASC",
        )
        .map_err(|error| format!("cannot prepare update query: {error}"))?;
    let rows = statement
        .query_map([document_id], |row| row.get::<_, Vec<u8>>(0))
        .map_err(|error| format!("cannot query persisted updates: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("cannot read persisted update: {error}"))
}

fn with_engine<T>(operation: impl FnOnce(&CollabEngine) -> Result<T, String>) -> Result<T, String> {
    let engine = ENGINE.lock();
    let engine = engine
        .as_ref()
        .ok_or_else(|| "document is not open".to_owned())?;
    operation(engine)
}

fn with_engine_mut<T>(
    operation: impl FnOnce(&mut CollabEngine) -> Result<T, String>,
) -> Result<T, String> {
    let mut engine = ENGINE.lock();
    let engine = engine
        .as_mut()
        .ok_or_else(|| "document is not open".to_owned())?;
    operation(engine)
}

fn open_result(engine: &CollabEngine, persisted_update_count: u32) -> OpenDocumentResult {
    OpenDocumentResult {
        blocks: engine.blocks(),
        persisted_update_count,
        shared_type_name: if engine.blockcraft_root_id.is_some() {
            blockcraft::ROOT_NAME
        } else {
            BLOCK_ORDER_NAME
        }
        .to_owned(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_document(
    document_id: String,
    database_path: String,
) -> Result<OpenDocumentResult, String> {
    let (engine, persisted_update_count) = CollabEngine::open(document_id, database_path)?;
    let result = open_result(&engine, persisted_update_count);
    *ENGINE.lock() = Some(engine);
    Ok(result)
}

/// 打开正式文档的独立缓存分区。document_id 是服务端根 ID，cache_document_id 只用于 SQLite 隔离。
/// 不创建业务根或补写 Demo 头部；恢复的缓存结构必须能通过正式模型校验。
#[flutter_rust_bridge::frb(sync)]
pub fn open_cses_document(
    document_id: String,
    cache_document_id: String,
    database_path: String,
) -> Result<OpenDocumentResult, String> {
    let (mut engine, count) = CollabEngine::open(cache_document_id, database_path)?;
    engine.blockcraft_root_id = Some(document_id.clone());
    blockcraft::validate(&engine.doc, &document_id)?;
    let result = open_result(&engine, count);
    *ENGINE.lock() = Some(engine);
    Ok(result)
}

/// Prepare a newly created formal document without installing the global engine.
/// `document_id` is the server root, `cache_document_id` is the host's isolated cache,
/// and `database_path` is the SQLite file. `operation_id`, `paragraph_id` and the
/// epoch-millisecond `created_time` remain stable across retries. Returns the root
/// snapshot JSON after the initial V1 update and local receipt commit atomically.
/// An occupied engine, existing content or mismatching receipt fails without mutation.
#[flutter_rust_bridge::frb(sync)]
pub fn prepare_cses_document(
    document_id: String,
    cache_document_id: String,
    database_path: String,
    operation_id: String,
    paragraph_id: String,
    created_time: f64,
) -> Result<String, String> {
    let guard = ENGINE.lock();
    if guard.is_some() {
        return Err("COLLAB_DOCUMENT_IN_USE: 请先关闭当前文档".into());
    }
    document_bootstrap::prepare(
        document_id,
        cache_document_id,
        database_path,
        operation_id,
        paragraph_id,
        created_time,
    )
}

/// 返回正式模型的只读原因，None 表示当前已知结构可编辑；不代表服务端业务授权。
/// 每次应用远端更新后重新查询，锁、修订和行内对象可能随协同状态变化。
#[flutter_rust_bridge::frb(sync)]
pub fn document_read_only_reason() -> Result<Option<String>, String> {
    with_engine(|engine| {
        Ok(engine
            .blockcraft_root_id
            .as_ref()
            .and_then(|id| blockcraft::project(&engine.doc, id).reason))
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn current_blocks() -> Result<Vec<CollabBlock>, String> {
    with_engine(|engine| Ok(engine.blocks()))
}

#[flutter_rust_bridge::frb(sync)]
pub fn create_sync_step1() -> Result<Vec<u8>, String> {
    with_engine(|engine| Ok(engine.sync_step1()))
}

/// 返回原始 Yjs 状态向量；调用方只在 JSON 传输边界进行 Base64 编码。
#[flutter_rust_bridge::frb(sync)]
pub fn encode_state_vector() -> Result<Vec<u8>, String> {
    with_engine(|engine| Ok(engine.doc.transact().state_vector().encode_v1()))
}

/// 根据服务端原始状态向量计算其缺失的完整 V1 update，不包装 y-websocket 帧。
///
/// `state_vector` 必须是已通过大小检查的解码字节；格式错误返回失败，不改变文档。
#[flutter_rust_bridge::frb(sync)]
pub fn encode_document_diff(state_vector: Vec<u8>) -> Result<Vec<u8>, String> {
    let vector = StateVector::decode_v1(&state_vector)
        .map_err(|error| format!("invalid state vector: {error}"))?;
    with_engine(|engine| Ok(engine.doc.transact().encode_state_as_update_v1(&vector)))
}

/// 应用 PaaS 原始 V1 update，先按当前引擎模型检查结构，再更新文档并写入 SQLite。
///
/// `bytes` 不包含 y-websocket 帧或 Base64 文本。返回快照供 Flutter 更新 UI，不生成回包，
/// 因而远端更新不会被自动回发；调用方在 collabSync 后另行计算差量。
#[flutter_rust_bridge::frb(sync)]
pub fn apply_document_update(bytes: Vec<u8>) -> Result<WireMessageResult, String> {
    with_engine_mut(|engine| engine.apply_cses_update(bytes))
}

/// 提高本机 Awareness 时钟并编码本 clientID 的在线或删除状态。
///
/// `user_id` 与 `user_name` 仅作展示，不是授权凭据；`present` 为 false 时发送标准 null。
/// 只选择自身 clientID 编码，不把已收到的远端状态再次上行。
#[flutter_rust_bridge::frb(sync)]
pub fn encode_local_awareness(
    user_id: String,
    user_name: String,
    present: bool,
) -> Result<Vec<u8>, String> {
    with_engine_mut(|engine| {
        engine
            .awareness
            .set_local_state(serde_json::json!({"user": {"id": user_id, "name": user_name}}))
            .map_err(|error| error.to_string())?;
        if !present {
            engine.awareness.clean_local_state();
        }
        engine
            .awareness
            .update_with_clients([engine.doc.client_id()])
            .map(|update| update.encode_v1())
            .map_err(|error| error.to_string())
    })
}

/// 应用原始 Awareness 字节并返回其他活动编辑器数量，不更改正文或写入 SQLite。
///
/// `bytes` 必须来自 collabAwareness；解码失败不更新状态。
#[flutter_rust_bridge::frb(sync)]
pub fn apply_awareness_update(bytes: Vec<u8>) -> Result<u32, String> {
    let update = AwarenessUpdate::decode_v1(&bytes).map_err(|error| error.to_string())?;
    with_engine_mut(|engine| {
        engine
            .awareness
            .apply_update(update)
            .map_err(|error| error.to_string())?;
        Ok(engine
            .awareness
            .iter()
            .filter(|(id, state)| *id != engine.doc.client_id() && state.data.is_some())
            .count() as u32)
    })
}

/// 断线时清除远端在线显示，保留 Awareness 删除时钟与本机状态，避免旧包复活已删除成员。
#[flutter_rust_bridge::frb(sync)]
pub fn clear_remote_awareness() -> Result<(), String> {
    with_engine_mut(|engine| {
        let remote = engine
            .awareness
            .iter()
            .filter_map(|(id, _)| (id != engine.doc.client_id()).then_some(id))
            .collect::<Vec<_>>();
        for id in remote {
            engine.awareness.remove_state(id);
        }
        Ok(())
    })
}

/// 释放本 Demo 当前唯一文档引擎；已同步写入的 SQLite 更新仍可在下次打开时恢复。
#[flutter_rust_bridge::frb(sync)]
pub fn close_document() {
    *ENGINE.lock() = None;
}

#[flutter_rust_bridge::frb(sync)]
pub fn apply_block_snapshot(blocks: Vec<CollabBlock>) -> Result<BlockChangeResult, String> {
    with_engine_mut(|engine| engine.apply_block_snapshot(blocks))
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_wire_message(bytes: Vec<u8>) -> Result<WireMessageResult, String> {
    with_engine_mut(|engine| engine.handle_wire_message(bytes))
}

#[flutter_rust_bridge::frb(sync)]
pub fn reset_local_document() -> Result<OpenDocumentResult, String> {
    let mut guard = ENGINE.lock();
    let current = guard
        .as_ref()
        .ok_or_else(|| "document is not open".to_owned())?;
    let document_id = current.document_id.clone();
    let database_path = current.database_path.clone();
    current
        .connection
        .execute(
            "DELETE FROM document_updates WHERE document_id = ?1",
            [&document_id],
        )
        .map_err(|error| format!("cannot clear persisted updates: {error}"))?;

    let (engine, persisted_update_count) = CollabEngine::open(document_id, database_path)?;
    let result = open_result(&engine, persisted_update_count);
    *guard = Some(engine);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn block(id: &str, block_type: &str, text: &str) -> CollabBlock {
        CollabBlock {
            paragraph_style: None,
            id: id.to_owned(),
            block_type: block_type.to_owned(),
            text: text.to_owned(),
            segments: Vec::new(),
            checked: false,
            alignment: "left".to_owned(),
            indent: 0,
            image: None,
            ordered: None,
            parent_id: None,
            callout_prefix: None,
            block_text_color: None,
            code: None,
            resource: None,
            replaces_id: None,
            block_background_color: None,
            block_border_color: None,
        }
    }

    /// 在测试引擎 `engine` 中安装或移除写入失败触发器，不影响其他数据库。
    fn set_persistence_failure(engine: &CollabEngine, enabled: bool) {
        engine.connection.execute_batch(if enabled {
            "CREATE TRIGGER fail_review_write BEFORE INSERT ON document_updates BEGIN SELECT RAISE(FAIL, 'forced cache write failure'); END;"
        } else {
            "DROP TRIGGER fail_review_write;"
        }).unwrap();
    }

    /// 本地和正式快照落盘失败不推进Doc；存储恢复后成功重试可完整重开。
    #[test]
    fn snapshot_persistence_failure_is_atomic_and_retry_reopens() {
        for formal in [false, true] {
            let directory = tempdir().unwrap();
            let path = directory
                .path()
                .join("atomic.sqlite")
                .to_string_lossy()
                .to_string();
            let mut engine = CollabEngine::open("atomic".into(), path.clone()).unwrap().0;
            if formal {
                engine.blockcraft_root_id = Some("fixture-doc".into());
                engine
                    .apply_cses_update(
                        include_bytes!("../../tests/fixtures/blockcraft-basic.update").to_vec(),
                    )
                    .unwrap();
            } else {
                engine
                    .apply_block_snapshot(vec![block("p", "paragraph", "A")])
                    .unwrap();
            }
            let before = engine.blocks();
            let vector = engine.doc.transact().state_vector();
            let client = engine.doc.client_id();
            let mut edited = before.clone();
            edited[0].text.push('B');
            if let Some(segment) = edited[0].segments.last_mut() {
                segment.text.push('B');
            }
            set_persistence_failure(&engine, true);
            assert!(engine
                .apply_block_snapshot(edited.clone())
                .unwrap_err()
                .contains("cannot persist"));
            assert_eq!(engine.blocks(), before);
            assert_eq!(engine.doc.transact().state_vector(), vector);
            set_persistence_failure(&engine, false);
            edited[0].text.push('C');
            if let Some(segment) = edited[0].segments.last_mut() {
                segment.text.push('C');
            }
            engine.apply_block_snapshot(edited).unwrap();
            let saved = engine.blocks();
            assert_eq!(engine.doc.client_id(), client);
            drop(engine);
            let mut reopened = CollabEngine::open("atomic".into(), path).unwrap().0;
            if formal {
                reopened.blockcraft_root_id = Some("fixture-doc".into());
            }
            assert_eq!(reopened.blocks(), saved);
        }
    }

    /// 远端落盘失败不推进向量；依赖增量先到达、重试和重开仍可收敛。
    #[test]
    fn remote_persistence_failure_keeps_vector_and_out_of_order_retry() {
        let directory = tempdir().unwrap();
        let path = directory
            .path()
            .join("target.sqlite")
            .to_string_lossy()
            .to_string();
        let mut source = CollabEngine::open("source".into(), ":memory:".into())
            .unwrap()
            .0;
        let mut target = CollabEngine::open("target".into(), path.clone()).unwrap().0;
        let a = source
            .apply_block_snapshot(vec![block("p", "paragraph", "A")])
            .unwrap();
        target.apply_cses_update(a.v1_update).unwrap();
        let vector = target.doc.transact().state_vector();
        let b = source
            .apply_block_snapshot(vec![block("p", "paragraph", "AB")])
            .unwrap();
        set_persistence_failure(&target, true);
        assert!(target.apply_cses_update(b.v1_update.clone()).is_err());
        assert_eq!(target.blocks()[0].text, "A");
        assert_eq!(target.doc.transact().state_vector(), vector);
        set_persistence_failure(&target, false);
        let c = source
            .apply_block_snapshot(vec![block("p", "paragraph", "ABC")])
            .unwrap();
        target.apply_cses_update(c.v1_update).unwrap();
        target.apply_cses_update(b.v1_update).unwrap();
        assert_eq!(target.blocks()[0].text, "ABC");
        drop(target);
        assert_eq!(
            CollabEngine::open("target".into(), path)
                .unwrap()
                .0
                .blocks()[0]
                .text,
            "ABC"
        );
    }

    /// 本地隔离写入保留待整合增量，并维持Awareness使用的clientID。
    #[test]
    fn local_staging_preserves_pending_remote_update_and_client_id() {
        let mut source = CollabEngine::open("source".into(), ":memory:".into())
            .unwrap()
            .0;
        let mut target = CollabEngine::open("target".into(), ":memory:".into())
            .unwrap()
            .0;
        let a = source
            .apply_block_snapshot(vec![block("p", "paragraph", "A")])
            .unwrap();
        target.apply_cses_update(a.v1_update).unwrap();
        let b = source
            .apply_block_snapshot(vec![block("p", "paragraph", "AB")])
            .unwrap();
        let c = source
            .apply_block_snapshot(vec![block("p", "paragraph", "ABC")])
            .unwrap();
        target.apply_cses_update(c.v1_update).unwrap();
        let client = target.doc.client_id();
        target
            .apply_block_snapshot(vec![
                block("p", "paragraph", "A"),
                block("q", "paragraph", "local"),
            ])
            .unwrap();
        target.apply_cses_update(b.v1_update).unwrap();
        assert_eq!(
            target
                .blocks()
                .iter()
                .map(|b| b.text.as_str())
                .collect::<Vec<_>>(),
            ["ABC", "local"]
        );
        assert_eq!(target.doc.client_id(), client);
    }

    /// 首次正式根同步落盘失败不切换引擎模型；重试后可正常识别和投影。
    #[test]
    fn initial_formal_sync_persistence_failure_preserves_model() {
        let mut target = CollabEngine::open("fixture-doc".into(), ":memory:".into())
            .unwrap()
            .0;
        let vector = target.doc.transact().state_vector();
        let payload = include_bytes!("../../tests/fixtures/blockcraft-basic.update").to_vec();
        set_persistence_failure(&target, true);
        assert!(target.apply_cses_update(payload.clone()).is_err());
        assert!(target.blockcraft_root_id.is_none());
        assert_eq!(target.doc.transact().state_vector(), vector);
        assert!(target.blocks().is_empty());
        set_persistence_failure(&target, false);
        target.apply_cses_update(payload).unwrap();
        assert_eq!(target.blockcraft_root_id.as_deref(), Some("fixture-doc"));
        assert_eq!(target.blocks().len(), 3);
    }

    /// 离线草稿的段落默认格式可重开；非法初始化在创建共享文字之前拒绝。
    #[test]
    fn legacy_paragraph_defaults_reopen_and_invalid_initialization_is_atomic() {
        let directory = tempdir().unwrap();
        let path = directory
            .path()
            .join("paragraph.sqlite")
            .to_string_lossy()
            .to_string();
        let mut engine = CollabEngine::open("legacy-paragraph".into(), path.clone())
            .unwrap()
            .0;
        let mut paragraph = block("empty", "paragraph", "");
        paragraph.paragraph_style = Some(CollabResource {
            properties: r#"{"textDefaults":{"a:bold":true},"nextParagraphStyle":"body"}"#.into(),
            property_edits: None,
        });
        engine.apply_block_snapshot(vec![paragraph]).unwrap();
        let saved = engine.blocks();
        let reopened = CollabEngine::open("legacy-paragraph".into(), path)
            .unwrap()
            .0;
        assert_eq!(reopened.blocks(), saved);
        let before = engine.doc.transact().state_vector();
        let mut invalid = block("invalid", "paragraph", "");
        invalid.paragraph_style = Some(CollabResource {
            properties: r#"{"textDefaults":{"mentionId":"bad"}}"#.into(),
            property_edits: None,
        });
        assert!(engine.apply_block_snapshot(vec![invalid]).is_err());
        assert_eq!(engine.doc.transact().state_vector(), before);
    }

    fn styled_segment(text: &str, bold: bool, strikethrough: bool) -> CollabTextSegment {
        CollabTextSegment {
            typography: None,
            href: None,
            inline_latex: None,
            inline_mention: None,
            mention_id: None,
            mention_type: None,
            mention_attributes: None,
            text: text.to_owned(),
            bold,
            italic: false,
            underline: false,
            strikethrough,
            code: false,
            text_color: None,
            background_color: None,
            superscript: false,
            subscript: false,
        }
    }

    fn test_engine(name: &str) -> CollabEngine {
        let directory = tempdir().expect("temp directory");
        let path = directory.keep().join(format!("{name}.sqlite3"));
        CollabEngine::open(name.to_owned(), path.to_string_lossy().to_string())
            .expect("open engine")
            .0
    }

    /// 正式 Yjs 13 生成的快照必须进入原有块模型，不能依赖手机 Demo 私有根名称。
    #[test]
    fn blockcraft_yjs_fixture_loads_formatted_paragraphs() {
        let mut engine = test_engine("fixture-doc");
        let result = engine
            .apply_cses_update(
                include_bytes!("../../tests/fixtures/blockcraft-basic.update").to_vec(),
            )
            .expect("valid BlockCraft snapshot");
        assert_eq!(result.blocks.len(), 3);
        assert_eq!(result.blocks[0].id, "p1");
        assert_eq!(result.blocks[0].text, "正文😀");
        assert!(result.blocks[0].segments[0].bold);
        assert_eq!(result.blocks[1].block_type, "heading_2");
        assert!(result.blocks[2].checked);
    }

    // CSES 载荷只有原始 V1 字节；用两份独立 SQLite 引擎验证双向补传和离线恢复。
    #[test]
    fn cses_raw_update_round_trip_and_offline_recovery() {
        let mut phone_a = test_engine("cses-a");
        let mut phone_b = test_engine("cses-b");
        let local = phone_a
            .apply_block_snapshot(vec![block("a", "paragraph", "原始 V1 😀")])
            .unwrap();
        assert!(!local.v1_update.is_empty());
        let remote = phone_b.apply_cses_update(local.v1_update.clone()).unwrap();
        assert!(remote.reply.is_empty());
        assert_eq!(phone_a.blocks(), phone_b.blocks());
        // 重放同一 update 不改变正文，体现 Yjs 幂等边界。
        phone_b.apply_cses_update(local.v1_update).unwrap();
        let mut edited = phone_b.blocks();
        edited.push(block("b", "paragraph", "离线补传"));
        phone_b.apply_block_snapshot(edited).unwrap();
        let vector = phone_a.doc.transact().state_vector().encode_v1();
        let diff = phone_b
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::decode_v1(&vector).unwrap());
        phone_a.apply_cses_update(diff).unwrap();
        assert_eq!(phone_a.blocks(), phone_b.blocks());
        let reopened =
            CollabEngine::open(phone_a.document_id.clone(), phone_a.database_path.clone())
                .unwrap()
                .0;
        assert_eq!(reopened.blocks(), phone_a.blocks());
    }

    // 不兼容根类型先在独立 Doc 中检查，拒绝后权威状态和 SQLite 都保持不变。
    #[test]
    fn cses_schema_rejection_does_not_mutate_doc_or_sqlite() {
        let mut engine = test_engine("schema-guard");
        engine
            .apply_block_snapshot(vec![block("local", "paragraph", "保留")])
            .unwrap();
        let before = engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let count = load_updates(&engine.connection, &engine.document_id)
            .unwrap()
            .len();
        let foreign = create_compatible_doc();
        foreign.get_or_insert_map("blocks").insert(
            &mut foreign.transact_mut(),
            "desktop",
            "BlockCraft",
        );
        let payload = foreign
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        assert!(engine
            .apply_cses_update(payload)
            .unwrap_err()
            .contains("UNSUPPORTED_DOCUMENT_SCHEMA"));
        assert_eq!(
            before,
            engine
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default())
        );
        assert_eq!(
            count,
            load_updates(&engine.connection, &engine.document_id)
                .unwrap()
                .len()
        );
        assert!(engine.apply_cses_update(vec![0, 0]).is_ok());
    }

    // 公共桥接仅有此测试访问全局引擎；验证本机心跳提升 clock，退出发 null，不回传他人。
    #[test]
    fn cses_awareness_bridge_owns_only_local_client_state() {
        *ENGINE.lock() = Some(test_engine("awareness"));
        let first = AwarenessUpdate::decode_v1(
            &encode_local_awareness("u".into(), "User".into(), true).unwrap(),
        )
        .unwrap();
        let local_id = *first.clients.keys().next().unwrap();
        let first_clock = first.clients[&local_id].clock;
        let mut remote = Awareness::new(create_compatible_doc());
        remote
            .set_local_state(serde_json::json!({"user": {"id": "other"}}))
            .unwrap();
        assert_eq!(
            apply_awareness_update(remote.update().unwrap().encode_v1()).unwrap(),
            1
        );
        let second = AwarenessUpdate::decode_v1(
            &encode_local_awareness("u".into(), "User".into(), true).unwrap(),
        )
        .unwrap();
        assert_eq!(second.clients.len(), 1);
        assert!(second.clients[&local_id].clock > first_clock);
        clear_remote_awareness().unwrap();
        let removed = AwarenessUpdate::decode_v1(
            &encode_local_awareness("u".into(), "User".into(), false).unwrap(),
        )
        .unwrap();
        assert_eq!(removed.clients[&local_id].json.as_ref(), "null");
        close_document();
    }

    #[test]
    fn block_update_converges_between_two_replicas() {
        let mut alice = test_engine("alice");
        let mut bob = test_engine("bob");
        let expected = vec![
            block("title", "heading_1", "Flutter + Rust"),
            block("item", "bulleted_list", "Yrs block sync"),
        ];

        let local = alice
            .apply_block_snapshot(expected.clone())
            .expect("local edit");
        let remote = bob
            .handle_wire_message(local.outbound_message)
            .expect("remote update");

        assert!(remote.changed);
        assert_eq!(alice.blocks(), expected);
        assert_eq!(bob.blocks(), expected);
    }

    #[test]
    fn concurrent_block_insertions_converge_after_update_exchange() {
        let mut phone_a = test_engine("phone-a");
        let mut phone_b = test_engine("phone-b");

        let update_a = phone_a
            .apply_block_snapshot(vec![block("a", "paragraph", "手机 A")])
            .expect("phone A offline edit")
            .outbound_message;
        let update_b = phone_b
            .apply_block_snapshot(vec![block("b", "numbered_list", "手机 B")])
            .expect("phone B offline edit")
            .outbound_message;

        phone_a
            .handle_wire_message(update_b)
            .expect("apply phone B update");
        phone_b
            .handle_wire_message(update_a)
            .expect("apply phone A update");

        assert_eq!(phone_a.blocks(), phone_b.blocks());
        assert_eq!(phone_a.blocks().len(), 2);
        assert!(phone_a.blocks().iter().any(|value| value.id == "a"));
        assert!(phone_a.blocks().iter().any(|value| value.id == "b"));
    }

    #[test]
    fn concurrent_text_insertions_in_one_block_converge() {
        let mut phone_a = test_engine("text-a");
        let mut phone_b = test_engine("text-b");
        let baseline = phone_a
            .apply_block_snapshot(vec![block("p", "paragraph", "base")])
            .expect("baseline")
            .outbound_message;
        phone_b
            .handle_wire_message(baseline)
            .expect("sync baseline");

        let update_a = phone_a
            .apply_block_snapshot(vec![block("p", "paragraph", "base A")])
            .expect("phone A edit")
            .outbound_message;
        let update_b = phone_b
            .apply_block_snapshot(vec![block("p", "paragraph", "base B")])
            .expect("phone B edit")
            .outbound_message;

        phone_a
            .handle_wire_message(update_b)
            .expect("apply phone B edit");
        phone_b
            .handle_wire_message(update_a)
            .expect("apply phone A edit");

        assert_eq!(phone_a.blocks(), phone_b.blocks());
        assert!(phone_a.blocks()[0].text.contains('A'));
        assert!(phone_a.blocks()[0].text.contains('B'));
    }

    #[test]
    fn rich_text_and_todo_state_converge_between_replicas() {
        let mut phone_a = test_engine("rich-a");
        let mut phone_b = test_engine("rich-b");
        let mut rich = block("rich", "paragraph", "bold and removed");
        rich.segments = vec![
            styled_segment("bold", true, false),
            styled_segment(" and ", false, false),
            styled_segment("removed", false, true),
        ];
        let mut todo = block("task", "todo_list", "ship mobile editor");
        todo.checked = true;

        let update = phone_a
            .apply_block_snapshot(vec![rich.clone(), todo.clone()])
            .expect("rich edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("apply rich update");

        assert_eq!(phone_a.blocks(), vec![rich.clone(), todo.clone()]);
        assert_eq!(phone_b.blocks(), vec![rich, todo]);
    }

    #[test]
    fn code_block_and_inline_colors_converge_between_replicas() {
        let mut phone_a = test_engine("color-code-a");
        let mut phone_b = test_engine("color-code-b");
        let mut code = block("code", "code", "let color = blue;");
        let mut colored = styled_segment("let color = blue;", false, false);
        colored.text_color = Some("0xff2196f3".to_owned());
        colored.background_color = Some("0x4dffc107".to_owned());
        code.segments = vec![colored];

        let update = phone_a
            .apply_block_snapshot(vec![code.clone()])
            .expect("code and color edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("apply code and color update");

        assert_eq!(phone_a.blocks(), vec![code.clone()]);
        assert_eq!(phone_b.blocks(), vec![code]);
    }

    /// 旧草稿的超范围标题按 H6 投影，读取不会覆盖其原始类型或文字。
    #[test]
    fn legacy_heading_levels_project_as_six_without_rewriting_metadata() {
        let mut engine = test_engine("legacy-headings");
        engine
            .apply_block_snapshot(vec![block("heading", "heading_6", "title")])
            .unwrap();
        for level in [7, 8, 9] {
            let kind = format!("heading_{level}");
            engine
                .block_meta
                .insert(&mut engine.doc.transact_mut(), "heading", kind.as_str());
            let vector = engine.doc.transact().state_vector();
            let blocks = engine.blocks();
            assert_eq!(blocks[0].block_type, "heading_6");
            assert_eq!(blocks[0].text, "title");
            let txn = engine.doc.transact();
            assert_eq!(
                out_string(engine.block_meta.get(&txn, "heading")),
                Some(kind)
            );
            assert_eq!(txn.state_vector(), vector);
        }
    }

    /// H6、列表布局与上下标经真实增量交换后保持一致。
    #[test]
    fn layout_heading_six_and_scripts_converge_between_replicas() {
        let mut phone_a = test_engine("layout-script-a");
        let mut phone_b = test_engine("layout-script-b");
        let mut heading = block("heading", "heading_6", "x2");
        heading.alignment = "center".to_owned();
        let mut exponent = styled_segment("2", false, false);
        exponent.superscript = true;
        heading.segments = vec![styled_segment("x", false, false), exponent];
        let mut list = block("list", "numbered_list", "nested item");
        list.alignment = "right".to_owned();
        list.indent = 2;

        let expected = vec![heading, list];
        let update = phone_a
            .apply_block_snapshot(expected.clone())
            .expect("layout and script edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("apply layout and script update");

        assert_eq!(phone_a.blocks(), expected);
        assert_eq!(phone_b.blocks(), expected);
    }

    #[test]
    fn url_backed_blocks_converge_between_replicas() {
        let mut phone_a = test_engine("embed-a");
        let mut phone_b = test_engine("embed-b");
        let expected = vec![
            block("link", "link", "https://example.com/article"),
            block("image", "image", "https://example.com/photo.jpg"),
            block("video", "video", "https://example.com/movie.mp4"),
        ];

        // A URL is stored in the same collaborative text primitive as normal
        // block content. Exercising a full wire update proves that the new
        // types are accepted, ordered and reconstructed by another replica.
        let update = phone_a
            .apply_block_snapshot(expected.clone())
            .expect("URL-backed block edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("apply URL-backed block update");

        assert_eq!(phone_a.blocks(), expected);
        assert_eq!(phone_b.blocks(), expected);
    }

    #[test]
    fn old_draft_headers_are_removed_once_without_changing_body() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory
            .path()
            .join("header.sqlite3")
            .to_string_lossy()
            .to_string();
        let (mut engine, _) = CollabEngine::open("draft".into(), path.clone()).unwrap();
        let mut body = block("body", "paragraph", "正文🙂");
        body.segments = vec![styled_segment("正文🙂", true, false)];
        engine.apply_block_snapshot(vec![body.clone()]).unwrap();
        // 模拟旧版本持久化数据；新版本写入口不再接受这两种类型。
        let before = engine.doc.transact().state_vector();
        {
            let mut txn = engine.doc.transact_mut();
            engine
                .block_order
                .insert_range(&mut txn, 0, ["cover", "title"]);
            engine
                .block_meta
                .insert(&mut txn, "cover", "document_cover");
            engine
                .block_meta
                .insert(&mut txn, "title", "document_title");
        }
        let update = engine.doc.transact().encode_state_as_update_v1(&before);
        engine.persist_update(&update).unwrap();
        drop(engine);
        let (mut restored, count) = CollabEngine::open("draft".into(), path.clone()).unwrap();
        assert_eq!(restored.blocks(), vec![body.clone()]);
        for kind in ["document_cover", "document_title"] {
            assert!(restored
                .apply_block_snapshot(vec![block("invalid", kind, "旧头部")])
                .is_err());
        }
        drop(restored);
        let (reopened, next_count) = CollabEngine::open("draft".into(), path).unwrap();
        assert_eq!(reopened.blocks(), vec![body]);
        assert_eq!(next_count, count);
    }

    #[test]
    fn concurrent_rich_text_formatting_converges() {
        let mut phone_a = test_engine("format-a");
        let mut phone_b = test_engine("format-b");
        let baseline = phone_a
            .apply_block_snapshot(vec![block("rich", "paragraph", "AB")])
            .expect("baseline")
            .outbound_message;
        phone_b
            .handle_wire_message(baseline)
            .expect("sync baseline");

        let mut format_a = block("rich", "paragraph", "AB");
        format_a.segments = vec![
            styled_segment("A", true, false),
            styled_segment("B", false, false),
        ];
        let mut format_b = block("rich", "paragraph", "AB");
        format_b.segments = vec![
            styled_segment("A", false, false),
            styled_segment("B", false, true),
        ];
        let update_a = phone_a
            .apply_block_snapshot(vec![format_a])
            .expect("format A")
            .outbound_message;
        let update_b = phone_b
            .apply_block_snapshot(vec![format_b])
            .expect("format B")
            .outbound_message;

        phone_a
            .handle_wire_message(update_b)
            .expect("apply B format");
        phone_b
            .handle_wire_message(update_a)
            .expect("apply A format");

        assert_eq!(phone_a.blocks(), phone_b.blocks());
    }

    #[test]
    fn rich_text_and_todo_state_restore_from_sqlite() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("rich-updates.sqlite3");
        let path = path.to_string_lossy().to_string();
        let mut rich = block("rich", "quote", "keep formatting");
        rich.segments = vec![
            styled_segment("keep ", false, false),
            styled_segment("formatting", true, false),
        ];
        let mut todo = block("todo", "todo_list", "persist checked");
        todo.checked = true;
        let expected = vec![rich, todo];
        {
            let mut engine = CollabEngine::open("rich-doc".to_owned(), path.clone())
                .expect("open")
                .0;
            engine
                .apply_block_snapshot(expected.clone())
                .expect("save rich document");
        }

        let (restored, _) =
            CollabEngine::open("rich-doc".to_owned(), path).expect("restore rich document");
        assert_eq!(restored.blocks(), expected);
    }

    #[test]
    fn reorder_type_change_and_delete_converge() {
        let mut phone_a = test_engine("structure-a");
        let mut phone_b = test_engine("structure-b");
        let baseline = vec![
            block("a", "paragraph", "A"),
            block("b", "paragraph", "B"),
            block("c", "paragraph", "C"),
        ];
        let baseline_update = phone_a
            .apply_block_snapshot(baseline)
            .expect("baseline")
            .outbound_message;
        phone_b
            .handle_wire_message(baseline_update)
            .expect("sync baseline");

        let expected = vec![
            block("c", "heading_3", "C"),
            block("a", "bulleted_list", "A"),
        ];
        let update = phone_a
            .apply_block_snapshot(expected.clone())
            .expect("structural edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("sync structural edit");

        assert_eq!(phone_a.blocks(), expected);
        assert_eq!(phone_b.blocks(), expected);
    }

    #[test]
    fn unchanged_snapshot_does_not_emit_an_update() {
        let mut engine = test_engine("no-op");
        let blocks = vec![block("p", "paragraph", "unchanged")];
        engine
            .apply_block_snapshot(blocks.clone())
            .expect("initial edit");

        let result = engine
            .apply_block_snapshot(blocks.clone())
            .expect("no-op edit");

        assert!(result.outbound_message.is_empty());
        assert_eq!(result.blocks, blocks);
    }

    #[test]
    fn sync_step_round_trip_recovers_offline_blocks() {
        let mut offline = test_engine("offline");
        let expected = vec![block("p", "heading_2", "offline first")];
        offline
            .apply_block_snapshot(expected.clone())
            .expect("offline edit");
        let mut online = test_engine("online");

        let step1 = online.sync_step1();
        let step2 = offline
            .handle_wire_message(step1)
            .expect("handle step 1")
            .reply;
        let result = online.handle_wire_message(step2).expect("handle step 2");

        assert!(result.changed);
        assert_eq!(online.blocks(), expected);
    }

    #[test]
    fn sqlite_update_log_restores_block_document() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("updates.sqlite3");
        let path = path.to_string_lossy().to_string();
        let expected = vec![
            block("one", "paragraph", "persisted"),
            block("two", "bulleted_list", "second"),
        ];
        {
            let mut engine = CollabEngine::open("doc".to_owned(), path.clone())
                .expect("open")
                .0;
            engine.apply_block_snapshot(expected.clone()).expect("edit");
        }

        let (restored, count) = CollabEngine::open("doc".to_owned(), path).expect("reopen");
        assert_eq!(count, 1);
        assert_eq!(restored.blocks(), expected);
    }

    #[test]
    fn block_text_indices_use_utf16_like_yjs_and_dart() {
        let mut engine = test_engine("emoji");
        engine
            .apply_block_snapshot(vec![block("p", "paragraph", "A😀B")])
            .expect("insert");
        engine
            .apply_block_snapshot(vec![block("p", "paragraph", "A🚀B")])
            .expect("replace emoji");

        assert_eq!(engine.blocks()[0].text, "A🚀B");
    }

    #[test]
    fn legacy_single_text_is_migrated_to_paragraph_blocks() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("updates.sqlite3");
        let path = path.to_string_lossy().to_string();
        let connection = Connection::open(&path).expect("database");
        connection
            .execute_batch(
                "
                CREATE TABLE document_updates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    document_id TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                ",
            )
            .expect("schema");
        let legacy_doc = create_compatible_doc();
        let legacy_text = legacy_doc.get_or_insert_text(LEGACY_TEXT_NAME);
        let before = legacy_doc.transact().state_vector();
        legacy_text.insert(&mut legacy_doc.transact_mut(), 0, "first\nsecond");
        let update = legacy_doc.transact().encode_state_as_update_v1(&before);
        connection
            .execute(
                "INSERT INTO document_updates(document_id, payload) VALUES (?1, ?2)",
                params!["doc", update],
            )
            .expect("insert legacy update");
        drop(connection);

        let (engine, count) = CollabEngine::open("doc".to_owned(), path).expect("migrate");
        assert_eq!(count, 2);
        assert_eq!(
            engine.blocks(),
            vec![block(LEGACY_BLOCK_ID, "paragraph", "first\nsecond")]
        );
    }

    #[test]
    fn two_legacy_migrations_merge_without_duplicating_text() {
        let directory = tempdir().expect("temp directory");
        let legacy_doc = create_compatible_doc();
        let legacy_text = legacy_doc.get_or_insert_text(LEGACY_TEXT_NAME);
        let before = legacy_doc.transact().state_vector();
        legacy_text.insert(&mut legacy_doc.transact_mut(), 0, "shared legacy");
        let legacy_update = legacy_doc.transact().encode_state_as_update_v1(&before);

        let mut paths = Vec::new();
        for name in ["phone-a.sqlite3", "phone-b.sqlite3"] {
            let path = directory.path().join(name);
            let connection = Connection::open(&path).expect("database");
            connection
                .execute_batch(
                    "
                    CREATE TABLE document_updates (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        document_id TEXT NOT NULL,
                        payload BLOB NOT NULL
                    );
                    ",
                )
                .expect("schema");
            connection
                .execute(
                    "INSERT INTO document_updates(document_id, payload) VALUES (?1, ?2)",
                    params!["doc", legacy_update.clone()],
                )
                .expect("insert legacy update");
            paths.push(path.to_string_lossy().to_string());
        }

        let mut phone_a = CollabEngine::open("doc".to_owned(), paths[0].clone())
            .expect("open A")
            .0;
        let mut phone_b = CollabEngine::open("doc".to_owned(), paths[1].clone())
            .expect("open B")
            .0;

        let reply_a = phone_a
            .handle_wire_message(phone_b.sync_step1())
            .expect("A answers B")
            .reply;
        phone_b.handle_wire_message(reply_a).expect("B applies A");
        let reply_b = phone_b
            .handle_wire_message(phone_a.sync_step1())
            .expect("B answers A")
            .reply;
        phone_a.handle_wire_message(reply_b).expect("A applies B");

        let expected = vec![block(LEGACY_BLOCK_ID, "paragraph", "shared legacy")];
        assert_eq!(phone_a.blocks(), expected);
        assert_eq!(phone_b.blocks(), expected);
    }

    #[test]
    fn text_delta_never_splits_surrogate_pairs() {
        assert_eq!(
            compute_text_delta("A😀B", "A🚀B"),
            TextDelta {
                index: 1,
                delete_length: 2,
                insert_text: "🚀".to_owned(),
            }
        );
    }
}

/// Read effective locks for the entire reachable graph without changing shared data.
#[flutter_rust_bridge::frb(sync)]
pub fn current_block_locks() -> Result<Vec<block_locks::CollabBlockLock>, String> {
    with_engine(|engine| {
        Ok(engine
            .blockcraft_root_id
            .as_deref()
            .map_or_else(Vec::new, |root| block_locks::scan(&engine.doc, root)))
    })
}

/// Persist one desktop-compatible user lock. Identity and extra authorization are
/// supplied by the trusted host; expected metadata prevents stale menu actions.
#[flutter_rust_bridge::frb(sync)]
pub fn set_block_lock(
    block_id: String,
    locked: bool,
    user_id: String,
    grant: bool,
    expected_owner: Option<String>,
    expected_template: bool,
) -> Result<BlockChangeResult, String> {
    with_engine_mut(|engine| {
        engine.set_block_lock(
            block_id,
            locked,
            user_id,
            grant,
            expected_owner,
            expected_template,
        )
    })
}
