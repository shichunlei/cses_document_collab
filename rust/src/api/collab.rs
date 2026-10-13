use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::HashSet;
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollabTextSegment {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub code: bool,
    pub text_color: Option<String>,
    /// Inline background/highlight color encoded as an ARGB string.
    ///
    /// This stays distinct from `text_color` so peers can independently merge
    /// foreground and background formatting on the same Yrs text range.
    pub background_color: Option<String>,
    pub superscript: bool,
    pub subscript: bool,
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
    /// 高亮容器的父 ID；根级为 None，正文始终保留自己的 Y.Text。
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

        let mut engine = Self {
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
        };
        let mut persisted_update_count = updates.len() as u32;
        if engine.migrate_legacy_text()? {
            persisted_update_count += 1;
        }

        Ok((engine, persisted_update_count))
    }

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

    fn apply_block_snapshot(
        &mut self,
        blocks: Vec<CollabBlock>,
    ) -> Result<BlockChangeResult, String> {
        validate_blocks(&blocks, self.blockcraft_root_id.is_some())?;
        if let Some(root_id) = &self.blockcraft_root_id {
            let before = self.doc.transact().state_vector();
            blockcraft::apply(&self.doc, root_id, &blocks)?;
            let update = self.doc.transact().encode_state_as_update_v1(&before);
            self.persist_update(&update)?;
            return Ok(BlockChangeResult {
                blocks: self.blocks(),
                v1_update: update.clone(),
                outbound_message: Message::Sync(SyncMessage::Update(update)).encode_v1(),
            });
        }
        let current_blocks = self.blocks();
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

        let text_refs = blocks
            .iter()
            .map(|block| self.doc.get_or_insert_text(block_text_name(&block.id)))
            .collect::<Vec<_>>();
        let (current_texts, current_segments) = {
            let transaction = self.doc.transact();
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
        let before = self.doc.transact().state_vector();
        {
            let mut transaction = self.doc.transact_mut();
            reconcile_order(
                &self.block_order,
                &mut transaction,
                &current_order,
                &desired_order,
            );

            let desired_ids = desired_order.iter().cloned().collect::<HashSet<_>>();
            for id in current_order {
                if !desired_ids.contains(&id) {
                    self.block_meta.remove(&mut transaction, &id);
                    self.block_checked.remove(&mut transaction, &id);
                    self.block_align.remove(&mut transaction, &id);
                    self.block_indent.remove(&mut transaction, &id);
                    self.block_colors
                        .remove(&mut transaction, &format!("{id}:background"));
                    self.block_colors
                        .remove(&mut transaction, &format!("{id}:border"));
                    for suffix in ["parent", "prefix", "text", "resource"] {
                        self.block_colors
                            .remove(&mut transaction, &format!("{id}:{suffix}"));
                    }
                }
            }

            for (((block, text_ref), current_text), current_segments) in blocks
                .iter()
                .zip(text_refs.iter())
                .zip(current_texts.iter())
                .zip(current_segments.iter())
            {
                self.block_meta.try_update(
                    &mut transaction,
                    block.id.clone(),
                    block.block_type.clone(),
                );
                self.block_checked
                    .try_update(&mut transaction, block.id.clone(), block.checked);
                self.block_align.try_update(
                    &mut transaction,
                    block.id.clone(),
                    block.alignment.clone(),
                );
                self.block_indent.try_update(
                    &mut transaction,
                    block.id.clone(),
                    block.indent as i64,
                );
                for (suffix, color) in [
                    ("background", &block.block_background_color),
                    ("border", &block.block_border_color),
                    ("parent", &block.parent_id),
                    ("prefix", &block.callout_prefix),
                    ("text", &block.block_text_color),
                ] {
                    let key = format!("{}:{suffix}", block.id);
                    if let Some(color) = color {
                        self.block_colors
                            .try_update(&mut transaction, key, color.clone());
                    } else {
                        self.block_colors.remove(&mut transaction, &key);
                    }
                }
                let key = format!("{}:resource", block.id);
                if let Some(resource) = &block.resource {
                    self.block_colors.try_update(
                        &mut transaction,
                        key,
                        resource.properties.clone(),
                    );
                } else {
                    self.block_colors.remove(&mut transaction, &key);
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

        let update = self.doc.transact().encode_state_as_update_v1(&before);
        self.persist_update(&update)?;
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
            self.blockcraft_root_id = Some(root_id);
            return self.apply_remote_update(payload, "collabUpdate");
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
        self.apply_remote_update(payload, "collabUpdate")
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
                self.apply_remote_update(update, "sync-step-2")
            }
            Message::Sync(SyncMessage::Update(update)) => {
                self.apply_remote_update(update, "sync-update")
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

    fn apply_remote_update(
        &mut self,
        payload: Vec<u8>,
        message_kind: &str,
    ) -> Result<WireMessageResult, String> {
        let before = self.blocks();
        if !payload.is_empty() {
            let update = Update::decode_v1(&payload)
                .map_err(|error| format!("invalid Yjs V1 update: {error}"))?;
            self.doc
                .transact_mut()
                .apply_update(update)
                .map_err(|error| format!("cannot apply remote Yjs update: {error}"))?;
            self.persist_update(&payload)?;
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

    fn persist_update(&self, payload: &[u8]) -> Result<(), String> {
        if payload.is_empty() {
            return Ok(());
        }
        self.connection
            .execute(
                "INSERT INTO document_updates(document_id, payload) VALUES (?1, ?2)",
                params![self.document_id, payload],
            )
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
            let text = match chunk.insert {
                Out::Any(Any::String(value)) => value.to_string(),
                _ => return None,
            };
            let attributes = chunk.attributes.as_deref();
            Some(CollabTextSegment {
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
        self.bold
            || self.italic
            || self.underline
            || self.strikethrough
            || self.code
            || self.text_color.is_some()
            || self.background_color.is_some()
            || self.superscript
            || self.subscript
    }

    fn attributes(&self) -> Attrs {
        let mut attributes = Attrs::new();
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

/// 受支持格式只清除自己的键；正式模式不删除链接、字体、提及或其他未知属性。
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
    let clear_attributes = Attrs::from([
        // Every supported rich-text attribute is explicitly cleared before
        // replaying canonical segments, preventing removed remote highlights
        // from surviving on a peer that previously formatted the same range.
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

fn validate_blocks(blocks: &[CollabBlock], allow_placeholders: bool) -> Result<(), String> {
    let mut ids = HashSet::new();
    let mut ancestors = Vec::<&str>::new();
    for block in blocks {
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
                .ok_or("INVALID_BLOCK_PARENT: 父块必须是前序高亮容器")?;
            ancestors.truncate(position + 1);
        } else {
            ancestors.clear();
        }
        if block.block_type == "callout" {
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
        if !is_supported_block_type(&block.block_type)
            && !(allow_placeholders && block.block_type == blockcraft::UNSUPPORTED_BLOCK_TYPE)
        {
            return Err(format!("unsupported block type: {}", block.block_type));
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
            | "heading_7"
            | "heading_8"
            | "heading_9"
            | "bulleted_list"
            | "numbered_list"
            | "todo_list"
            | "quote"
            | "code"
            | "callout"
            // URL-backed blocks reuse the existing per-block Y.Text payload:
            // their `text` contains the resource URL rather than editable
            // paragraph content. This preserves convergence without a schema
            // migration or an additional bridge field.
            | "link"
            | "image"
            | "video"
            // Fixed document header blocks use the same Y.Text payload: the
            // cover stores an optional URL and the title stores editable text.
            // Deterministic IDs/order are enforced by the Dart controller.
            | "document_cover"
            | "document_title"
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

    fn styled_segment(text: &str, bold: bool, strikethrough: bool) -> CollabTextSegment {
        CollabTextSegment {
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

    #[test]
    fn layout_heading_nine_and_scripts_converge_between_replicas() {
        let mut phone_a = test_engine("layout-script-a");
        let mut phone_b = test_engine("layout-script-b");
        let mut heading = block("heading", "heading_9", "x2");
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
    fn document_cover_and_title_converge_between_replicas() {
        let mut phone_a = test_engine("document-header-a");
        let mut phone_b = test_engine("document-header-b");
        let expected = vec![
            block(
                "cses-document-cover",
                "document_cover",
                "https://example.com/cover.jpg",
            ),
            block("cses-document-title", "document_title", "协同文档标题"),
            block("body", "paragraph", "正文"),
        ];

        let update = phone_a
            .apply_block_snapshot(expected.clone())
            .expect("document header edit")
            .outbound_message;
        phone_b
            .handle_wire_message(update)
            .expect("apply document header update");

        assert_eq!(phone_a.blocks(), expected);
        assert_eq!(phone_b.blocks(), expected);
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
