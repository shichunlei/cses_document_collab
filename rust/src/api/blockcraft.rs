//! 正式 BlockCraft 的 Yrs 适配。`blocks` 中的嵌套共享类型始终是权威数据，
//! Flutter 快照只是投影；写入只修改明确支持的字段，保留 props/meta/行内未知属性。
//! 暂不能完整投影的容器、内嵌对象、修订和锁定内容令整篇文档只读，防止扁平 UI 丢数据。

use super::*;
use std::collections::HashMap;
use yrs::types::AsPrelim;
use yrs::{ArrayPrelim, MapPrelim, TextPrelim, TextRef};

pub(super) const ROOT_NAME: &str = "blocks";
const AUXILIARY_ROOTS: &[&str] = &["bc:revisions", "bc:revision-decisions", "bc:revision-meta"];

/// Flutter 投影和当前写入边界；reason 为空时才允许从完整快照产生本地操作。
pub(super) struct Projection {
    pub blocks: Vec<CollabBlock>,
    pub reason: Option<String>,
}

/// 取已有嵌套 Map，不创建任何共享内容；类型不符时返回 None。
fn map<T: ReadTxn>(parent: &MapRef, txn: &T, key: &str) -> Option<MapRef> {
    match parent.get(txn, key) {
        Some(Out::YMap(value)) => Some(value),
        _ => None,
    }
}

/// 读取结构块的子 ID；错误的字段类型交给 validate 拒绝，投影本身不写文档。
fn children<T: ReadTxn>(block: &MapRef, txn: &T) -> Vec<String> {
    match block.get(txn, "children") {
        Some(Out::YArray(array)) => array
            .iter(txn)
            .filter_map(|v| out_string(Some(v)))
            .collect(),
        _ => Vec::new(),
    }
}

/// 对齐桌面 normalizeOrderedCounterInteger；缺失/非法/非正值归零，正小数向下取整。
fn counter_integer(value: Option<Out>) -> u32 {
    let number = match value {
        Some(Out::Any(Any::Number(v))) => v,
        Some(Out::Any(Any::BigInt(v))) => v as f64,
        Some(Out::Any(Any::String(v))) => v.trim().parse().unwrap_or(0.0),
        Some(Out::Any(Any::Bool(true))) => 1.0,
        _ => 0.0,
    };
    if number.is_finite() && number > 0.0 {
        number.floor() as u32
    } else {
        0
    }
}

/// 使用当前桌面 OrderedBlockPlugin 的兄弟扫描规则计算编号，不依赖已存 order。
/// 同层普通段落不打断编号；返回浅层及 ordered heading 边界剪除对应计数器，start 重开。
/// 未建模 ms 原样保留；null/未知显式样式阻止继承，只有桌面已注册样式能够向新项传播。
fn ordered_projection<T: ReadTxn>(
    blocks: &MapRef,
    txn: &T,
    ids: &[String],
) -> HashMap<String, (CollabOrdered, Option<String>)> {
    let mut counters: HashMap<(u32, u32), (u32, Option<String>)> = HashMap::new();
    let mut result = HashMap::new();
    for id in ids {
        let Some(block) = map(blocks, txn, id) else {
            continue;
        };
        let Some(props) = map(&block, txn, "props") else {
            continue;
        };
        let ordered = out_string(block.get(txn, "flavour")).as_deref() == Some("ordered");
        let depth = counter_integer(props.get(txn, "depth"));
        let heading = counter_integer(props.get(txn, "heading"));
        counters.retain(|&(counter_depth, counter_heading), _| {
            counter_depth <= depth
                && !(ordered && heading > 0 && (counter_heading == 0 || counter_heading > heading))
        });
        if !ordered {
            continue;
        }
        let start = counter_integer(props.get(txn, "start"));
        let previous = if start > 0 {
            None
        } else {
            counters.get(&(depth, heading))
        };
        let order = if start > 0 {
            start - 1
        } else {
            previous.map_or(0, |v| v.0)
        };
        let own_style = out_string(props.get(txn, "ms"));
        let marker_style = if props.contains_key(txn, "ms") {
            own_style.clone().filter(|v| is_marker_style(v))
        } else {
            previous.and_then(|v| v.1.clone())
        };
        let stored = props.get(txn, "order");
        let needs_repair = match stored {
            Some(Out::Any(Any::Number(v))) => !v.is_finite() || v.floor() != order as f64,
            Some(Out::Any(Any::BigInt(v))) => v != order as i64,
            _ => true,
        };
        result.insert(
            id.clone(),
            (
                CollabOrdered {
                    order,
                    start: (start > 0).then_some(start),
                    heading,
                    // 桌面只在插入时写入继承 ms；既有缺失 ms 的项目按自身 depth 回退展示。
                    marker_style: own_style,
                    needs_repair,
                    numbering: ordered_numbering(&props, txn),
                    numbering_edit: None,
                },
                marker_style.clone(),
            ),
        );
        counters.insert(
            (depth, heading),
            (
                order.saturating_add(1),
                marker_style.filter(|v| is_marker_style(v)),
            ),
        );
    }
    result
}

/// 提取编号设置原值，保持 missing/null/0/自定义起点的区别；排序后的 JSON 供 UI 历史保存。
/// 只读取原子属性，不将未知 props、样式或共享类型复制到可写输入。
fn ordered_numbering<T: ReadTxn>(props: &MapRef, txn: &T) -> String {
    let mut values = std::collections::BTreeMap::new();
    for key in ["start", "continuePrevious"] {
        if let Some(Out::Any(value)) = props.get(txn, key) {
            values.insert(key, value);
        }
    }
    serde_json::to_string(&values).expect("Yrs 原子属性可序列化为 JSON")
}

/// 编号命令在写事务前完整校验，仅允许两个原子设置键；空对象表示恢复两个属性的缺失状态。
/// 拒绝超大载荷、未知键和非对象输入，防止编号菜单成为任意 props 写入通道。
fn parse_numbering_edit(value: &str) -> Result<std::sync::Arc<HashMap<String, Any>>, String> {
    let invalid =
        || "INVALID_ORDERED_PROPERTIES: 编号设置必须仅含 start/continuePrevious".to_owned();
    if value.len() > 8192 {
        return Err(invalid());
    }
    let Any::Map(values) = Any::from_json(value).map_err(|_| invalid())? else {
        return Err(invalid());
    };
    if values
        .keys()
        .any(|key| key != "start" && key != "continuePrevious")
    {
        return Err(invalid());
    }
    Ok(values)
}

/// 只写结构派生的 order；未知 props/meta 和用户配置的 start/ms/continuePrevious 原样保留。
/// 调用者与正文/根顺序修改共用事务，保证持久化及广播始终包含完整编号结果。
fn update_ordered_counters(
    blocks: &MapRef,
    txn: &mut yrs::TransactionMut<'_>,
    ids: &[String],
    inserted: &HashSet<String>,
) {
    for (id, (value, inherited_style)) in ordered_projection(blocks, txn, ids) {
        let block = map(blocks, txn, &id).unwrap();
        let props = map(&block, txn, "props").unwrap();
        if value.needs_repair {
            props.try_update(txn, "order", value.order as i64);
        }
        if inserted.contains(&id) && !props.contains_key(txn, "ms") {
            if let Some(style) = inherited_style {
                props.try_update(txn, "ms", style);
            }
        }
    }
}

/// 与当前桌面注册的 ms 预设对齐；未知样式保留在原块，但不传播给新增项。
fn is_marker_style(value: &str) -> bool {
    matches!(
        value,
        "n1" | "n2" | "n3" | "n4" | "n5" | "a1" | "a2" | "r1" | "r2" | "c1" | "c2" | "o1"
    )
}

/// 验证正式根和所有块的基础结构；未知 flavour 保留，但 malformed 共享类型不能进入缓存。
/// 空快照允许暂时缺少根，等后续依赖到达；非空快照必须包含目标文档的 root。
pub(super) fn validate(doc: &Doc, root_id: &str) -> Result<(), String> {
    let txn = doc.transact();
    let Some(blocks) = txn.get_map(ROOT_NAME) else {
        return Ok(());
    };
    for (name, _) in txn.root_refs() {
        let mobile = matches!(
            name,
            BLOCK_ORDER_NAME
                | BLOCK_META_NAME
                | BLOCK_CHECKED_NAME
                | BLOCK_ALIGN_NAME
                | BLOCK_INDENT_NAME
                | BLOCK_COLORS_NAME
                | LEGACY_TEXT_NAME
        ) || name.starts_with(BLOCK_TEXT_PREFIX);
        // V1 根类型在首次接收时可能是 UndefinedRef，按 Map/序列两个分量检查实际数据。
        let occupied = txn.get_map(name).is_some_and(|v| v.len(&txn) > 0)
            || txn.get_array(name).is_some_and(|v| v.len(&txn) > 0);
        if mobile && occupied {
            return Err("UNSUPPORTED_DOCUMENT_SCHEMA: 不能混用 Demo 与正式文档缓存".into());
        }
    }
    if blocks.len(&txn) == 0 {
        return Ok(());
    }
    let fail = || "UNSUPPORTED_DOCUMENT_SCHEMA: BlockCraft 块结构或文档根不合法".to_owned();
    let root = map(&blocks, &txn, root_id).ok_or_else(fail)?;
    if out_string(root.get(&txn, "flavour")).as_deref() != Some("root")
        || out_string(root.get(&txn, "nodeType")).as_deref() != Some("root")
    {
        return Err(fail());
    }
    for (id, value) in blocks.iter(&txn) {
        let Out::YMap(block) = value else {
            return Err(fail());
        };
        if out_string(block.get(&txn, "id")).as_deref() != Some(id)
            || out_string(block.get(&txn, "flavour")).is_none()
            || map(&block, &txn, "props").is_none()
            || map(&block, &txn, "meta").is_none()
        {
            return Err(fail());
        }
        match (
            out_string(block.get(&txn, "nodeType")).as_deref(),
            block.get(&txn, "children"),
        ) {
            (Some("editable"), Some(Out::YText(_))) => {}
            (Some("root" | "block" | "void"), Some(Out::YArray(array))) => {
                if array.iter(&txn).any(|v| out_string(Some(v)).is_none()) {
                    return Err(fail());
                }
            }
            _ => return Err(fail()),
        }
    }
    Ok(())
}

/// 将正式 flavour/props 转为手机可编辑类型；不支持的类型返回 None，不降级写回 paragraph。
fn mobile_type<T: ReadTxn>(block: &MapRef, props: &MapRef, txn: &T) -> Option<String> {
    let flavour = out_string(block.get(txn, "flavour"))?;
    Some(match flavour.as_str() {
        "paragraph" => match out_u32(props.get(txn, "heading")) {
            Some(level @ 1..=9) => format!("heading_{level}"),
            _ => "paragraph".to_owned(),
        },
        "bullet" => "bulleted_list".to_owned(),
        "ordered" => "numbered_list".to_owned(),
        "todo" => "todo_list".to_owned(),
        "blockquote" => "quote".to_owned(),
        "code" | "image" | "video" => flavour,
        _ => return None,
    })
}

/// 有限数字原样投影；缺失、null 和错误类型不触发默认值写回。
fn number<T: ReadTxn>(props: &MapRef, txn: &T, key: &str) -> Option<f64> {
    match props.get(txn, key) {
        Some(Out::Any(Any::Number(v))) if v.is_finite() => Some(v),
        Some(Out::Any(Any::BigInt(v))) => Some(v as f64),
        _ => None,
    }
}

/// 读取图片自己的布局及 caption 子块，不把题注加入根顺序。
/// 缺失/重复/锁定/内嵌内容仍使整篇只读；不支持的子块交给外层继续预览。
fn image_projection<T: ReadTxn>(
    block: &MapRef,
    props: &MapRef,
    blocks: &MapRef,
    txn: &T,
    seen: &mut HashSet<String>,
    reason: &mut Option<String>,
) -> CollabImage {
    let mut captions = Vec::new();
    for id in children(block, txn) {
        let Some(caption) = map(blocks, txn, &id) else {
            *reason = Some("图片题注尚未到达，等待完整同步".into());
            continue;
        };
        if out_string(caption.get(txn, "flavour")).as_deref() != Some("caption")
            || !seen.insert(id.clone())
        {
            *reason = Some("图片包含不支持或重复的子块，当前仅可预览".into());
            continue;
        }
        if map(&caption, txn, "meta")
            .and_then(|m| out_string(m.get(txn, "lock")))
            .is_some_and(|s| !s.trim().is_empty())
        {
            *reason = Some("图片题注已锁定，当前仅可预览".into());
        }
        if let Some(Out::YText(text)) = caption.get(txn, "children") {
            if text
                .diff(txn, |_| ())
                .iter()
                .any(|c| !matches!(&c.insert, Out::Any(Any::String(_))))
            {
                *reason = Some("图片题注包含行内对象，当前仅可预览".into());
            }
            captions.push(CollabImageCaption {
                id,
                text: text.get_string(txn),
            });
        } else {
            *reason = Some("图片题注结构不支持，当前仅可预览".into());
        }
    }
    CollabImage {
        width_ratio: number(props, txn, "wr").filter(|v| *v > 0.0),
        aspect_ratio: number(props, txn, "ar").filter(|v| *v > 0.0),
        width: number(props, txn, "width").filter(|v| *v > 0.0),
        height: number(props, txn, "height").filter(|v| *v > 0.0),
        rotation: number(props, txn, "rotation"),
        captions,
    }
}

/// 深度优先展示内容；保留树中真实 blockId，容器输出占位后继续预览后代。
/// UI 目前是扁平结构，任何容器/未知内容均禁止整篇写入，原嵌套关系不会被改平。
pub(super) fn project(doc: &Doc, root_id: &str) -> Projection {
    let txn = doc.transact();
    let mut result = Projection {
        blocks: Vec::new(),
        reason: None,
    };
    for (name, _) in txn.root_refs() {
        if name != ROOT_NAME
            && !AUXILIARY_ROOTS.contains(&name)
            && !matches!(
                name,
                BLOCK_ORDER_NAME
                    | BLOCK_META_NAME
                    | BLOCK_CHECKED_NAME
                    | BLOCK_ALIGN_NAME
                    | BLOCK_INDENT_NAME
                    | BLOCK_COLORS_NAME
                    | LEGACY_TEXT_NAME
            )
        {
            result.reason = Some("文档含暂不支持的顶层数据，仅可预览".into());
        }
    }
    // 修订批注未绑定移动编辑器，保留全部原始数据且不绕过修订语义直接改正文。
    if txn.get_map("bc:revisions").is_some_and(|v| v.len(&txn) > 0) {
        result.reason = Some("文档含修订记录，当前仅可预览".into());
    }
    let Some(root) = txn
        .get_map(ROOT_NAME)
        .and_then(|blocks| map(&blocks, &txn, root_id))
    else {
        result.reason = Some("等待正式文档根初始化".into());
        return result;
    };
    let blocks = txn
        .get_map(ROOT_NAME)
        .expect("root lookup established blocks");
    let ordered = ordered_projection(&blocks, &txn, &children(&root, &txn));
    let mut stack: Vec<(String, usize)> = children(&root, &txn)
        .into_iter()
        .rev()
        .map(|id| (id, 0))
        .collect();
    let mut seen = HashSet::new();
    while let Some((id, depth)) = stack.pop() {
        if depth > 256 || seen.len() >= 100_000 || !seen.insert(id.clone()) {
            result.reason = Some("文档结构重复、循环或超限，当前仅可预览".into());
            continue;
        }
        let Some(block) = map(&blocks, &txn, &id) else {
            result.reason = Some("文档包含尚未到达的子块，等待完整同步".into());
            continue;
        };
        let Some(props) = map(&block, &txn, "props") else {
            continue;
        };
        let meta = map(&block, &txn, "meta");
        if meta
            .as_ref()
            .and_then(|m| out_string(m.get(&txn, "lock")))
            .is_some_and(|s| !s.trim().is_empty())
        {
            result.reason = Some("文档含锁定块，当前仅可预览".into());
        }
        let flavour = out_string(block.get(&txn, "flavour")).unwrap_or_default();
        let node_type = out_string(block.get(&txn, "nodeType")).unwrap_or_default();
        let kind = mobile_type(&block, &props, &txn);
        let mut text = String::new();
        let mut segments = Vec::new();
        let mut image = None;
        let is_media = matches!(kind.as_deref(), Some("image" | "video"));
        match block.get(&txn, "children") {
            Some(Out::YText(value)) if node_type == "editable" && !is_media => {
                text = value.get_string(&txn);
                segments = text_segments_for_schema(&value, &txn, true);
                if value
                    .diff(&txn, |_| ())
                    .iter()
                    .any(|c| !matches!(&c.insert, Out::Any(Any::String(_))))
                {
                    result.reason = Some("文档含行内对象，当前仅可预览".into());
                }
            }
            Some(Out::YArray(array))
                if (kind.as_deref() == Some("image")
                    && matches!(node_type.as_str(), "block" | "void"))
                    || (kind.as_deref() == Some("video")
                        && node_type == "void"
                        && array.len(&txn) == 0) =>
            {
                text = out_string(props.get(&txn, "src")).unwrap_or_default();
                if !matches!(
                    props.get(&txn, "src"),
                    None | Some(Out::Any(Any::Null | Any::String(_)))
                ) {
                    result.reason = Some("媒体资源结构暂不支持，当前仅可预览".into());
                }
                if kind.as_deref() == Some("image") {
                    image = Some(image_projection(
                        &block,
                        &props,
                        &blocks,
                        &txn,
                        &mut seen,
                        &mut result.reason,
                    ));
                    for child in children(&block, &txn).into_iter().rev() {
                        if !seen.contains(&child) {
                            stack.push((child, depth + 1));
                        }
                    }
                }
            }
            _ => {
                result.reason = Some(format!("块 {flavour} 的结构暂不支持，当前仅可预览"));
                for child in children(&block, &txn).into_iter().rev() {
                    stack.push((child, depth + 1));
                }
            }
        }
        if kind.is_none() {
            result.reason = Some(format!("包含暂不支持的 {flavour} 块，当前仅可预览"));
            text = format!("［暂不支持的块：{flavour}］{text}");
            segments.clear();
        }
        let kind = kind.unwrap_or_else(|| "paragraph".into());
        result.blocks.push(CollabBlock {
            ordered: ordered.get(&id).map(|v| v.0.clone()),
            replaces_id: None,
            block_background_color: out_string(props.get(&txn, "backColor")),
            block_border_color: out_string(props.get(&txn, "borderColor")),
            id,
            text,
            segments,
            checked: kind == "todo_list"
                && (out_u32(props.get(&txn, "checked")) == Some(1)
                    || out_bool(props.get(&txn, "checked")) == Some(true)),
            alignment: out_string(props.get(
                &txn,
                if kind == "image" {
                    "align"
                } else {
                    "textAlign"
                },
            ))
            .filter(|v| is_supported_alignment(v))
            .unwrap_or_else(|| "left".into()),
            indent: if is_indentable_block_type(&kind) {
                out_u32(props.get(&txn, "depth")).unwrap_or(0).min(6)
            } else {
                0
            },
            block_type: kind,
            image,
        });
    }
    result
}

/// 支持的手机类型到正式 flavour；Demo 的独立标题、封面和链接块没有隐式正式对应。
fn formal_type(kind: &str) -> Option<(&str, bool)> {
    Some(match kind {
        "paragraph" => ("paragraph", false),
        s if s.starts_with("heading_") => ("paragraph", false),
        "bulleted_list" => ("bullet", false),
        "numbered_list" => ("ordered", false),
        "todo_list" => ("todo", false),
        "quote" => ("blockquote", false),
        "code" => ("code", false),
        "image" => ("image", true),
        "video" => ("video", true),
        _ => return None,
    })
}

/// 在全部前置校验通过后才更新既有共享类型。外部负责取得向量、持久化增量和广播。
/// 未改动的块/属性/格式不重放；删除仅处理本次根子列表中的块，隐藏与孤立数据原样保留。
/// 新身份类型替换只清理源类型专有的编号/勾选键，其他扩展属性继续克隆；恢复有序历史时
/// 仅初始化经过白名单校验的原始编号设置和投影样式，派生 order 始终重新计算。
pub(super) fn apply(doc: &Doc, root_id: &str, desired: &[CollabBlock]) -> Result<(), String> {
    validate(doc, root_id)?;
    let current = project(doc, root_id);
    if let Some(reason) = current.reason {
        return Err(format!("READ_ONLY_DOCUMENT: {reason}"));
    }
    for block in desired {
        if block.id == root_id || formal_type(&block.block_type).is_none() {
            return Err("UNSUPPORTED_BLOCK_TYPE: 正式文档不支持该手机块类型".into());
        }
    }
    let blocks = doc.get_or_insert_map(ROOT_NAME);
    let txn = doc.transact();
    let root = map(&blocks, &txn, root_id).ok_or("正式文档根缺失")?;
    let order = match root.get(&txn, "children") {
        Some(Out::YArray(v)) => v,
        _ => return Err("根 children 必须是 Y.Array".into()),
    };
    let ids = children(&root, &txn);
    let previous: HashMap<_, _> = current.blocks.iter().map(|b| (b.id.as_str(), b)).collect();
    let mut desired_ids: HashSet<String> = desired.iter().map(|b| b.id.clone()).collect();
    let mut replaced_ids = HashSet::new();
    let mut replacements = HashMap::new();
    let mut numbering_edits = HashMap::new();
    // 新 UI 身份不能复用未展示的块或孤立块，避免覆盖隐藏内容。
    for block in desired {
        if !previous.contains_key(block.id.as_str()) && blocks.contains_key(&txn, &block.id) {
            return Err("BLOCK_ID_CONFLICT: 新块 ID 已被原文档占用".into());
        }
        let old = if let Some(source) = &block.replaces_id {
            if source == &block.id
                || desired_ids.contains(source)
                || !replaced_ids.insert(source.clone())
            {
                return Err(
                    "INVALID_BLOCK_CONVERSION: 替换来源必须唯一且不能继续保留在根列表".into(),
                );
            }
            let old = previous
                .get(source.as_str())
                .copied()
                .ok_or("INVALID_BLOCK_CONVERSION: 替换来源已经不存在")?;
            let source_block = map(&blocks, &txn, source).unwrap();
            replacements.insert(block.id.clone(), source_block.as_prelim(&txn));
            Some(old)
        } else {
            previous.get(block.id.as_str()).copied()
        };
        if let Some(edit) = block
            .ordered
            .as_ref()
            .and_then(|v| v.numbering_edit.as_ref())
        {
            if block.block_type != "numbered_list"
                || old.is_none_or(|b| b.block_type != "numbered_list")
                || block.replaces_id.is_some()
            {
                return Err("INVALID_ORDERED_PROPERTIES: 编号操作只适用于既有有序列表".into());
            }
            numbering_edits.insert(block.id.clone(), parse_numbering_edit(edit)?);
        }
        // 只有新身份的有序替换允许从历史投影初始化设置；同类型普通快照仍然只读。
        // 在取得写事务前验证 JSON，避免任一选中项非法时发生部分根替换。
        if block.replaces_id.is_some() && block.block_type == "numbered_list" {
            if let Some(ordered) = &block.ordered {
                numbering_edits.insert(block.id.clone(), parse_numbering_edit(&ordered.numbering)?);
            }
        }
        if old.is_some_and(|old| {
            old.id == block.id && formal_type(&old.block_type) != formal_type(&block.block_type)
        }) {
            return Err("INVALID_BLOCK_CONVERSION: flavour 转换需要新块身份和 replacesId".into());
        }
        if old.is_some_and(|b| {
            b.block_type == "image" && b.image.as_ref().is_some_and(|i| !i.captions.is_empty())
        }) && block.block_type != "image"
        {
            return Err("UNSUPPORTED_BLOCK_TYPE: 带题注图片不能直接转换为正文块".into());
        }
        if let Some(image) = &block.image {
            if block.block_type != "image"
                || [
                    image.width_ratio,
                    image.aspect_ratio,
                    image.width,
                    image.height,
                ]
                .into_iter()
                .flatten()
                .any(|v| !v.is_finite() || v <= 0.0)
                || image.rotation.is_some_and(|v| !v.is_finite())
            {
                return Err("INVALID_IMAGE_PROPERTIES: 图片尺寸必须为有限正数".into());
            }
            for caption in &image.captions {
                let original = old
                    .and_then(|b| b.image.as_ref())
                    .is_some_and(|i| i.captions.iter().any(|c| c.id == caption.id));
                if caption.id.is_empty()
                    || caption.id == root_id
                    || !desired_ids.insert(caption.id.clone())
                    || (!original && blocks.contains_key(&txn, &caption.id))
                {
                    return Err("BLOCK_ID_CONFLICT: 图片题注 ID 已被占用".into());
                }
            }
        }
    }
    drop(txn);
    let mut txn = doc.transact_mut();
    let next_ids: Vec<_> = desired.iter().map(|b| b.id.clone()).collect();
    reconcile_order(&order, &mut txn, &ids, &next_ids);
    let keep: HashSet<_> = next_ids.iter().collect();
    for id in &ids {
        if !keep.contains(id) {
            if let Some(image) = previous.get(id.as_str()).and_then(|b| b.image.as_ref()) {
                for caption in &image.captions {
                    blocks.remove(&mut txn, &caption.id);
                }
            }
            blocks.remove(&mut txn, id);
        }
    }
    for next in desired {
        let old = previous
            .get(next.replaces_id.as_deref().unwrap_or(&next.id))
            .copied();
        if old == Some(next) {
            continue;
        }
        let (flavour, media) = formal_type(&next.block_type).unwrap();
        let block = if let Some(prelim) = replacements.remove(&next.id) {
            let block = blocks.insert(&mut txn, next.id.clone(), prelim);
            block.try_update(&mut txn, "id", next.id.clone());
            block
        } else {
            map(&blocks, &txn, &next.id)
                .unwrap_or_else(|| blocks.insert(&mut txn, next.id.clone(), MapPrelim::default()))
        };
        let props = map(&block, &txn, "props")
            .unwrap_or_else(|| block.insert(&mut txn, "props", MapPrelim::default()));
        if next.replaces_id.is_some() {
            if old.is_some_and(|b| b.block_type == "numbered_list") || flavour == "ordered" {
                for key in ["order", "start", "continuePrevious", "ms", "heading"] {
                    props.remove(&mut txn, key);
                }
            }
            if old.is_some_and(|b| b.block_type == "todo_list") && flavour != "todo" {
                for key in ["checked", "created"] {
                    props.remove(&mut txn, key);
                }
            }
            if flavour == "ordered" {
                if let Some(ordered) = &next.ordered {
                    if ordered.heading > 0 {
                        props.try_update(&mut txn, "heading", ordered.heading as i64);
                    }
                    if let Some(style) = &ordered.marker_style {
                        props.try_update(&mut txn, "ms", style.clone());
                    } else {
                        // 历史投影的默认样式必须阻止插入阶段继承上文预设，否则撤销会改变标记。
                        // 新转入项没有 ordered 投影，继续使用既有插入时的样式继承规则。
                        props.try_update(&mut txn, "ms", Any::Null);
                    }
                }
            }
        }
        // 只消费显式设置动作。常规文本、格式、排序及远端投影不会用旧快照覆盖编号设置。
        // 与派生 order 更新共用此事务，外部得到的 V1 增量可直接持久化和广播。
        if let Some(values) = numbering_edits.get(&next.id) {
            for key in ["start", "continuePrevious"] {
                if let Some(value) = values.get(key) {
                    props.try_update(&mut txn, key, value.clone());
                } else {
                    props.remove(&mut txn, key);
                }
            }
        }
        if old.is_none() {
            block.insert(&mut txn, "id", next.id.clone());
            let meta = block.insert(&mut txn, "meta", MapPrelim::default());
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            meta.insert(&mut txn, "createdTime", now);
            props.insert(&mut txn, "depth", next.indent as i64);
            if flavour == "todo" {
                props.insert(&mut txn, "created", now);
            }
            if flavour == "code" {
                props.insert(&mut txn, "lang", "PlainText");
            }
        }
        if old.is_none_or(|b| b.block_type != next.block_type) {
            block.try_update(&mut txn, "flavour", flavour);
            block.try_update(
                &mut txn,
                "nodeType",
                if flavour == "image" {
                    "block"
                } else if media {
                    "void"
                } else {
                    "editable"
                },
            );
            if let Some(level) = next
                .block_type
                .strip_prefix("heading_")
                .and_then(|s| s.parse::<i64>().ok())
            {
                props.try_update(&mut txn, "heading", level);
            } else if flavour != "ordered" {
                props.remove(&mut txn, "heading");
            }
        }
        if old.is_none_or(|b| b.alignment != next.alignment) {
            let align_key = if flavour == "image" {
                "align"
            } else {
                "textAlign"
            };
            if next.alignment == "left" {
                props.remove(&mut txn, align_key);
            } else {
                props.try_update(&mut txn, align_key, next.alignment.clone());
            }
        }
        for (key, previous, color) in [
            (
                "backColor",
                old.and_then(|b| b.block_background_color.as_ref()),
                next.block_background_color.as_ref(),
            ),
            (
                "borderColor",
                old.and_then(|b| b.block_border_color.as_ref()),
                next.block_border_color.as_ref(),
            ),
        ] {
            // 普通正文编辑不重写颜色，保留桌面 null、缺失及未知值。
            if previous != color {
                if let Some(color) = color {
                    props.try_update(&mut txn, key, css_color(Any::String(color.clone().into())));
                } else {
                    props.remove(&mut txn, key);
                }
            }
        }
        if old.is_none_or(|b| b.indent != next.indent) {
            props.try_update(&mut txn, "depth", next.indent as i64);
        }
        if flavour == "todo"
            && old.is_none_or(|b| b.checked != next.checked || b.block_type != next.block_type)
        {
            props.try_update(&mut txn, "checked", i64::from(next.checked));
        }
        if media {
            if !matches!(block.get(&txn, "children"), Some(Out::YArray(_))) {
                block.insert(
                    &mut txn,
                    "children",
                    ArrayPrelim::from(Vec::<String>::new()),
                );
            }
            if old.is_none_or(|b| b.text != next.text) {
                props.try_update(&mut txn, "src", next.text.clone());
            }
            if flavour == "image" {
                apply_image(
                    &blocks,
                    &block,
                    &props,
                    &mut txn,
                    old.and_then(|b| b.image.as_ref()),
                    next.image.as_ref(),
                );
            }
        } else {
            let text: TextRef = match block.get(&txn, "children") {
                Some(Out::YText(v)) => v,
                _ => block.insert(&mut txn, "children", TextPrelim::new("")),
            };
            let before = text.get_string(&txn);
            let delta = compute_text_delta(&before, &next.text);
            if delta.delete_length > 0 {
                text.remove_range(&mut txn, delta.index, delta.delete_length);
            }
            if !delta.insert_text.is_empty() {
                text.insert(&mut txn, delta.index, &delta.insert_text);
            }
            apply_formats(&text, &mut txn, next);
        }
    }
    let inserted = desired
        .iter()
        .filter(|b| !previous.contains_key(b.id.as_str()))
        .map(|b| b.id.clone())
        .collect();
    update_ordered_counters(&blocks, &mut txn, &next_ids, &inserted);
    Ok(())
}

/// 更新图片支持的布局键与题注。只写变化字段，保留旧尺寸/未知属性和题注原 Y.Text 格式。
/// None 输入表示调用者尚未提供图片投影：已有图片保留，新图片采用 wr=100 的正式默认值。
fn apply_image(
    blocks: &MapRef,
    block: &MapRef,
    props: &MapRef,
    txn: &mut yrs::TransactionMut<'_>,
    old: Option<&CollabImage>,
    next: Option<&CollabImage>,
) {
    let default = CollabImage {
        width_ratio: Some(100.0),
        ..Default::default()
    };
    let next = next.or(old).unwrap_or(&default);
    for (key, before, after) in [
        ("wr", old.and_then(|v| v.width_ratio), next.width_ratio),
        ("ar", old.and_then(|v| v.aspect_ratio), next.aspect_ratio),
        ("width", old.and_then(|v| v.width), next.width),
        ("height", old.and_then(|v| v.height), next.height),
        ("rotation", old.and_then(|v| v.rotation), next.rotation),
    ] {
        if before != after {
            if let Some(value) = after {
                props.try_update(txn, key, value);
            } else {
                props.remove(txn, key);
            }
        }
    }
    let order = match block.get(txn, "children") {
        Some(Out::YArray(v)) => v,
        _ => unreachable!(),
    };
    let previous = old.map(|i| i.captions.as_slice()).unwrap_or_default();
    let before: Vec<_> = previous.iter().map(|c| c.id.clone()).collect();
    let after: Vec<_> = next.captions.iter().map(|c| c.id.clone()).collect();
    reconcile_order(&order, txn, &before, &after);
    for id in &before {
        if !after.contains(id) {
            blocks.remove(txn, id);
        }
    }
    for caption in &next.captions {
        if previous.iter().any(|c| c == caption) {
            continue;
        }
        let stored = map(blocks, txn, &caption.id).unwrap_or_else(|| {
            let stored = blocks.insert(txn, caption.id.clone(), MapPrelim::default());
            stored.insert(txn, "id", caption.id.clone());
            stored.insert(txn, "flavour", "caption");
            stored.insert(txn, "nodeType", "editable");
            stored.insert(txn, "meta", MapPrelim::default());
            let p = stored.insert(txn, "props", MapPrelim::default());
            p.insert(txn, "textAlign", "center");
            stored.insert(txn, "children", TextPrelim::new(""));
            stored
        });
        if let Some(Out::YText(text)) = stored.get(txn, "children") {
            let delta = compute_text_delta(&text.get_string(txn), &caption.text);
            if delta.delete_length > 0 {
                text.remove_range(txn, delta.index, delta.delete_length);
            }
            if !delta.insert_text.is_empty() {
                text.insert(txn, delta.index, &delta.insert_text);
            }
        }
    }
}

/// 手机颜色为 0xAARRGGBB；正式 s:color/background 需要 CSS。已有 CSS 值直接保留。
fn css_color(value: Any) -> Any {
    if let Any::String(s) = &value {
        if let Some(hex) = s.strip_prefix("0x").filter(|s| s.len() == 8) {
            if let Ok(argb) = u32::from_str_radix(hex, 16) {
                let alpha = argb >> 24;
                let css = if alpha == 255 {
                    format!("#{:06x}", argb & 0xffffff)
                } else {
                    format!(
                        "rgba({}, {}, {}, {})",
                        (argb >> 16) & 255,
                        (argb >> 8) & 255,
                        argb & 255,
                        alpha as f64 / 255.0
                    )
                };
                return Any::String(css.into());
            }
        }
    }
    value
}

/// 在文本差量应用后比较每个格式区间，只写实际改变的受支持属性。
/// 不对整块无条件 clear/replay，从而保留链接等未知格式，并减少对并发格式更新的覆盖。
fn apply_formats(text: &TextRef, txn: &mut yrs::TransactionMut<'_>, desired: &CollabBlock) {
    let actual: Vec<_> = text
        .diff(txn, |_| ())
        .into_iter()
        .filter_map(|c| match c.insert {
            Out::Any(Any::String(s)) => Some((
                s.encode_utf16().count() as u32,
                c.attributes.map(|a| *a).unwrap_or_default(),
            )),
            _ => None,
        })
        .collect();
    let target: Vec<(u32, Attrs)> = if desired.segments.is_empty() {
        vec![(desired.text.encode_utf16().count() as u32, Attrs::new())]
    } else {
        desired
            .segments
            .iter()
            .map(|s| {
                (
                    s.text.encode_utf16().count() as u32,
                    s.attributes()
                        .into_iter()
                        .map(|(key, value)| {
                            let value = if matches!(key.as_ref(), "textColor" | "backgroundColor") {
                                css_color(value)
                            } else {
                                value
                            };
                            (schema_attribute(&key, true).into(), value)
                        })
                        .collect(),
                )
            })
            .filter(|(len, _)| *len > 0)
            .collect()
    };
    let keys = [
        "a:bold",
        "a:italic",
        "a:underline",
        "a:strike",
        "a:code",
        "s:color",
        "s:background",
        "a:sup",
        "a:sub",
    ];
    let (mut i, mut j, mut used_a, mut used_b, mut offset) = (0, 0, 0, 0, 0);
    while i < actual.len() && j < target.len() {
        let length = (actual[i].0 - used_a).min(target[j].0 - used_b);
        let mut patch = Attrs::new();
        for key in keys {
            let before = actual[i]
                .1
                .get(key)
                .filter(|v| !matches!(v, Any::Null | Any::Bool(false)));
            let after = target[j]
                .1
                .get(key)
                .filter(|v| !matches!(v, Any::Null | Any::Bool(false)));
            if before != after {
                patch.insert(key.into(), after.cloned().unwrap_or(Any::Null));
            }
        }
        if length > 0 && !patch.is_empty() {
            text.format(txn, offset, length, patch);
        }
        offset += length;
        used_a += length;
        used_b += length;
        if used_a == actual[i].0 {
            i += 1;
            used_a = 0;
        }
        if used_b == target[j].0 {
            j += 1;
            used_b = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use yrs::types::ToJson;

    /// 每个用例拥有独立 Doc/SQLite，使用真正由 Yjs 13 编码的正式模型 fixture。
    fn engine(bytes: &[u8]) -> CollabEngine {
        let directory = tempdir().unwrap().keep();
        let mut engine = CollabEngine::open(
            "fixture-doc".into(),
            directory.join("updates.sqlite").to_string_lossy().into(),
        )
        .unwrap()
        .0;
        engine.blockcraft_root_id = Some("fixture-doc".into());
        engine.apply_cses_update(bytes.to_vec()).unwrap();
        engine
    }

    #[test]
    fn block_colors_roundtrip_without_touching_inline_formats_or_unknown_props() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let mut desktop = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let mut desired = phone.blocks();
        desired[0].block_background_color = Some("#ffecdf".into());
        desired[0].block_border_color = Some("rgba(255, 0, 0, 0.5)".into());
        let update = phone.apply_block_snapshot(desired).unwrap();
        desktop.apply_cses_update(update.v1_update).unwrap();
        assert_eq!(phone.blocks(), desktop.blocks());
        let before = phone.blocks()[0].clone();
        let props_before = {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let block = map(&blocks, &txn, &before.id).unwrap();
            map(&block, &txn, "props").unwrap().to_json(&txn)
        };
        let mut edited = phone.blocks();
        edited[0].text.push_str("正文");
        edited[0].segments.clear();
        phone.apply_block_snapshot(edited).unwrap();
        {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let block = map(&blocks, &txn, &before.id).unwrap();
            assert_eq!(
                map(&block, &txn, "props").unwrap().to_json(&txn),
                props_before
            );
        }
        let mut cleared = phone.blocks();
        cleared[0].block_background_color = None;
        phone.apply_block_snapshot(cleared).unwrap();
        let actual = phone.blocks();
        assert_eq!(actual[0].block_background_color, None);
        assert_eq!(actual[0].block_border_color, before.block_border_color);
        let mut restored = actual;
        restored[0].block_background_color = before.block_background_color;
        phone.apply_block_snapshot(restored).unwrap();
        let path = phone.database_path.clone();
        drop(phone);
        let mut reopened = CollabEngine::open("fixture-doc".into(), path).unwrap().0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(
            reopened.blocks()[0].block_background_color.as_deref(),
            Some("#ffecdf")
        );
    }

    /// 通过正式完整快照提交一项显式编号设置；其他块只作为只读设置投影。
    fn numbering_command(engine: &mut CollabEngine, id: &str, edit: &str) -> BlockChangeResult {
        let mut blocks = engine.blocks();
        blocks
            .iter_mut()
            .find(|b| b.id == id)
            .unwrap()
            .ordered
            .as_mut()
            .unwrap()
            .numbering_edit = Some(edit.into());
        engine.apply_block_snapshot(blocks).unwrap()
    }

    /// 中途重新编号与跨段落继续编号遵循桌面计数器，并保留后方显式起点及样式/正文身份。
    #[test]
    fn explicit_numbering_commands_respect_desktop_boundaries_and_preserve_props() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-ordered.update"
        ));
        let before = engine.blocks();
        numbering_command(&mut engine, "b", r#"{"start":1,"continuePrevious":false}"#);
        let blocks = engine.blocks();
        let order = |id: &str| {
            blocks
                .iter()
                .find(|b| b.id == id)
                .unwrap()
                .ordered
                .as_ref()
                .unwrap()
                .order
        };
        assert_eq!((order("a"), order("b"), order("e")), (0, 0, 1));
        assert_eq!((order("c"), order("d")), (0, 1));
        assert_eq!((order("restart"), order("f")), (4, 5));
        assert_eq!(
            (order("h2"), order("h2-next"), order("normal-after")),
            (0, 1, 0)
        );
        numbering_command(&mut engine, "b", r#"{"start":0,"continuePrevious":true}"#);
        let blocks = engine.blocks();
        assert_eq!(
            blocks
                .iter()
                .filter_map(|b| b.ordered.as_ref().map(|v| v.order))
                .collect::<Vec<_>>(),
            vec![0, 1, 0, 1, 2, 4, 5, 0, 1, 0]
        );
        for (old, next) in before.iter().zip(&blocks) {
            assert_eq!(
                (&old.id, &old.text, &old.segments),
                (&next.id, &next.text, &next.segments)
            );
            assert_eq!(
                old.ordered.as_ref().map(|v| &v.marker_style),
                next.ordered.as_ref().map(|v| &v.marker_style)
            );
        }
        // 同一命令重复执行没有新增 Yrs 内容；不因为按钮重复点击制造新编号边界。
        let before_repeat = engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        numbering_command(&mut engine, "b", r#"{"start":0,"continuePrevious":true}"#);
        assert_eq!(
            engine
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default()),
            before_repeat
        );
        let root = engine.doc.get_or_insert_map(ROOT_NAME);
        let txn = engine.doc.transact();
        assert!(map(&map(&root, &txn, "a").unwrap(), &txn, "props")
            .unwrap()
            .contains_key(&txn, "customOrdered"));
    }

    /// 空/显式 null/自定义起点可精确恢复，普通旧快照不覆盖设置；命令增量可在另一副本和缓存恢复。
    #[test]
    fn numbering_undo_settings_are_explicit_atomic_and_persisted() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-ordered.update");
        let mut source = engine(fixture);
        let mut peer = engine(fixture);
        let stale = source.blocks();
        let initial = stale
            .iter()
            .find(|b| b.id == "restart")
            .unwrap()
            .ordered
            .as_ref()
            .unwrap()
            .numbering
            .clone();
        assert_eq!(initial, r#"{"start":5}"#);
        let update = numbering_command(
            &mut source,
            "restart",
            r#"{"start":0,"continuePrevious":true}"#,
        );
        peer.apply_cses_update(update.v1_update).unwrap();
        assert_eq!(source.blocks(), peer.blocks());
        source.apply_block_snapshot(stale).unwrap();
        assert_eq!(
            source
                .blocks()
                .iter()
                .find(|b| b.id == "restart")
                .unwrap()
                .ordered
                .as_ref()
                .unwrap()
                .start,
            None
        );
        numbering_command(&mut source, "restart", &initial);
        let custom = source
            .blocks()
            .into_iter()
            .find(|b| b.id == "restart")
            .unwrap()
            .ordered
            .unwrap();
        assert_eq!(custom.start, Some(5));
        assert_eq!(custom.numbering, initial);
        numbering_command(
            &mut source,
            "a",
            r#"{"start":null,"continuePrevious":null}"#,
        );
        numbering_command(&mut source, "b", "{}");
        let canonical = source.blocks();
        let path = source.database_path.clone();
        let mut reopened = CollabEngine::open("fixture-doc".into(), path).unwrap().0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(canonical, reopened.blocks());
        assert!(canonical.iter().all(|b| b
            .ordered
            .as_ref()
            .is_none_or(|v| v.numbering_edit.is_none())));
        // 在任何根顺序/正文写入前拒绝非法命令，避免失败后留下一半修改。
        let vector = source.doc.transact().state_vector();
        for edit in ["[]", "not-json", r#"{"ms":"n2"}"#] {
            let mut invalid = canonical.clone();
            invalid[0].text.push_str("should-not-write");
            invalid[0].ordered.as_mut().unwrap().numbering_edit = Some(edit.into());
            assert!(source
                .apply_block_snapshot(invalid)
                .unwrap_err()
                .contains("INVALID_ORDERED_PROPERTIES"));
            assert_eq!(source.doc.transact().state_vector(), vector);
        }
        numbering_command(&mut source, "a", r#"{"start":0,"continuePrevious":true}"#);
        assert_eq!(source.blocks()[0].ordered.as_ref().unwrap().order, 0);
    }

    /// 手机创建的列表必须携带桌面读取的零基序号，不能依赖桌面的本地编号插件。
    #[test]
    fn mobile_ordered_items_write_desktop_counters_and_renumber_after_deletion() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        // 此用例验证普通列表；原 fixture 第二项为标题，正式 ordered heading 使用独立计数器。
        let root = engine.doc.get_or_insert_map(ROOT_NAME);
        let mut txn = engine.doc.transact_mut();
        let block = map(&root, &txn, "p2").unwrap();
        map(&block, &txn, "props")
            .unwrap()
            .remove(&mut txn, "heading");
        drop(txn);
        let mut desired = engine.blocks();
        for item in &mut desired {
            item.replaces_id = Some(item.id.clone());
            item.id.push_str("-ordered");
            item.block_type = "numbered_list".into();
            item.indent = 0;
            item.checked = false;
        }
        engine.apply_block_snapshot(desired).unwrap();
        for expected in [vec![0, 1, 2], vec![0, 1]] {
            let blocks = engine.blocks();
            let root = engine.doc.get_or_insert_map(ROOT_NAME);
            let txn = engine.doc.transact();
            let orders: Vec<_> = blocks
                .iter()
                .map(|b| {
                    let block = map(&root, &txn, &b.id).unwrap();
                    out_u32(map(&block, &txn, "props").unwrap().get(&txn, "order"))
                })
                .collect();
            assert_eq!(orders, expected.into_iter().map(Some).collect::<Vec<_>>());
            drop(txn);
            if blocks.len() == 3 {
                let mut next = blocks;
                next.remove(1);
                engine.apply_block_snapshot(next).unwrap();
            }
        }
    }

    /// 转换使用新身份和根 children 替换，桌面必须观察到插入/删除，而不是原位 flavour 写入。
    #[test]
    fn list_conversion_replaces_identity_and_preserves_native_extensions() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let mut desired = engine.blocks();
        desired[0].id = "ordered-new".into();
        desired[0].replaces_id = Some("p1".into());
        desired[0].block_type = "numbered_list".into();
        engine.apply_block_snapshot(desired).unwrap();
        let root = engine.doc.get_or_insert_map(ROOT_NAME);
        let txn = engine.doc.transact();
        assert!(!root.contains_key(&txn, "p1"));
        let block = map(&root, &txn, "ordered-new").unwrap();
        assert_eq!(
            out_string(block.get(&txn, "flavour")).as_deref(),
            Some("ordered")
        );
        assert!(map(&block, &txn, "props")
            .unwrap()
            .contains_key(&txn, "customProp"));
        assert!(map(&block, &txn, "meta")
            .unwrap()
            .contains_key(&txn, "customAudit"));
        let Some(Out::YText(text)) = block.get(&txn, "children") else {
            panic!("editable text");
        };
        assert!(text
            .diff(&txn, |_| ())
            .first()
            .unwrap()
            .attributes
            .as_ref()
            .unwrap()
            .contains_key("a:link"));
    }

    /// 类型切换只清理原类型拥有的设置；恢复有序历史时重建起点，其他扩展属性不受影响。
    #[test]
    fn list_type_switch_cleans_settings_and_restores_ordered_history() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-ordered.update"
        ));
        let original = engine
            .blocks()
            .into_iter()
            .find(|b| b.id == "restart")
            .unwrap();
        let mut desired = engine.blocks();
        let item = desired.iter_mut().find(|b| b.id == "restart").unwrap();
        item.id = "as-todo".into();
        item.replaces_id = Some("restart".into());
        item.block_type = "todo_list".into();
        item.ordered = None;
        item.checked = true;
        engine.apply_block_snapshot(desired).unwrap();
        {
            let blocks = engine.doc.get_or_insert_map(ROOT_NAME);
            let txn = engine.doc.transact();
            let props = map(&map(&blocks, &txn, "as-todo").unwrap(), &txn, "props").unwrap();
            for key in ["start", "continuePrevious", "order", "ms", "heading"] {
                assert!(!props.contains_key(&txn, key), "stale {key}");
            }
        }
        let mut desired = engine.blocks();
        let item = desired.iter_mut().find(|b| b.id == "as-todo").unwrap();
        item.id = "ordered-restored".into();
        item.replaces_id = Some("as-todo".into());
        item.block_type = "numbered_list".into();
        item.ordered = original.ordered.clone();
        item.checked = false;
        engine.apply_block_snapshot(desired).unwrap();
        let restored = engine
            .blocks()
            .into_iter()
            .find(|b| b.id == "ordered-restored")
            .unwrap();
        assert_eq!(
            restored.ordered.as_ref().unwrap().numbering,
            original.ordered.as_ref().unwrap().numbering
        );
        assert_eq!(restored.ordered.as_ref().unwrap().order, 4);
        let blocks = engine.doc.get_or_insert_map(ROOT_NAME);
        let txn = engine.doc.transact();
        let props = map(
            &map(&blocks, &txn, "ordered-restored").unwrap(),
            &txn,
            "props",
        )
        .unwrap();
        assert!(!props.contains_key(&txn, "checked"));
    }

    /// 缺失/null/0/自定义起点在转换历史中精确保留，单个 V1 增量让第二个正式文档得到相同结果。
    #[test]
    fn list_type_history_settings_and_v1_replica_converge() {
        for settings in [
            "{}",
            r#"{"start":null,"continuePrevious":null}"#,
            r#"{"start":0,"continuePrevious":true}"#,
            r#"{"start":5,"continuePrevious":false}"#,
        ] {
            let bytes = include_bytes!("../../tests/fixtures/blockcraft-ordered.update");
            let mut a = engine(bytes);
            let mut b = engine(bytes);
            let update = numbering_command(&mut a, "restart", settings);
            b.apply_cses_update(update.v1_update).unwrap();
            let original = a.blocks().into_iter().find(|v| v.id == "restart").unwrap();
            for (index, kind) in ["bulleted_list", "todo_list", "numbered_list"]
                .into_iter()
                .enumerate()
            {
                let mut desired = a.blocks();
                let item = desired
                    .iter_mut()
                    .find(|v| v.text == original.text)
                    .unwrap();
                item.replaces_id = Some(item.id.clone());
                item.id = format!("conversion-{index}");
                item.block_type = kind.into();
                item.checked = kind == "todo_list";
                item.ordered = if kind == "numbered_list" {
                    original.ordered.clone()
                } else {
                    None
                };
                let update = a.apply_block_snapshot(desired).unwrap();
                assert!(!update.v1_update.is_empty());
                b.apply_cses_update(update.v1_update).unwrap();
                assert_eq!(a.blocks(), b.blocks());
            }
            let restored = a
                .blocks()
                .into_iter()
                .find(|v| v.id == "conversion-2")
                .unwrap();
            assert_eq!(
                restored.ordered.as_ref().unwrap().numbering,
                original.ordered.as_ref().unwrap().numbering
            );
        }
    }

    /// 类型替换中的编号初始值也必须在写事务前验证，不得借恢复历史覆盖任意原生 props。
    #[test]
    fn invalid_list_conversion_settings_are_atomic() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-ordered.update"
        ));
        let before = engine.doc.transact().state_vector();
        let mut desired = engine.blocks();
        let item = desired.iter_mut().find(|b| b.id == "restart").unwrap();
        item.id = "invalid-history".into();
        item.replaces_id = Some("restart".into());
        item.ordered.as_mut().unwrap().numbering = r#"{"checked":1}"#.into();
        assert!(engine
            .apply_block_snapshot(desired)
            .unwrap_err()
            .starts_with("INVALID_ORDERED_PROPERTIES"));
        assert_eq!(engine.doc.transact().state_vector(), before);
    }

    /// 与桌面相同的段落续号、缩进、ordered heading、显式起始值和预设继承。
    #[test]
    fn desktop_ordered_boundaries_styles_and_starts_survive_mobile_edits() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-ordered.update"
        ));
        let ordered: Vec<_> = engine
            .blocks()
            .iter()
            .filter_map(|b| b.ordered.as_ref().map(|v| v.order))
            .collect();
        assert_eq!(ordered, vec![0, 1, 0, 1, 2, 4, 5, 0, 1, 0]);
        assert_eq!(
            engine.blocks()[2]
                .ordered
                .as_ref()
                .unwrap()
                .marker_style
                .as_deref(),
            None
        );
        let mut desired = engine.blocks();
        desired.retain(|b| b.id != "b");
        let mut inserted = desired[0].clone();
        inserted.id = "new-ordered".into();
        inserted.text = "new".into();
        inserted.segments.clear();
        desired.insert(1, inserted);
        engine.apply_block_snapshot(desired).unwrap();
        assert!(engine
            .blocks()
            .iter()
            .filter_map(|b| b.ordered.as_ref())
            .all(|v| !v.needs_repair));
        let root = engine.doc.get_or_insert_map(ROOT_NAME);
        let txn = engine.doc.transact();
        let props = map(&map(&root, &txn, "new-ordered").unwrap(), &txn, "props").unwrap();
        assert_eq!(out_string(props.get(&txn, "ms")).as_deref(), Some("a2"));
        let props = map(&map(&root, &txn, "restart").unwrap(), &txn, "props").unwrap();
        assert_eq!(out_u32(props.get(&txn, "start")), Some(5));
        assert_eq!(props.get(&txn, "ms"), Some(Out::Any(Any::Null)));
        assert!(map(&map(&root, &txn, "a").unwrap(), &txn, "props")
            .unwrap()
            .contains_key(&txn, "customOrdered"));
        drop(txn);
        let vector = engine.doc.transact().state_vector();
        engine.apply_block_snapshot(engine.blocks()).unwrap();
        assert_eq!(engine.doc.transact().state_vector(), vector);
    }

    /// 原位 flavour 转换和无效替换来源在事务前失败，不遗失原块及其未知字段。
    #[test]
    fn invalid_conversion_does_not_mutate_doc() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let before = engine.doc.transact().state_vector();
        let mut desired = engine.blocks();
        desired[0].block_type = "numbered_list".into();
        assert!(engine
            .apply_block_snapshot(desired.clone())
            .unwrap_err()
            .contains("INVALID_BLOCK_CONVERSION"));
        desired[0].id = "new".into();
        desired[0].replaces_id = Some("missing".into());
        assert!(engine
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("INVALID_BLOCK_CONVERSION"));
        assert_eq!(before, engine.doc.transact().state_vector());
    }

    /// 旧手机未保存 order 时可只修复编号，不替换身份、文本或用户扩展属性。
    #[test]
    fn legacy_missing_orders_are_repaired_without_changing_content_or_identity() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-ordered.update"
        ));
        let root = engine.doc.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = engine.doc.transact_mut();
            for id in ["a", "b", "c"] {
                let block = map(&root, &txn, id).unwrap();
                map(&block, &txn, "props")
                    .unwrap()
                    .remove(&mut txn, "order");
            }
        }
        let before = engine.blocks();
        assert_eq!(
            before
                .iter()
                .filter(|b| b.ordered.as_ref().is_some_and(|v| v.needs_repair))
                .count(),
            3
        );
        let update = engine
            .apply_block_snapshot(before.clone())
            .unwrap()
            .v1_update;
        assert_ne!(update, [0, 0]);
        let after = engine.blocks();
        assert_eq!(
            before.iter().map(|b| (&b.id, &b.text)).collect::<Vec<_>>(),
            after.iter().map(|b| (&b.id, &b.text)).collect::<Vec<_>>()
        );
        assert!(after
            .iter()
            .filter_map(|b| b.ordered.as_ref())
            .all(|v| !v.needs_repair));
        let txn = engine.doc.transact();
        let props = map(&map(&root, &txn, "a").unwrap(), &txn, "props").unwrap();
        assert!(props.contains_key(&txn, "customOrdered"));
        assert_eq!(out_string(props.get(&txn, "ms")).as_deref(), Some("a2"));
    }

    /// 使用当前桌面 ImageBlockSchema 的真实 Yjs 编码，图片携带题注时仍应可编辑。
    #[test]
    fn current_image_schema_with_caption_is_editable() {
        let engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-image.update"
        ));
        let projection = project(&engine.doc, "fixture-doc");
        assert_eq!(projection.reason, None);
        assert_eq!(projection.blocks.len(), 4);
        assert_eq!(projection.blocks[3].text, "https://example.test/image.png");
        assert_eq!(projection.blocks[3].alignment, "right");
    }

    /// 写回原 Y.Text，验证未建模 props/meta/属性保持原值，颜色使用桌面可读的 CSS。
    #[test]
    fn edits_preserve_unknown_fields_and_native_shared_types() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let map = engine.doc.get_or_insert_map(ROOT_NAME);
        let (props_before, meta_before) = {
            let txn = engine.doc.transact();
            let p = super::map(&map, &txn, "p1").unwrap();
            (
                super::map(&p, &txn, "props").unwrap().to_json(&txn),
                super::map(&p, &txn, "meta").unwrap().to_json(&txn),
            )
        };
        let mut desired = engine.blocks();
        desired[0].text.push_str("追加");
        desired[0].segments[0].text = desired[0].text.clone();
        desired[0].segments[0].bold = false;
        desired[0].segments[0].italic = true;
        desired[0].segments[0].text_color = Some("0xff2196f3".into());
        desired[2].checked = false;
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let p = super::map(&map, &txn, "p1").unwrap();
        assert_eq!(
            super::map(&p, &txn, "props").unwrap().to_json(&txn),
            props_before
        );
        assert_eq!(
            super::map(&p, &txn, "meta").unwrap().to_json(&txn),
            meta_before
        );
        let Some(Out::YText(text)) = p.get(&txn, "children") else {
            panic!("must retain native text");
        };
        let chunks = text.diff(&txn, |_| ());
        let attrs = chunks[0].attributes.as_ref().unwrap();
        assert_eq!(
            attrs.get("a:link"),
            Some(&Any::String("https://example.test".into()))
        );
        assert_eq!(attrs.get("t:ff"), Some(&Any::String("serif".into())));
        assert_eq!(attrs.get("a:italic"), Some(&Any::Bool(true)));
        assert_eq!(attrs.get("s:color"), Some(&Any::String("#2196f3".into())));
        assert!(!attrs.contains_key("bold"));
        assert!(!attrs.contains_key("a:bold"));
        assert_eq!(text.get_string(&txn), "正文😀追加");
        drop(txn);
        assert!(!engine.blocks()[2].checked);
    }

    /// 未知容器、内嵌对象和锁都允许完整接收/保存，但任何本地写入在事务前被拒绝。
    #[test]
    fn unsupported_content_is_preserved_and_read_only() {
        for bytes in [
            include_bytes!("../../tests/fixtures/blockcraft-unknown.update").as_slice(),
            include_bytes!("../../tests/fixtures/blockcraft-embed.update").as_slice(),
            include_bytes!("../../tests/fixtures/blockcraft-locked.update").as_slice(),
        ] {
            let mut engine = engine(bytes);
            let before = engine
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default());
            let count = load_updates(&engine.connection, &engine.document_id)
                .unwrap()
                .len();
            assert!(project(&engine.doc, "fixture-doc").reason.is_some());
            assert!(engine
                .apply_block_snapshot(engine.blocks())
                .unwrap_err()
                .contains("READ_ONLY_DOCUMENT"));
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
        }
    }

    /// 新增、类型转换、重排和删除只更新正式 children 数组与目标块，不写 Demo 私有根。
    #[test]
    fn structural_edits_and_sqlite_restore_use_formal_schema() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let mut desired = engine.blocks();
        desired.remove(1);
        desired[1].replaces_id = Some(desired[1].id.clone());
        desired[1].id = "ordered-todo".into();
        desired[1].block_type = "numbered_list".into();
        desired[1].checked = false;
        desired.insert(
            0,
            CollabBlock {
                id: "new-p".into(),
                block_type: "quote".into(),
                text: "新引用".into(),
                segments: Vec::new(),
                checked: false,
                alignment: "center".into(),
                indent: 0,
                image: None,
                ordered: None,
                replaces_id: None,
                block_background_color: None,
                block_border_color: None,
            },
        );
        engine.apply_block_snapshot(desired.clone()).unwrap();
        let actual = engine.blocks();
        for item in &mut desired {
            item.replaces_id = None;
            item.ordered = actual
                .iter()
                .find(|b| b.id == item.id)
                .unwrap()
                .ordered
                .clone();
        }
        assert_eq!(actual, desired);
        validate(&engine.doc, "fixture-doc").unwrap();
        let mut reopened =
            CollabEngine::open(engine.document_id.clone(), engine.database_path.clone())
                .unwrap()
                .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), engine.blocks());
        let map = engine.doc.get_or_insert_map(ROOT_NAME);
        let txn = engine.doc.transact();
        assert_eq!(engine.block_order.len(&txn), 0);
        assert!(!map.contains_key(&txn, "p2"));
        assert_eq!(
            out_string(
                super::map(&map, &txn, "ordered-todo")
                    .unwrap()
                    .get(&txn, "flavour")
            )
            .as_deref(),
            Some("ordered")
        );
    }

    /// 正式块同一文本的并发插入，以及互不重叠的格式操作通过原始增量收敛。
    #[test]
    fn concurrent_formal_text_and_format_edits_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-basic.update");
        let mut a = engine(fixture);
        let mut b = engine(fixture);
        let mut left = a.blocks();
        let mut right = b.blocks();
        left[1].text.insert_str(0, "甲");
        right[1].text.push_str("乙");
        left[0].segments[0].italic = true;
        right[0].segments[0].underline = true;
        let a_update = a.apply_block_snapshot(left).unwrap().v1_update;
        let b_update = b.apply_block_snapshot(right).unwrap().v1_update;
        a.apply_cses_update(b_update).unwrap();
        b.apply_cses_update(a_update).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        assert_eq!(a.blocks()[1].text, "甲标题乙");
        assert!(a.blocks()[0].segments[0].italic);
        assert!(a.blocks()[0].segments[0].underline);
    }

    /// 手机专属封面/标题或隐藏身份冲突都在事务开始前拒绝，不改原正文。
    #[test]
    fn unsupported_local_types_do_not_mutate_formal_doc() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let before = engine.doc.transact().state_vector();
        let mut desired = engine.blocks();
        desired[0].block_type = "document_title".into();
        assert!(engine
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("UNSUPPORTED_BLOCK_TYPE"));
        assert_eq!(engine.doc.transact().state_vector(), before);
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
    }

    /// 空 root 允许新增正式内容；媒体与正文相互转换时，children 使用正确的共享类型。
    #[test]
    fn empty_root_and_media_edits_keep_native_children_types() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        engine.apply_block_snapshot(Vec::new()).unwrap();
        assert!(engine.blocks().is_empty());
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
        let mut block = CollabBlock {
            id: "media".into(),
            block_type: "image".into(),
            text: "https://example.test/image.png".into(),
            segments: Vec::new(),
            checked: false,
            alignment: "left".into(),
            indent: 0,
            image: None,
            ordered: None,
            replaces_id: None,
            block_background_color: None,
            block_border_color: None,
        };
        for kind in ["image", "video", "paragraph"] {
            if kind != "image" {
                block.replaces_id = Some(block.id.clone());
                block.id = format!("media-{kind}");
            }
            block.block_type = kind.into();
            block.image = if kind == "image" {
                Some(CollabImage {
                    width_ratio: Some(100.0),
                    ..Default::default()
                })
            } else {
                None
            };
            engine.apply_block_snapshot(vec![block.clone()]).unwrap();
            let mut expected = block.clone();
            expected.replaces_id = None;
            assert_eq!(engine.blocks(), vec![expected]);
            validate(&engine.doc, "fixture-doc").unwrap();
            let txn = engine.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let stored = super::map(&blocks, &txn, &block.id).unwrap();
            assert!(match stored.get(&txn, "children") {
                Some(Out::YArray(_)) => kind != "paragraph",
                Some(Out::YText(_)) => kind == "paragraph",
                _ => false,
            });
        }
    }

    /// 远端修订元数据即使不改变正文投影，也立即关闭写入并完整保留原记录。
    #[test]
    fn remote_revision_metadata_disables_writes_without_changing_blocks() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-basic.update");
        let mut engine = engine(fixture);
        let before = engine.blocks();
        let remote = create_compatible_doc();
        remote
            .transact_mut()
            .apply_update(Update::decode_v1(fixture).unwrap())
            .unwrap();
        let vector = remote.transact().state_vector();
        let revisions = remote.get_or_insert_map("bc:revisions");
        revisions.insert(&mut remote.transact_mut(), "revision-1", "opaque-record");
        let update = remote.transact().encode_state_as_update_v1(&vector);
        engine.apply_cses_update(update).unwrap();
        assert_eq!(engine.blocks(), before);
        assert!(project(&engine.doc, "fixture-doc").reason.is_some());
        assert!(engine
            .apply_block_snapshot(before)
            .unwrap_err()
            .contains("READ_ONLY_DOCUMENT"));
        let txn = engine.doc.transact();
        assert_eq!(
            out_string(txn.get_map("bc:revisions").unwrap().get(&txn, "revision-1")),
            Some("opaque-record".into())
        );
    }

    /// URL、布局和题注分别更新原共享字段；未知图片属性、题注格式和元数据保持不变。
    #[test]
    fn image_edits_preserve_caption_tree_and_unknown_fields() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-image.update"
        ));
        let mut desired = engine.blocks();
        let image = desired[3].image.as_mut().unwrap();
        assert_eq!(image.width_ratio, Some(60.0));
        assert_eq!(image.captions[0].id, "caption-1");
        image.width_ratio = Some(80.0);
        image.captions[0].text.push_str("手机");
        desired[3].text = "https://example.test/replaced.png".into();
        desired[3].alignment = "center".into();
        engine.apply_block_snapshot(desired.clone()).unwrap();
        let actual = engine.blocks();
        for item in &mut desired {
            item.replaces_id = None;
            item.ordered = actual
                .iter()
                .find(|b| b.id == item.id)
                .unwrap()
                .ordered
                .clone();
        }
        assert_eq!(actual, desired);
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let stored = super::map(&blocks, &txn, "image-1").unwrap();
        assert_eq!(children(&stored, &txn), vec!["caption-1"]);
        assert_eq!(
            out_string(stored.get(&txn, "nodeType")).as_deref(),
            Some("block")
        );
        let props = super::map(&stored, &txn, "props").unwrap();
        assert_eq!(number(&props, &txn, "ar"), Some(1.5));
        assert_eq!(number(&props, &txn, "rotation"), Some(15.0));
        assert!(props.contains_key(&txn, "customImage"));
        assert!(!props.contains_key(&txn, "textAlign"));
        let caption = super::map(&blocks, &txn, "caption-1").unwrap();
        assert!(super::map(&caption, &txn, "meta")
            .unwrap()
            .contains_key(&txn, "customAudit"));
        assert_eq!(
            number(
                &super::map(&caption, &txn, "props").unwrap(),
                &txn,
                "customCaption"
            ),
            Some(42.0)
        );
        let Some(Out::YText(text)) = caption.get(&txn, "children") else {
            panic!()
        };
        let chunks = text.diff(&txn, |_| ());
        assert_eq!(
            chunks[0].attributes.as_ref().unwrap().get("a:bold"),
            Some(&Any::Bool(true))
        );
        assert!(chunks[0]
            .attributes
            .as_ref()
            .unwrap()
            .contains_key("a:link"));
        drop(txn);
        let mut reopened =
            CollabEngine::open(engine.document_id.clone(), engine.database_path.clone())
                .unwrap()
                .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), desired);
    }

    /// 不同端分别改资源、比例和同一题注文字，原始 Yjs 增量交换后收敛。
    #[test]
    fn concurrent_image_updates_and_caption_text_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-image.update");
        let mut a = engine(fixture);
        let mut b = engine(fixture);
        let mut left = a.blocks();
        let mut right = b.blocks();
        left[3].text = "https://example.test/new.png".into();
        left[3].image.as_mut().unwrap().captions[0]
            .text
            .insert_str(0, "甲");
        right[3].image.as_mut().unwrap().width_ratio = Some(35.0);
        right[3].image.as_mut().unwrap().captions[0]
            .text
            .push_str("乙");
        let au = a.apply_block_snapshot(left).unwrap().v1_update;
        let bu = b.apply_block_snapshot(right).unwrap().v1_update;
        a.apply_cses_update(bu).unwrap();
        b.apply_cses_update(au).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        let image = a.blocks().remove(3);
        assert_eq!(image.text, "https://example.test/new.png");
        assert_eq!(image.image.as_ref().unwrap().width_ratio, Some(35.0));
        assert_eq!(
            image.image.as_ref().unwrap().captions[0].text,
            "甲图片题注😀乙"
        );
    }

    /// 题注身份冲突/非法尺寸/带题注转换均在事务前拒绝；删除图片会同步删除其题注。
    #[test]
    fn image_preflight_and_recursive_removal_are_safe() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-image.update"
        ));
        for variant in 0..3 {
            let before = engine.doc.transact().state_vector();
            let mut desired = engine.blocks();
            match variant {
                0 => desired[3].image.as_mut().unwrap().width_ratio = Some(f64::NAN),
                1 => desired[3].image.as_mut().unwrap().captions[0].id = "p1".into(),
                _ => {
                    desired[3].block_type = "paragraph".into();
                    desired[3].image = None;
                }
            }
            assert!(engine.apply_block_snapshot(desired).is_err());
            assert_eq!(engine.doc.transact().state_vector(), before);
        }
        let mut desired = engine.blocks();
        desired.pop();
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        assert!(!blocks.contains_key(&txn, "image-1"));
        assert!(!blocks.contains_key(&txn, "caption-1"));
        assert!(blocks.contains_key(&txn, "p1"));
    }

    /// 无题注图片添加题注时创建真实 caption/Y.Text，后续远端锁定立即禁止本地写入。
    #[test]
    fn new_caption_uses_native_text_and_remote_lock_is_read_only() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-image.update"
        ));
        let mut desired = engine.blocks();
        desired[3].image.as_mut().unwrap().captions.clear();
        engine.apply_block_snapshot(desired.clone()).unwrap();
        desired[3]
            .image
            .as_mut()
            .unwrap()
            .captions
            .push(CollabImageCaption {
                id: "new-caption".into(),
                text: "手机添加😀".into(),
            });
        engine.apply_block_snapshot(desired.clone()).unwrap();
        let actual = engine.blocks();
        for item in &mut desired {
            item.replaces_id = None;
            item.ordered = actual
                .iter()
                .find(|b| b.id == item.id)
                .unwrap()
                .ordered
                .clone();
        }
        assert_eq!(actual, desired);
        let remote = create_compatible_doc();
        let state = engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        remote
            .transact_mut()
            .apply_update(Update::decode_v1(&state).unwrap())
            .unwrap();
        let before = remote.transact().state_vector();
        let blocks = remote.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = remote.transact_mut();
            let caption = super::map(&blocks, &txn, "new-caption").unwrap();
            assert!(matches!(caption.get(&txn, "children"), Some(Out::YText(_))));
            let meta = super::map(&caption, &txn, "meta").unwrap();
            meta.insert(&mut txn, "lock", "fixture-owner");
        }
        engine
            .apply_cses_update(remote.transact().encode_state_as_update_v1(&before))
            .unwrap();
        assert!(project(&engine.doc, "fixture-doc").reason.is_some());
        assert!(engine
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_DOCUMENT"));
    }

    /// 旧版像素尺寸只参与展示，改 URL 不自动补 wr/ar 或丢掉原 width/height。
    #[test]
    fn legacy_image_size_is_preserved_when_only_url_changes() {
        let remote = create_compatible_doc();
        remote
            .transact_mut()
            .apply_update(
                Update::decode_v1(include_bytes!(
                    "../../tests/fixtures/blockcraft-image.update"
                ))
                .unwrap(),
            )
            .unwrap();
        let blocks = remote.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = remote.transact_mut();
            let image = super::map(&blocks, &txn, "image-1").unwrap();
            let props = super::map(&image, &txn, "props").unwrap();
            props.remove(&mut txn, "wr");
            props.remove(&mut txn, "ar");
            props.insert(&mut txn, "width", 600);
            props.insert(&mut txn, "height", 200);
        }
        let state = remote
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let mut engine = engine(&state);
        let mut desired = engine.blocks();
        assert_eq!(desired[3].image.as_ref().unwrap().width, Some(600.0));
        desired[3].text = "https://example.test/replacement.png".into();
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let image = super::map(&blocks, &txn, "image-1").unwrap();
        let props = super::map(&image, &txn, "props").unwrap();
        assert!(!props.contains_key(&txn, "wr"));
        assert!(!props.contains_key(&txn, "ar"));
        assert_eq!(number(&props, &txn, "width"), Some(600.0));
        assert_eq!(number(&props, &txn, "height"), Some(200.0));
    }
}
