use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{
    types::Attrs, Any, Array, ArrayRef, Doc, GetString, Map, MapRef, OffsetKind, Options, Out,
    ReadTxn, Text, Transact, Update,
};

const BLOCK_ORDER_NAME: &str = "cses_mobile_block_order";
const BLOCK_META_NAME: &str = "cses_mobile_block_meta";
const BLOCK_CHECKED_NAME: &str = "cses_mobile_block_checked";
const BLOCK_ALIGN_NAME: &str = "cses_mobile_block_align";
const BLOCK_INDENT_NAME: &str = "cses_mobile_block_indent";
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollabBlock {
    pub id: String,
    pub block_type: String,
    pub text: String,
    pub segments: Vec<CollabTextSegment>,
    pub checked: bool,
    pub alignment: String,
    pub indent: u32,
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
    block_order: ArrayRef,
    block_meta: MapRef,
    block_checked: MapRef,
    block_align: MapRef,
    block_indent: MapRef,
    connection: Connection,
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
            doc,
            block_order,
            block_meta,
            block_checked,
            block_align,
            block_indent,
            connection,
        };
        let mut persisted_update_count = updates.len() as u32;
        if engine.migrate_legacy_text()? {
            persisted_update_count += 1;
        }

        Ok((engine, persisted_update_count))
    }

    fn blocks(&self) -> Vec<CollabBlock> {
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
                    id,
                    block_type,
                    text: text_ref.get_string(&transaction),
                    segments: text_segments(&text_ref, &transaction),
                    checked,
                    alignment,
                    indent,
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
        validate_blocks(&blocks)?;
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
            outbound_message: Message::Sync(SyncMessage::Update(update)).encode_v1(),
        })
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
                bold: attribute_enabled(attributes, "bold"),
                italic: attribute_enabled(attributes, "italic"),
                underline: attribute_enabled(attributes, "underline"),
                strikethrough: attribute_enabled(attributes, "strikethrough"),
                code: attribute_enabled(attributes, "code"),
                text_color: attribute_string(attributes, "textColor"),
                // The collaborative schema uses a stable camelCase name while
                // Flutter maps it to AppFlowy's package-specific `bg_color`.
                background_color: attribute_string(attributes, "backgroundColor"),
                superscript: attribute_enabled(attributes, "cses_superscript"),
                subscript: attribute_enabled(attributes, "cses_subscript"),
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
    ]);
    text_ref.format(transaction, 0, length, clear_attributes);

    let mut offset = 0;
    for segment in &block.segments {
        let segment_length = segment.text.encode_utf16().count() as u32;
        if segment_length > 0 && segment.is_styled() {
            text_ref.format(transaction, offset, segment_length, segment.attributes());
        }
        offset += segment_length;
    }
}

fn validate_blocks(blocks: &[CollabBlock]) -> Result<(), String> {
    let mut ids = HashSet::new();
    for block in blocks {
        if block.id.trim().is_empty() {
            return Err("block id must not be empty".to_owned());
        }
        if !ids.insert(block.id.as_str()) {
            return Err(format!("duplicate block id: {}", block.id));
        }
        if !is_supported_block_type(&block.block_type) {
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
    matches!(
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
    matches!(alignment, "left" | "center" | "right")
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
        shared_type_name: BLOCK_ORDER_NAME.to_owned(),
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

#[flutter_rust_bridge::frb(sync)]
pub fn current_blocks() -> Result<Vec<CollabBlock>, String> {
    with_engine(|engine| Ok(engine.blocks()))
}

#[flutter_rust_bridge::frb(sync)]
pub fn create_sync_step1() -> Result<Vec<u8>, String> {
    with_engine(|engine| Ok(engine.sync_step1()))
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
