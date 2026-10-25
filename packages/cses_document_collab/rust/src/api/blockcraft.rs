//! 正式 BlockCraft 的 Yrs 适配。`blocks` 中的嵌套共享类型始终是权威数据，
//! Flutter 快照只是投影；写入只修改明确支持的字段，保留 props/meta/行内未知属性。
//! 高亮及普通/合并表格容器按父子关系投影；未知块/容器及含未适配行内对象的正文仅显示只读占位，
//! 原始子树和 Y.Text 不参与快照写入，不阻止其他已适配块编辑。

use super::*;
use std::collections::HashMap;
use yrs::types::AsPrelim;
use yrs::{ArrayPrelim, MapPrelim, TextPrelim, TextRef};

pub(super) const ROOT_NAME: &str = "blocks";
pub(super) const UNSUPPORTED_BLOCK_TYPE: &str = "unsupported";

/// 占位只保存真实身份和已适配父容器；正文、属性和隐藏子树始终留在原共享类型。
fn placeholder(id: String, parent_id: Option<String>) -> CollabBlock {
    CollabBlock {
        paragraph_style: None,
        id,
        parent_id,
        block_type: UNSUPPORTED_BLOCK_TYPE.into(),
        text: String::new(),
        segments: Vec::new(),
        checked: false,
        alignment: "left".into(),
        indent: 0,
        image: None,
        ordered: None,
        code: None,
        resource: None,
        replaces_id: None,
        block_background_color: None,
        block_border_color: None,
        callout_prefix: None,
        block_text_color: None,
    }
}
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
/// 计数器key使用原始heading，保留旧分组身份；对外标题投影限制0～6，不回写原属性。
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
                    heading: heading.min(6),
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

fn code_properties<T: ReadTxn>(props: &MapRef, txn: &T) -> String {
    let mut values = std::collections::BTreeMap::new();
    for key in ["lang", "blockName", "collapse"] {
        if let Some(Out::Any(value)) = props.get(txn, key) {
            values.insert(key, value);
        }
    }
    serde_json::to_string(&values).expect("代码属性可序列化")
}

/// Validate every patch before any write, including exact remove vs null undo.
fn parse_code_edit(input: &str) -> Result<HashMap<String, Option<Any>>, String> {
    let invalid = || "INVALID_CODE_PROPERTIES: 代码属性补丁不合法".to_owned();
    if input.len() > 16384 {
        return Err(invalid());
    }
    let Any::Map(values) = Any::from_json(input).map_err(|_| invalid())? else {
        return Err(invalid());
    };
    let mut result = HashMap::new();
    for (key, wrapper) in values.iter() {
        if !matches!(key.as_str(), "lang" | "blockName" | "collapse") {
            return Err(invalid());
        }
        let Any::Map(wrapper) = wrapper else {
            return Err(invalid());
        };
        if wrapper.keys().any(|k| k != "value") {
            return Err(invalid());
        }
        let value = wrapper.get("value").cloned();
        match (key.as_str(), &value) {
            (_, None | Some(Any::Null)) => {}
            ("lang", Some(Any::String(s))) if !s.trim().is_empty() && s.len() <= 80 => {}
            ("blockName", Some(Any::String(s))) if s.len() <= 4096 => {}
            ("collapse", Some(Any::Bool(_))) => {}
            _ => return Err(invalid()),
        }
        result.insert(key.clone(), value);
    }
    Ok(result)
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

/// 表格结构节点保留独立身份，正文继续使用各自的共享 Y.Text。
fn is_table_container(kind: &str) -> bool {
    matches!(kind, "table" | "table-row" | "table-cell")
}

/// 校验包含隐藏占位的桌面矩形网格，拒绝越界、交叠、悬空隐藏和超限结构。
fn valid_table_grid(rows: &[Vec<(usize, usize, bool)>]) -> bool {
    let columns = rows.first().map_or(0, Vec::len);
    if rows.is_empty()
        || rows.len() > 100
        || columns == 0
        || columns > 50
        || rows.len() * columns > 500
        || rows.iter().any(|row| row.len() != columns)
    {
        return false;
    }
    let mut covered = vec![vec![false; columns]; rows.len()];
    for (r, row) in rows.iter().enumerate() {
        for (c, &(height, width, hidden)) in row.iter().enumerate() {
            if hidden {
                if !covered[r][c] {
                    return false;
                }
                continue;
            }
            if height == 0 || width == 0 || r + height > rows.len() || c + width > columns {
                return false;
            }
            for rr in r..r + height {
                for cc in c..c + width {
                    if covered[rr][cc] || ((rr != r || cc != c) && !rows[rr][cc].2) {
                        return false;
                    }
                    covered[rr][cc] = true;
                }
            }
        }
    }
    true
}

/// 从真实共享类型验证桌面网格；无法完整解释时整张表保留为占位。
fn supported_table<T: ReadTxn>(table: &MapRef, blocks: &MapRef, txn: &T) -> bool {
    let mut grid = Vec::new();
    for id in children(table, txn) {
        let Some(row) = map(blocks, txn, &id) else {
            return false;
        };
        if out_string(row.get(txn, "flavour")).as_deref() != Some("table-row")
            || out_string(row.get(txn, "nodeType")).as_deref() != Some("block")
        {
            return false;
        }
        let mut cells = Vec::new();
        for id in children(&row, txn) {
            let Some(cell) = map(blocks, txn, &id) else {
                return false;
            };
            let Some(props) = map(&cell, txn, "props") else {
                return false;
            };
            if out_string(cell.get(txn, "flavour")).as_deref() != Some("table-cell")
                || out_string(cell.get(txn, "nodeType")).as_deref() != Some("block")
            {
                return false;
            }
            cells.push((
                out_u32(props.get(txn, "rowspan")).unwrap_or(1) as usize,
                out_u32(props.get(txn, "colspan")).unwrap_or(1) as usize,
                out_string(props.get(txn, "display")).as_deref() == Some("none"),
            ));
        }
        grid.push(cells);
    }
    if !valid_table_grid(&grid) {
        return false;
    }
    if let Some(props) = map(table, txn, "props") {
        if let Some(Out::Any(Any::Array(widths))) = props.get(txn, "colWidths") {
            if widths.len() != grid[0].len() {
                return false;
            }
        }
    }
    true
}

/// 判断投影节点是否位于表格子树中，支持删除后按原身份恢复未知属性与审计数据。
fn in_table(block: &CollabBlock, all: &HashMap<&str, &CollabBlock>) -> bool {
    let mut current = block;
    for _ in 0..256 {
        if current.block_type == "table" {
            return true;
        }
        let Some(parent) = current.parent_id.as_deref().and_then(|id| all.get(id)) else {
            return false;
        };
        current = parent;
    }
    false
}

/// 解析表格白名单属性；显式补丁用 value 包装区分移除与null，未经触碰的扩展数据不回放。
fn table_properties(
    kind: &str,
    input: &str,
    initial: bool,
) -> Result<HashMap<String, Option<Any>>, String> {
    let fail = || "INVALID_TABLE: 表格属性无效".to_owned();
    let value: serde_json::Value = serde_json::from_str(input).map_err(|_| fail())?;
    let object = value.as_object().ok_or_else(fail)?;
    let mut result = HashMap::new();
    for (key, value) in object {
        if !resource_keys(kind).contains(&key.as_str()) {
            return Err(fail());
        }
        let value = if initial {
            Some(value)
        } else {
            value.as_object().ok_or_else(fail)?.get("value")
        };
        if let Some(value) = value.filter(|v| !v.is_null()) {
            let valid = match key.as_str() {
                "colWidths" => value.as_array().is_some_and(|values| {
                    !values.is_empty()
                        && values.len() <= 50
                        && values.iter().all(|v| {
                            v.as_f64()
                                .is_some_and(|v| v.is_finite() && v > 0.0 && v <= 10000.0)
                        })
                }),
                "rowspan" | "colspan" => value.as_u64().is_some_and(|v| (1..=100).contains(&v)),
                "height" => value
                    .as_f64()
                    .is_some_and(|v| v.is_finite() && v > 0.0 && v <= 10000.0),
                "display" => value.as_str().is_some_and(|v| matches!(v, "" | "none")),
                "verticalAlign" => value
                    .as_str()
                    .is_some_and(|v| matches!(v, "top" | "middle" | "bottom")),
                _ => false,
            };
            if !valid {
                return Err(fail());
            }
        }
        result.insert(
            key.clone(),
            match value {
                Some(value) => Some(serde_json::from_value(value.clone()).map_err(|_| fail())?),
                None => None,
            },
        );
    }
    Ok(result)
}

/// 在取得写事务前检查表格层级、列宽数和合并覆盖关系，错误不会产生部分写入。
/// Validate projected table grids before local snapshots or native history commit.
pub(super) fn validate_tables(desired: &[CollabBlock]) -> Result<(), String> {
    let by_id: HashMap<_, _> = desired.iter().map(|b| (b.id.as_str(), b)).collect();
    let mut children_by_parent: HashMap<&str, Vec<&CollabBlock>> = HashMap::new();
    for block in desired {
        if let Some(parent) = block.parent_id.as_deref() {
            children_by_parent.entry(parent).or_default().push(block);
        }
    }
    let fail = || "INVALID_TABLE: 表格层级、尺寸或合并范围无效".to_owned();
    for block in desired {
        let parent = block.parent_id.as_deref().and_then(|id| by_id.get(id));
        match block.block_type.as_str() {
            "table" if parent.is_some_and(|p| p.block_type != "callout") => return Err(fail()),
            "table-row" if parent.is_none_or(|p| p.block_type != "table") => return Err(fail()),
            "table-cell" if parent.is_none_or(|p| p.block_type != "table-row") => {
                return Err(fail())
            }
            _ if parent.is_some_and(|p| {
                (p.block_type == "table" && block.block_type != "table-row")
                    || (p.block_type == "table-row" && block.block_type != "table-cell")
            }) =>
            {
                return Err(fail())
            }
            _ => {}
        }
        if block.block_type != "table" {
            continue;
        }
        let mut grid = Vec::new();
        for row in children_by_parent
            .get(block.id.as_str())
            .into_iter()
            .flatten()
        {
            let mut cells = Vec::new();
            for cell in children_by_parent
                .get(row.id.as_str())
                .into_iter()
                .flatten()
            {
                let props: serde_json::Value = serde_json::from_str(
                    cell.resource
                        .as_ref()
                        .map_or("{}", |v| v.properties.as_str()),
                )
                .map_err(|_| fail())?;
                cells.push((
                    props.get("rowspan").and_then(|v| v.as_u64()).unwrap_or(1) as usize,
                    props.get("colspan").and_then(|v| v.as_u64()).unwrap_or(1) as usize,
                    props.get("display").and_then(|v| v.as_str()) == Some("none"),
                ));
            }
            grid.push(cells);
        }
        if !valid_table_grid(&grid) {
            return Err(fail());
        }
        let props: serde_json::Value = serde_json::from_str(
            block
                .resource
                .as_ref()
                .map_or("{}", |v| v.properties.as_str()),
        )
        .map_err(|_| fail())?;
        if props
            .get("colWidths")
            .and_then(|v| v.as_array())
            .is_some_and(|v| v.len() != grid[0].len())
        {
            return Err(fail());
        }
    }
    Ok(())
}

/// Mermaid 只接受一个纯文本源码子块；异常或对象内容整棵保留为占位。
fn supported_mermaid<T: ReadTxn>(block: &MapRef, blocks: &MapRef, txn: &T) -> bool {
    let ids = children(block, txn);
    if ids.len() != 1 {
        return false;
    }
    let Some(source) = map(blocks, txn, &ids[0]) else {
        return false;
    };
    if map(&source, txn, "props").is_none() {
        return false;
    }
    if out_string(source.get(txn, "flavour")).as_deref() != Some("mermaid-textarea")
        || out_string(source.get(txn, "nodeType")).as_deref() != Some("editable")
    {
        return false;
    }
    let Some(Out::YText(text)) = source.get(txn, "children") else {
        return false;
    };
    text.get_string(txn).encode_utf16().count() <= 100_000
        && text
            .diff(txn, |_| ())
            .iter()
            .all(|chunk| matches!(&chunk.insert, Out::Any(Any::String(_))))
}

/// 将正式 flavour/props 转为手机可编辑类型；不支持的类型返回 None，不降级写回 paragraph。
/// 标题仅投影 H1~H6，超范围正值按 H6 展示；投影不回写原始 props。
fn mobile_type<T: ReadTxn>(block: &MapRef, props: &MapRef, txn: &T) -> Option<String> {
    let flavour = out_string(block.get(txn, "flavour"))?;
    Some(match flavour.as_str() {
        "paragraph" => match out_u32(props.get(txn, "heading")) {
            Some(level) if level > 0 => format!("heading_{}", level.min(6)),
            _ => "paragraph".to_owned(),
        },
        "bullet" => "bulleted_list".to_owned(),
        "ordered" => "numbered_list".to_owned(),
        "todo" => "todo_list".to_owned(),
        "blockquote" => "quote".to_owned(),
        "table" | "table-row" | "table-cell" => flavour,
        "code" | "image" | "video" | "callout" | "mermaid" | "mermaid-textarea" | "date-card"
        | "divider" | "page-divider" | "formula" | "meeting" | "task" | "kr-list" => flavour,
        s if is_resource_block_type(s) => flavour,
        _ => return None,
    })
}

/// 桌面视频用 props.url；兼容早期移动端写入的 src，但显式 url 始终优先。
/// 仅网络资源支持原生播放器；空值、上传中的 blob 和嵌入代码均原样保留为占位。
fn video_url<T: ReadTxn>(props: &MapRef, txn: &T) -> Option<String> {
    match props.get(txn, "sourceType") {
        None => {}
        Some(Out::Any(Any::String(value))) if matches!(value.as_ref(), "link" | "local") => {}
        _ => return None,
    }
    let key = if props.contains_key(txn, "url") {
        "url"
    } else {
        "src"
    };
    let url = out_string(props.get(txn, key))?;
    let (scheme, rest) = url.split_once("://")?;
    if !(scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https"))
        || rest.split(['/', '?', '#']).next().is_none_or(str::is_empty)
        || url.chars().any(char::is_whitespace)
    {
        return None;
    }
    Some(url)
}

/// 桌面 0.11.14 的三类分割线预设；未知远端样式只投影，不能作为新设置写入。
fn is_divider_style(style: &str) -> bool {
    matches!(
        style,
        "solid"
            | "dashed"
            | "dotted"
            | "double"
            | "fade"
            | "wave"
            | "zigzag"
            | "sketch"
            | "triple-dot"
            | "diamond"
            | "tape-dot-black"
            | "tape-grid-pattern"
            | "tape-regular-lines"
            | "tape-gradient-blocks"
            | "tape-gray-lines"
            | "edge-grass"
            | "edge-flower"
            | "edge-vine"
            | "edge-daisy"
            | "edge-stars"
            | "edge-berries"
    )
}

/// 已适配块的属性白名单；表格布局通过显式补丁写入，日期卡片/会议/任务/分割线/公式/绘图不使用资源 URL。
fn resource_keys(kind: &str) -> &'static [&'static str] {
    match kind {
        "formula" => &["latex"],
        "mermaid" => &["mode"],
        "meeting" => &["meetingId", "title", "number"],
        "kr-list" => &["meetingId"],
        "task" => &["taskId", "title"],
        "table" => &["colWidths"],
        "table-row" => &["height"],
        "table-cell" => &["verticalAlign", "rowspan", "colspan", "display"],
        "date-card" => &[
            "date",
            "style",
            "format",
            "bg",
            "fg",
            "bc",
            "bw",
            "ff",
            "width",
            "height",
            "fsCalendar",
            "fsSquare",
            "fsBanner",
            "fsMinibar",
            "fsTicket",
            "fsStamp",
            "fsFlip",
            "fsMasthead",
            "fsBookmark",
            "fsSplit",
            "fsPill",
            "fsRail",
        ],
        "divider" => &[
            "style",
            "length",
            "thickness",
            "opacity",
            "lineColor",
            "size",
        ],
        "attachment" => &["name", "type", "size", "icon"],
        "audio" => &["name", "size", "sourceType", "width"],
        "bookmark" => &["title", "description", "icon", "image"],
        "embed" | "juejin-embed" | "figma-embed" => &["wr", "ar", "width", "height"],
        _ => &[],
    }
}

fn valid_resource_url(kind: &str, value: &str) -> bool {
    let Some((scheme, rest)) = value.split_once("://") else {
        return false;
    };
    if value.len() > 8192
        || !matches!(scheme, "http" | "https")
        || value.chars().any(char::is_whitespace)
    {
        return false;
    }
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty() || host.contains('@') {
        return false;
    }
    match kind {
        "figma-embed" => matches!(host, "figma.com" | "www.figma.com" | "embed.figma.com"),
        "juejin-embed" => matches!(host, "juejin.cn" | "www.juejin.cn"),
        _ => true,
    }
}

fn resource_properties<T: ReadTxn>(kind: &str, props: &MapRef, txn: &T) -> String {
    let values: std::collections::BTreeMap<_, _> = resource_keys(kind)
        .iter()
        .filter_map(|key| {
            if let Some(Out::Any(value)) = props.get(txn, key) {
                Some((*key, value))
            } else {
                None
            }
        })
        .collect();
    serde_json::to_string(&values).unwrap()
}

fn parse_resource_edit(
    kind: &str,
    input: &str,
    initial: bool,
) -> Result<HashMap<String, Option<Any>>, String> {
    let fail = || "INVALID_RESOURCE: 资源属性无效".to_owned();
    if input.len()
        > (if matches!(kind, "formula" | "task") {
            160_128
        } else {
            32768
        })
    {
        return Err(fail());
    }
    let Any::Map(values) = Any::from_json(input).map_err(|_| fail())? else {
        return Err(fail());
    };
    if matches!(kind, "meeting" | "task" | "kr-list")
        && initial
        && !matches!(values.get(if kind == "task" { "taskId" } else { "meetingId" }), Some(Any::String(id)) if !id.trim().is_empty() && id.len() <= 512)
    {
        return Err(fail());
    }
    let mut result = HashMap::new();
    for (key, wrapper) in values.iter() {
        if !resource_keys(kind).contains(&key.as_str())
            && (initial
                || key != "url"
                || matches!(
                    kind,
                    "date-card"
                        | "divider"
                        | "formula"
                        | "meeting"
                        | "task"
                        | "kr-list"
                        | "mermaid"
                ))
        {
            return Err(fail());
        }
        let value = if initial {
            Some(wrapper.clone())
        } else {
            let Any::Map(v) = wrapper else {
                return Err(fail());
            };
            if v.keys().any(|key| key != "value") {
                return Err(fail());
            }
            v.get("value").cloned()
        };
        if matches!(
            (kind, key.as_str()),
            ("meeting", "meetingId") | ("kr-list", "meetingId") | ("task", "taskId")
        ) && value.is_none()
        {
            return Err(fail());
        }
        if let Some(v) = &value {
            if key == "url"
                && !out_string(Some(Out::Any(v.clone())))
                    .is_some_and(|url| valid_resource_url(kind, &url))
            {
                return Err(fail());
            }
            if kind == "task" {
                let valid = match (key.as_str(), v) {
                    ("taskId", Any::String(id)) => !id.trim().is_empty() && id.len() <= 512,
                    ("title", Any::String(title)) => title.encode_utf16().count() <= 20_000,
                    ("title", Any::Null) => true,
                    _ => false,
                };
                if !valid {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "kr-list" {
                if !matches!((key.as_str(), v), ("meetingId", Any::String(id)) if !id.trim().is_empty() && id.len() <= 512)
                {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "meeting" {
                let valid = match (key.as_str(), v) {
                    ("meetingId", Any::String(id)) => !id.trim().is_empty() && id.len() <= 512,
                    ("title", Any::String(title)) => title.encode_utf16().count() <= 2000,
                    ("number", Any::String(number)) => number.encode_utf16().count() <= 256,
                    ("title" | "number", Any::Null) => true,
                    _ => false,
                };
                if !valid {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "mermaid" {
                if !matches!(v, Any::Null)
                    && !matches!(v, Any::String(mode) if matches!(mode.as_ref(), "text" | "graph" | "default"))
                {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "formula" {
                if !matches!(v, Any::Null)
                    && !matches!(v, Any::String(latex) if latex.encode_utf16().count() <= 20_000)
                {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "date-card" {
                let valid = match (key.as_str(), v) {
                    (_, Any::Null) => true,
                    ("style", Any::String(v)) => matches!(
                        v.as_ref(),
                        "calendar"
                            | "square"
                            | "banner"
                            | "minibar"
                            | "ticket"
                            | "stamp"
                            | "flip"
                            | "masthead"
                            | "bookmark"
                            | "split"
                            | "pill"
                            | "rail"
                    ),
                    ("format", Any::String(v)) => matches!(v.as_ref(), "full" | "noWeek" | "min"),
                    ("bw", Any::String(v)) => matches!(
                        v.as_ref(),
                        "" | "0px solid"
                            | "1px solid"
                            | "2px solid"
                            | "3px solid"
                            | "1px dashed"
                            | "2px dashed"
                            | "1px dotted"
                            | "2px dotted"
                            | "3px double"
                    ),
                    ("width" | "height", Any::Number(v)) => {
                        v.is_finite() && *v > 0.0 && *v <= 100_000.0
                    }
                    ("date", Any::String(v)) => v.len() <= 128,
                    (_, Any::String(v)) => v.len() <= 256,
                    _ => false,
                };
                if !valid {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            if kind == "divider" {
                let valid = match (key.as_str(), v) {
                    (_, Any::Null) => true,
                    ("style", Any::String(v)) => is_divider_style(v),
                    ("length", Any::String(v)) => {
                        matches!(v.as_ref(), "short" | "medium" | "long" | "full")
                    }
                    ("thickness", Any::String(v)) => {
                        matches!(v.as_ref(), "thin" | "regular" | "thick")
                    }
                    ("size", Any::String(v)) => {
                        matches!(v.as_ref(), "thin" | "small" | "medium" | "large")
                    }
                    ("lineColor", Any::String(v)) => v.len() <= 256,
                    ("opacity", Any::Number(v)) => v.is_finite() && (0.1..=1.0).contains(v),
                    _ => false,
                };
                if !valid {
                    return Err(fail());
                }
                result.insert(key.clone(), value);
                continue;
            }
            let numeric = matches!(key.as_str(), "size" | "width" | "height" | "wr" | "ar");
            let valid = match v {
                Any::Null => true,
                Any::String(v) => {
                    !numeric
                        && v.len() <= 8192
                        && (key != "sourceType" || matches!(v.as_ref(), "link" | "local"))
                }
                Any::Number(v) => {
                    numeric && v.is_finite() && *v >= 0.0 && (key == "size" || *v > 0.0)
                }
                _ => false,
            };
            if !valid {
                return Err(fail());
            }
        }
        result.insert(key.clone(), value);
    }
    Ok(result)
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
/// 缺失/重复/内嵌内容仍使整篇只读；题注锁由完整锁图保护，不支持的子块交给外层预览。
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

/// 深度优先投影已适配块；未知块/容器输出一个只读占位，不展开或写入隐藏子树。
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
    let mut ordered = ordered_projection(&blocks, &txn, &children(&root, &txn));
    let mut stack: Vec<(String, usize, Option<String>)> = children(&root, &txn)
        .into_iter()
        .rev()
        .map(|id| (id, 0, None))
        .collect();
    let mut seen = HashSet::new();
    while let Some((id, depth, parent_id)) = stack.pop() {
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
        let node_type = out_string(block.get(&txn, "nodeType")).unwrap_or_default();
        let Some(kind) = mobile_type(&block, &props, &txn) else {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        };
        // Legacy nested breaks stay opaque; new writes must obey the desktop rootOnly schema.
        if kind == "page-divider" && parent_id.is_some() {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        if matches!(kind.as_str(), "meeting" | "task" | "kr-list")
            && parse_resource_edit(&kind, &resource_properties(&kind, &props, &txn), true).is_err()
        {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        if matches!(kind.as_str(), "table-row" | "table-cell")
            && !parent_id
                .as_ref()
                .and_then(|id| map(&blocks, &txn, id))
                .is_some_and(|parent| {
                    out_string(parent.get(&txn, "flavour")).as_deref()
                        == Some(if kind == "table-row" {
                            "table"
                        } else {
                            "table-row"
                        })
                })
        {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        if kind == "mermaid" && !supported_mermaid(&block, &blocks, &txn) {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        if kind == "mermaid-textarea"
            && !parent_id
                .as_ref()
                .and_then(|id| map(&blocks, &txn, id))
                .is_some_and(|parent| {
                    out_string(parent.get(&txn, "flavour")).as_deref() == Some("mermaid")
                })
        {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        if kind == "table" && !supported_table(&block, &blocks, &txn) {
            result.blocks.push(placeholder(id, parent_id));
            continue;
        }
        let mut text = String::new();
        let mut segments = Vec::new();
        let mut image = None;
        let is_media = matches!(kind.as_str(), "image" | "video");
        match block.get(&txn, "children") {
            Some(Out::YArray(_))
                if (matches!(kind.as_str(), "callout" | "mermaid")
                    || is_table_container(&kind))
                    && node_type == "block" =>
            {
                let ids = children(&block, &txn);
                ordered.extend(ordered_projection(&blocks, &txn, &ids));
                for child in ids.into_iter().rev() {
                    stack.push((child, depth + 1, Some(id.clone())));
                }
            }
            Some(Out::YArray(array))
                if matches!(
                    kind.as_str(),
                    "date-card"
                        | "divider"
                        | "page-divider"
                        | "formula"
                        | "meeting"
                        | "task"
                        | "kr-list"
                ) && node_type == "void"
                    && array.len(&txn) == 0 => {}
            Some(Out::YArray(array))
                if is_resource_block_type(&kind) && node_type == "void" && array.len(&txn) == 0 =>
            {
                text = out_string(props.get(&txn, "url")).unwrap_or_default();
                let supported_source = kind != "audio"
                    || match props.get(&txn, "sourceType") {
                        None => true,
                        Some(Out::Any(Any::String(value))) => {
                            matches!(value.as_ref(), "link" | "local")
                        }
                        _ => false,
                    };
                if !valid_resource_url(&kind, &text) || !supported_source {
                    result.blocks.push(placeholder(id, parent_id));
                    continue;
                }
            }
            Some(Out::YText(value))
                if node_type == "editable"
                    && !is_media
                    && !is_resource_block_type(&kind)
                    && kind != "callout"
                    && kind != "mermaid"
                    && kind != "page-divider"
                    && kind != "date-card"
                    && kind != "divider"
                    && kind != "formula"
                    && kind != "kr-list"
                    && kind != "meeting"
                    && kind != "task" =>
            {
                if value.diff(&txn, |_| ()).iter().any(|c| {
                    !matches!(&c.insert, Out::Any(Any::String(_)))
                        && (matches!(kind.as_str(), "code" | "mermaid-textarea")
                            || inline_embed(&c.insert, c.attributes.as_deref()).is_none())
                }) {
                    // 整段作为不透明块保留，避免普通文字投影丢失对象或其业务属性。
                    // 复用占位的删除/转换/父容器保护；其他正文仍可写入。
                    result.blocks.push(placeholder(id, parent_id));
                    continue;
                }
                text = projected_inline_text(&value, &txn);
                segments = text_segments_for_schema(&value, &txn, true);
            }
            Some(Out::YArray(array))
                if (kind == "image" && matches!(node_type.as_str(), "block" | "void"))
                    || (kind == "video" && node_type == "void" && array.len(&txn) == 0) =>
            {
                if kind == "video" {
                    let Some(url) = video_url(&props, &txn) else {
                        result.blocks.push(placeholder(id, parent_id));
                        continue;
                    };
                    text = url;
                } else {
                    text = out_string(props.get(&txn, "src")).unwrap_or_default();
                    if !matches!(
                        props.get(&txn, "src"),
                        None | Some(Out::Any(Any::Null | Any::String(_)))
                    ) {
                        result.reason = Some("媒体资源结构暂不支持，当前仅可预览".into());
                    }
                }
                if kind == "image" {
                    // An image with unadapted children is opaque as a whole;
                    // exposing those children as root blocks would flatten its native tree.
                    let has_unadapted_child = children(&block, &txn).iter().any(|child| {
                        map(&blocks, &txn, child).is_some_and(|caption| {
                            out_string(caption.get(&txn, "flavour")).as_deref() != Some("caption")
                                || !matches!(caption.get(&txn, "children"), Some(Out::YText(_)))
                        })
                    });
                    if has_unadapted_child {
                        result.blocks.push(placeholder(id, parent_id));
                        continue;
                    }
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
                            stack.push((child, depth + 1, parent_id.clone()));
                        }
                    }
                }
            }
            _ => {
                result.blocks.push(placeholder(id, parent_id));
                continue;
            }
        }
        result.blocks.push(CollabBlock {
            paragraph_style: paragraph_style::supports(&kind)
                .then(|| CollabResource {
                    properties: paragraph_style::project(&kind, &props, &txn),
                    property_edits: None,
                })
                .filter(|s| s.properties != "{}"),
            parent_id,
            callout_prefix: (kind == "callout")
                .then(|| out_string(props.get(&txn, "prefix")))
                .flatten(),
            block_text_color: (kind == "callout")
                .then(|| out_string(props.get(&txn, "color")))
                .flatten(),
            code: (kind == "code").then(|| CollabCode {
                language: out_string(props.get(&txn, "lang")).unwrap_or_else(|| "PlainText".into()),
                name: out_string(props.get(&txn, "blockName")).unwrap_or_default(),
                collapsed: out_bool(props.get(&txn, "collapse")) == Some(true),
                properties: code_properties(&props, &txn),
                property_edits: None,
            }),
            resource: (is_resource_block_type(&kind)
                || is_table_container(&kind)
                || matches!(
                    kind.as_str(),
                    "date-card"
                        | "divider"
                        | "formula"
                        | "meeting"
                        | "task"
                        | "kr-list"
                        | "mermaid"
                ))
            .then(|| CollabResource {
                properties: resource_properties(&kind, &props, &txn),
                property_edits: None,
            }),
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
        "callout" => ("callout", false),
        "mermaid" => ("mermaid", false),
        "mermaid-textarea" => ("mermaid-textarea", false),
        "table" => ("table", false),
        "table-row" => ("table-row", false),
        "table-cell" => ("table-cell", false),
        "image" => ("image", true),
        "video" => ("video", true),
        "date-card" => ("date-card", true),
        "divider" => ("divider", true),
        "page-divider" => ("page-divider", true),
        "formula" => ("formula", true),
        "meeting" => ("meeting", true),
        "kr-list" => ("kr-list", true),
        "task" => ("task", true),
        "attachment" => ("attachment", true),
        "audio" => ("audio", true),
        "bookmark" => ("bookmark", true),
        "embed" => ("embed", true),
        "juejin-embed" => ("juejin-embed", true),
        "figma-embed" => ("figma-embed", true),
        _ => return None,
    })
}

/// 在全部前置校验通过后才更新既有共享类型。外部负责取得向量、持久化增量和广播。
/// 未改动的块/属性/格式不重放；删除仅处理本次已投影的块，隐藏与孤立数据原样保留。
/// 表格结构在完整网格预检后更新，布局只消费显式字段补丁；删除的表格节点保留为可恢复孤立节点。
/// 新身份类型替换只清理源类型专有的编号/勾选键，其他扩展属性继续克隆；恢复有序历史时
/// 仅初始化经过白名单校验的原始编号设置和投影样式，派生 order 始终重新计算。
/// 新插入的有序块从编号投影初始化起点，代码块从语言投影初始化 lang；既有块不被普通快照覆盖。
pub(super) fn apply(doc: &Doc, root_id: &str, desired: &[CollabBlock]) -> Result<(), String> {
    validate(doc, root_id)?;
    let current = project(doc, root_id);
    if let Some(reason) = current.reason {
        return Err(format!("READ_ONLY_DOCUMENT: {reason}"));
    }
    super::block_locks::preflight(doc, root_id, &current.blocks, desired)?;
    // 占位必须原样保留；删除父容器、转换或伪造占位也在任何写入前拒绝。
    let previous: HashMap<_, _> = current.blocks.iter().map(|b| (b.id.as_str(), b)).collect();
    let desired_by_id: HashMap<_, _> = desired.iter().map(|b| (b.id.as_str(), b)).collect();
    for old in &current.blocks {
        if old.block_type == UNSUPPORTED_BLOCK_TYPE
            && desired_by_id.get(old.id.as_str()).copied() != Some(old)
        {
            return Err("READ_ONLY_BLOCK: 未适配的块不可编辑或删除".into());
        }
    }
    let mut desired_children: HashMap<&str, Vec<String>> = HashMap::new();
    for block in desired {
        if let Some(parent) = block.parent_id.as_deref() {
            desired_children
                .entry(parent)
                .or_default()
                .push(block.id.clone());
        }
    }
    validate_tables(desired)?;
    for block in desired {
        if block.block_type == UNSUPPORTED_BLOCK_TYPE
            && previous.get(block.id.as_str()).copied() == Some(block)
        {
            continue;
        }
        if block.block_type == "page-divider"
            && (block.parent_id.is_some() || !block.text.is_empty() || !block.segments.is_empty())
        {
            return Err("INVALID_PAGE_DIVIDER: 分页符必须是根级无正文块".into());
        }
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
    let ids: Vec<_> = current.blocks.iter().map(|b| b.id.clone()).collect();
    let mut desired_ids: HashSet<String> = desired.iter().map(|b| b.id.clone()).collect();
    let mut replaced_ids = HashSet::new();
    let mut replacements = HashMap::new();
    let mut numbering_edits = HashMap::new();
    let mut code_edits = HashMap::new();
    let mut resource_edits = HashMap::new();
    let mut paragraph_edits = HashMap::new();
    let mut restored = HashSet::new();
    // 新 UI 身份不能复用未展示的块或孤立块，避免覆盖隐藏内容。
    for block in desired {
        if !previous.contains_key(block.id.as_str()) && blocks.contains_key(&txn, &block.id) {
            let archived = map(&blocks, &txn, &block.id).filter(|native| {
                out_string(native.get(&txn, "flavour")).as_deref()
                    == formal_type(&block.block_type).map(|v| v.0)
                    && map(native, &txn, "meta").is_some_and(|meta| {
                        out_bool(meta.get(&txn, "csesMobileTableDeleted")) == Some(true)
                    })
            });
            if archived.is_none() || !in_table(block, &desired_by_id) {
                return Err("BLOCK_ID_CONFLICT: 新块 ID 已被原文档占用".into());
            }
            restored.insert(block.id.clone());
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
            if old.block_type == UNSUPPORTED_BLOCK_TYPE {
                return Err("READ_ONLY_BLOCK: 未适配的块不可转换".into());
            }
            let source_block = map(&blocks, &txn, source).unwrap();
            replacements.insert(block.id.clone(), source_block.as_prelim(&txn));
            Some(old)
        } else {
            previous.get(block.id.as_str()).copied()
        };
        if let Some(style) = block
            .paragraph_style
            .as_ref()
            .filter(|_| paragraph_style::supports(&block.block_type))
        {
            let initial = old.is_none() || block.replaces_id.is_some();
            let input = if initial {
                Some(style.properties.as_str())
            } else {
                style.property_edits.as_deref()
            };
            if let Some(input) = input {
                paragraph_edits.insert(block.id.clone(), paragraph_style::parse(input, initial)?);
            }
        }
        if matches!(block.block_type.as_str(), "meeting" | "task" | "kr-list")
            && block.resource.is_none()
        {
            return Err("INVALID_RESOURCE: 实体卡片引用缺少属性".into());
        }
        if is_table_container(&block.block_type) {
            let resource = block.resource.as_ref();
            let source = if old.is_none() {
                resource.map(|r| r.properties.as_str())
            } else {
                resource.and_then(|r| r.property_edits.as_deref())
            };
            if let Some(source) = source {
                resource_edits.insert(
                    block.id.clone(),
                    table_properties(&block.block_type, source, old.is_none())?,
                );
            }
        }
        if let Some(resource) = block
            .resource
            .as_ref()
            .filter(|_| !is_table_container(&block.block_type))
        {
            if !is_resource_block_type(&block.block_type)
                && !matches!(
                    block.block_type.as_str(),
                    "date-card"
                        | "divider"
                        | "formula"
                        | "meeting"
                        | "task"
                        | "kr-list"
                        | "mermaid"
                )
            {
                return Err("INVALID_RESOURCE: 资源属性与块类型不符".into());
            }
            let source = if old.is_none() {
                Some(resource.properties.as_str())
            } else {
                resource.property_edits.as_deref()
            };
            if let Some(source) = source {
                resource_edits.insert(
                    block.id.clone(),
                    parse_resource_edit(&block.block_type, source, old.is_none())?,
                );
            }
        }
        if is_resource_block_type(&block.block_type)
            && !valid_resource_url(&block.block_type, &block.text)
        {
            return Err("INVALID_RESOURCE: 请输入有效的资源地址".into());
        }
        if let Some(edit) = block.code.as_ref().and_then(|v| v.property_edits.as_ref()) {
            if block.block_type != "code"
                || old.is_some_and(|b| b.block_type != "code")
                || block.replaces_id.is_some()
            {
                return Err("INVALID_CODE_PROPERTIES: 属性操作只适用于代码块".into());
            }
            code_edits.insert(block.id.clone(), parse_code_edit(edit)?);
        }
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
        // 新块及新身份的有序替换从投影初始化设置；既有同类型普通快照仍然只读。
        // 在取得写事务前验证 JSON，避免任一选中项非法时发生部分根替换。
        if (old.is_none() || block.replaces_id.is_some()) && block.block_type == "numbered_list" {
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
            (matches!(b.block_type.as_str(), "callout" | "mermaid")
                || is_table_container(&b.block_type))
                && b.block_type != block.block_type
        }) {
            return Err("UNSUPPORTED_BLOCK_TYPE: 高亮容器不能直接转换为正文块".into());
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
                let original = restored.contains(&block.id)
                    || old
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
    for block in desired.iter().filter(|b| is_table_container(&b.block_type)) {
        let mut effective: HashMap<String, Any> = previous
            .get(block.id.as_str())
            .and_then(|old| old.resource.as_ref())
            .map(|r| serde_json::from_str(&r.properties))
            .transpose()
            .map_err(|_| "INVALID_TABLE: 布局属性无效")?
            .unwrap_or_default();
        if let Some(edits) = resource_edits.get(&block.id) {
            for (key, value) in edits {
                if let Some(value) = value {
                    effective.insert(key.clone(), value.clone());
                } else {
                    effective.remove(key);
                }
            }
        }
        let target: HashMap<String, Any> = serde_json::from_str(
            block
                .resource
                .as_ref()
                .map_or("{}", |r| r.properties.as_str()),
        )
        .map_err(|_| "INVALID_TABLE: 布局属性无效")?;
        if effective != target {
            return Err("INVALID_TABLE: 布局变化缺少明确字段补丁".into());
        }
    }
    drop(txn);
    let mut txn = doc.transact_mut();
    let next_ids: Vec<_> = desired.iter().map(|b| b.id.clone()).collect();
    let root_ids: Vec<_> = desired
        .iter()
        .filter(|b| b.parent_id.is_none())
        .map(|b| b.id.clone())
        .collect();
    let old_root_ids = children(&root, &txn);
    reconcile_order(&order, &mut txn, &old_root_ids, &root_ids);
    let keep: HashSet<_> = next_ids.iter().collect();
    for id in &ids {
        if !keep.contains(id) {
            if let Some(image) = previous
                .get(id.as_str())
                .filter(|b| !in_table(b, &previous))
                .and_then(|b| b.image.as_ref())
            {
                for caption in &image.captions {
                    blocks.remove(&mut txn, &caption.id);
                }
            }
            if previous
                .get(id.as_str())
                .is_some_and(|b| in_table(b, &previous))
            {
                if let Some(meta) = map(&blocks, &txn, id).and_then(|b| map(&b, &txn, "meta")) {
                    meta.insert(&mut txn, "csesMobileTableDeleted", true);
                }
            } else {
                blocks.remove(&mut txn, id);
            }
        }
    }
    for next in desired {
        let old = previous
            .get(next.replaces_id.as_deref().unwrap_or(&next.id))
            .copied();
        if old == Some(next)
            && !matches!(next.block_type.as_str(), "callout" | "mermaid")
            && !is_table_container(&next.block_type)
        {
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
        if restored.contains(&next.id) {
            if let Some(meta) = map(&block, &txn, "meta") {
                meta.remove(&mut txn, "csesMobileTableDeleted");
            }
            // 未投影期间到达的远端正文仍是权威内容，撤销删除不能以旧UI快照覆盖它。
            if !is_table_container(&next.block_type)
                && !matches!(next.block_type.as_str(), "callout" | "mermaid")
            {
                continue;
            }
        }
        if old.is_none() && !restored.contains(&next.id) {
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
            if flavour == "mermaid" {
                props.insert(&mut txn, "mode", "graph");
            }
            if flavour == "code" {
                // 新代码块可携带导入语言；既有代码语言仍仅通过显式属性补丁修改。
                let language = next
                    .code
                    .as_ref()
                    .map_or("PlainText", |code| code.language.as_str());
                props.insert(&mut txn, "lang", language);
            }
        }
        if let Some(values) = code_edits.get(&next.id) {
            for (key, value) in values {
                if let Some(value) = value {
                    props.try_update(&mut txn, key.as_str(), value.clone());
                } else {
                    props.remove(&mut txn, key);
                }
            }
        }
        if old.is_none_or(|b| b.block_type != next.block_type) {
            block.try_update(&mut txn, "flavour", flavour);
            block.try_update(
                &mut txn,
                "nodeType",
                if matches!(flavour, "image" | "callout" | "mermaid") || is_table_container(flavour)
                {
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
                "prefix",
                old.and_then(|b| b.callout_prefix.as_ref()),
                next.callout_prefix.as_ref(),
            ),
            (
                "color",
                old.and_then(|b| b.block_text_color.as_ref()),
                next.block_text_color.as_ref(),
            ),
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
                    props.try_update(
                        &mut txn,
                        key,
                        if key == "prefix" {
                            Any::String(color.clone().into())
                        } else {
                            css_color(Any::String(color.clone().into()))
                        },
                    );
                } else {
                    props.remove(&mut txn, key);
                }
            }
        }
        if old.is_none_or(|b| b.indent != next.indent) {
            props.try_update(&mut txn, "depth", next.indent as i64);
        }
        if let Some(values) = paragraph_edits.get(&next.id) {
            for (key, value) in values {
                if let Some(value) = value {
                    props.try_update(&mut txn, key.as_str(), value.clone());
                } else {
                    props.remove(&mut txn, key);
                }
            }
        }
        if flavour == "todo"
            && old.is_none_or(|b| b.checked != next.checked || b.block_type != next.block_type)
        {
            props.try_update(&mut txn, "checked", i64::from(next.checked));
        }
        if is_table_container(flavour) || flavour == "mermaid" {
            if let Some(edits) = resource_edits.get(&next.id) {
                for (key, value) in edits {
                    if let Some(value) = value {
                        props.try_update(&mut txn, key.as_str(), value.clone());
                    } else {
                        props.remove(&mut txn, key);
                    }
                }
            }
        }
        if matches!(flavour, "callout" | "mermaid") || is_table_container(flavour) {
            let array = match block.get(&txn, "children") {
                Some(Out::YArray(v)) => v,
                _ => block.insert(
                    &mut txn,
                    "children",
                    ArrayPrelim::from(Vec::<String>::new()),
                ),
            };
            let before = children(&block, &txn);
            let after = desired_children
                .get(next.id.as_str())
                .cloned()
                .unwrap_or_default();
            reconcile_order(&array, &mut txn, &before, &after);
        } else if media {
            if let Some(edits) = resource_edits.get(&next.id) {
                for (key, value) in edits {
                    if let Some(value) = value {
                        props.try_update(&mut txn, key.as_str(), value.clone());
                    } else {
                        props.remove(&mut txn, key);
                    }
                }
            }
            if old.is_none() && matches!(flavour, "embed" | "figma-embed" | "juejin-embed") {
                if !props.contains_key(&txn, "wr") {
                    props.try_update(&mut txn, "wr", 100);
                }
                if !props.contains_key(&txn, "ar") {
                    props.try_update(&mut txn, "ar", 16.0 / 9.0);
                }
            }
            if old.is_none() && flavour == "audio" && !props.contains_key(&txn, "sourceType") {
                props.try_update(&mut txn, "sourceType", "link");
            }
            if !matches!(block.get(&txn, "children"), Some(Out::YArray(_))) {
                block.insert(
                    &mut txn,
                    "children",
                    ArrayPrelim::from(Vec::<String>::new()),
                );
            }
            if !matches!(
                flavour,
                "date-card"
                    | "divider"
                    | "page-divider"
                    | "formula"
                    | "meeting"
                    | "task"
                    | "kr-list"
            ) && ((!is_resource_block_type(flavour)
                && old.is_none_or(|b| b.text != next.text || b.block_type != next.block_type))
                || (is_resource_block_type(flavour)
                    && old.is_none_or(|b| b.block_type != next.block_type)))
            {
                props.try_update(
                    &mut txn,
                    if flavour == "video" || is_resource_block_type(flavour) {
                        "url"
                    } else {
                        "src"
                    },
                    next.text.clone(),
                );
                if flavour == "video" && old.is_none_or(|b| b.block_type != "video") {
                    props.try_update(&mut txn, "sourceType", "link");
                }
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
            let before = projected_inline_text(&text, &txn);
            let contains_formula = next.segments.iter().any(|s| segment_embed(s).is_some())
                || text
                    .diff(&txn, |_| ())
                    .iter()
                    .any(|c| inline_embed(&c.insert, c.attributes.as_deref()).is_some());
            let delta = if before == next.text || !contains_formula {
                compute_text_delta(&before, &next.text)
            } else {
                compute_inline_text_delta(&text, &txn, next)
            };
            if delta.delete_length > 0 {
                text.remove_range(&mut txn, delta.index, delta.delete_length);
            }
            if !delta.insert_text.is_empty() {
                insert_inline_range(
                    &text,
                    &mut txn,
                    next,
                    delta.index,
                    delta.insert_text.encode_utf16().count() as u32,
                );
            }
            reconcile_inline_formulas(&text, &mut txn, next);
            apply_formats(&text, &mut txn, next);
        }
    }
    let inserted = desired
        .iter()
        .filter(|b| !previous.contains_key(b.id.as_str()))
        .map(|b| b.id.clone())
        .collect();
    update_ordered_counters(&blocks, &mut txn, &root_ids, &inserted);
    for container in desired
        .iter()
        .filter(|b| matches!(b.block_type.as_str(), "callout" | "table-cell"))
    {
        let ids = desired_children
            .get(container.id.as_str())
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        update_ordered_counters(&blocks, &mut txn, ids, &inserted);
    }
    Ok(())
}

/// 混合文字/公式/四类提及差量按对象内容比较前后缀，避免新增公式误匹配已有 U+FFFC。
/// 普通文字按 Unicode 标量比较，返回的 index/delete_length 始终是 UTF-16 单位。
fn compute_inline_text_delta<T: ReadTxn>(
    text: &TextRef,
    txn: &T,
    desired: &CollabBlock,
) -> TextDelta {
    let mut actual = Vec::new();
    for chunk in text.diff(txn, |_| ()) {
        if let Some(embed) = inline_embed(&chunk.insert, chunk.attributes.as_deref()) {
            actual.push((format!("embed:{embed:?}"), 1u32));
        } else if let Out::Any(Any::String(value)) = chunk.insert {
            actual.extend(
                value
                    .chars()
                    .map(|c| (format!("text:{c}"), c.len_utf16() as u32)),
            );
        }
    }
    let mut target = Vec::new();
    if desired.segments.is_empty() {
        target.extend(
            desired
                .text
                .chars()
                .map(|c| (format!("text:{c}"), c.len_utf16() as u32)),
        );
    } else {
        for segment in &desired.segments {
            if let Some(embed) = segment_embed(segment) {
                target.push((format!("embed:{embed:?}"), 1u32));
            } else {
                target.extend(
                    segment
                        .text
                        .chars()
                        .map(|c| (format!("text:{c}"), c.len_utf16() as u32)),
                );
            }
        }
    }
    let prefix = actual
        .iter()
        .zip(&target)
        .take_while(|(a, b)| a == b)
        .count();
    let suffix = actual[prefix..]
        .iter()
        .rev()
        .zip(target[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let index = actual[..prefix].iter().map(|a| a.1).sum();
    let delete_length = actual[prefix..actual.len() - suffix]
        .iter()
        .map(|a| a.1)
        .sum();
    let insert_length: u32 = target[prefix..target.len() - suffix]
        .iter()
        .map(|a| a.1)
        .sum();
    let units: Vec<_> = desired.text.encode_utf16().collect();
    TextDelta {
        index,
        delete_length,
        insert_text: String::from_utf16(&units[index as usize..(index + insert_length) as usize])
            .unwrap(),
    }
}

/// 插入 desired 投影的 UTF-16 子区间；公式和提及使用原生 insert_embed，不写占位文本。
fn insert_inline_range(
    text: &TextRef,
    txn: &mut yrs::TransactionMut<'_>,
    desired: &CollabBlock,
    start: u32,
    length: u32,
) {
    if desired.segments.is_empty() {
        let units: Vec<_> = desired.text.encode_utf16().collect();
        text.insert(
            txn,
            start,
            &String::from_utf16(&units[start as usize..(start + length) as usize]).unwrap(),
        );
        return;
    }
    let mut offset = 0;
    let mut cursor = start;
    for segment in &desired.segments {
        let units: Vec<_> = segment.text.encode_utf16().collect();
        let end = offset + units.len() as u32;
        let from = start.max(offset);
        let to = (start + length).min(end);
        if from < to {
            if let Some(embed) = segment_embed(segment) {
                let mut attrs = restored_mention_attributes(segment);
                let value = embed_value(&embed, &mut attrs);
                text.insert_embed_with_attributes(txn, cursor, value, attrs);
            } else {
                text.insert(
                    txn,
                    cursor,
                    &String::from_utf16(&units[(from - offset) as usize..(to - offset) as usize])
                        .unwrap(),
                );
            }
            cursor += to - from;
        }
        offset = end;
    }
}

/// 比较原生对象与目标单字符投影；公式及提及修改只替换该原子，保留未建模格式。
/// 普通 U+FFFC 字符无 inline_latex 时仍是普通文字，不被误判为公式。
fn reconcile_inline_formulas(
    text: &TextRef,
    txn: &mut yrs::TransactionMut<'_>,
    desired: &CollabBlock,
) {
    let mut actual = HashMap::new();
    let mut offset = 0;
    for chunk in text.diff(txn, |_| ()) {
        if let Some(embed) = inline_embed(&chunk.insert, chunk.attributes.as_deref()) {
            actual.insert(
                offset,
                (embed, chunk.attributes.map(|a| *a).unwrap_or_default()),
            );
            offset += 1;
        } else if let Out::Any(Any::String(value)) = chunk.insert {
            offset += value.encode_utf16().count() as u32;
        }
    }
    let mut wanted = HashMap::new();
    offset = 0;
    for segment in &desired.segments {
        if let Some(embed) = segment_embed(segment) {
            wanted.insert(offset, embed);
        }
        offset += segment.text.encode_utf16().count() as u32;
    }
    let positions: HashSet<_> = actual.keys().chain(wanted.keys()).copied().collect();
    for position in positions {
        let before = actual.get(&position);
        let after = wanted.get(&position);
        if before.map(|v| &v.0) == after {
            continue;
        }
        let mut attributes = before.map(|v| v.1.clone()).unwrap_or_else(|| {
            let mut offset = 0;
            for chunk in text.diff(txn, |_| ()) {
                let length = match &chunk.insert {
                    Out::Any(Any::String(value)) => value.encode_utf16().count() as u32,
                    _ => 1,
                };
                if position >= offset && position < offset + length {
                    return chunk.attributes.map(|a| *a).unwrap_or_default();
                }
                offset += length;
            }
            Attrs::new()
        });
        text.remove_range(txn, position, 1);
        if let Some(embed) = after {
            let value = embed_value(embed, &mut attributes);
            text.insert_embed_with_attributes(txn, position, value, attributes);
        } else {
            text.insert_with_attributes(txn, position, "\u{fffc}", attributes);
        }
    }
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
/// 不对整块无条件 clear/replay，链接按独立区间差量处理，保留其他未知格式。
fn apply_formats(text: &TextRef, txn: &mut yrs::TransactionMut<'_>, desired: &CollabBlock) {
    let actual: Vec<_> = text
        .diff(txn, |_| ())
        .into_iter()
        .filter_map(|c| match c.insert {
            Out::Any(Any::String(s)) => Some((
                s.encode_utf16().count() as u32,
                c.attributes.map(|a| *a).unwrap_or_default(),
            )),
            other if inline_embed(&other, c.attributes.as_deref()).is_some() => {
                Some((1, c.attributes.map(|a| *a).unwrap_or_default()))
            }
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
        "a:link",
        "a:bold",
        "a:italic",
        "a:underline",
        "a:strike",
        "a:code",
        "s:color",
        "s:background",
        "a:sup",
        "a:sub",
        "t:ff",
        "t:px",
        "t:fs",
        "t:ls",
        "s:fontFamily",
        "s:fontSize",
        "s:letterSpacing",
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

    /// 旧标题只投影为 H6，非法类型及字段补丁在原生事务开始前拒绝。
    #[test]
    fn heading_levels_are_bounded_without_rewriting_legacy_props() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let blocks = e.doc.get_or_insert_map(ROOT_NAME);
        for level in [7_i64, 8, 9] {
            {
                let mut txn = e.doc.transact_mut();
                let props = map(&blocks, &txn, "p1")
                    .and_then(|block| map(&block, &txn, "props"))
                    .unwrap();
                props.insert(&mut txn, "heading", level);
            }
            let expected = e.blocks();
            assert_eq!(
                expected.iter().find(|b| b.id == "p1").unwrap().block_type,
                "heading_6"
            );
            let vector = e.doc.transact().state_vector();
            e.apply_block_snapshot(expected.clone()).unwrap();
            assert_eq!(e.doc.transact().state_vector(), vector);
            let mut invalid = expected.clone();
            invalid
                .iter_mut()
                .find(|b| b.id == "p1")
                .unwrap()
                .block_type = format!("heading_{level}");
            assert!(e.apply_block_snapshot(invalid).is_err());
            let mut invalid = expected;
            invalid
                .iter_mut()
                .find(|b| b.id == "p1")
                .unwrap()
                .paragraph_style
                .as_mut()
                .unwrap()
                .property_edits = Some(format!(r#"{{"heading":{{"value":{level}}}}}"#));
            assert!(e.apply_block_snapshot(invalid).is_err());
            assert_eq!(e.doc.transact().state_vector(), vector);
            let txn = e.doc.transact();
            let props = map(&blocks, &txn, "p1")
                .and_then(|block| map(&block, &txn, "props"))
                .unwrap();
            assert_eq!(out_u32(props.get(&txn, "heading")), Some(level as u32));
        }
        for level in [0.0, 1.0, 6.0] {
            assert!(paragraph_style::parse(
                &format!(r#"{{"heading":{{"value":{level}}}}}"#),
                false
            )
            .is_ok());
        }
        for level in [-1.0, 1.5, 7.0, 8.0, 9.0] {
            assert!(paragraph_style::parse(
                &format!(r#"{{"heading":{{"value":{level}}}}}"#),
                false
            )
            .is_err());
        }
    }

    /// 旧超范围标题保留原编号分组；仅修复缺失的order，不迁移heading或未知数据。
    #[test]
    fn legacy_ordered_groups_survive_sync_repair_and_peer_edits() {
        for (fixture, missing) in [
            (
                include_bytes!("../../tests/fixtures/blockcraft-legacy-ordered-headings.update")
                    .as_slice(),
                false,
            ),
            (
                include_bytes!(
                    "../../tests/fixtures/blockcraft-legacy-ordered-missing-orders.update"
                )
                .as_slice(),
                true,
            ),
        ] {
            let mut local = engine(fixture);
            let mut peer = engine(fixture);
            let expected_orders = [0_u32, 0, 1];
            assert_eq!(
                local
                    .blocks()
                    .iter()
                    .map(|b| b.ordered.as_ref().unwrap().order)
                    .collect::<Vec<_>>(),
                expected_orders
            );
            let before = local.doc.transact().state_vector();
            let before_json = local
                .doc
                .get_or_insert_map(ROOT_NAME)
                .to_json(&local.doc.transact());
            let repaired = local.apply_block_snapshot(local.blocks()).unwrap();
            if missing {
                assert_ne!(local.doc.transact().state_vector(), before);
            } else {
                assert_eq!(local.doc.transact().state_vector(), before);
                assert_eq!(
                    local
                        .doc
                        .get_or_insert_map(ROOT_NAME)
                        .to_json(&local.doc.transact()),
                    before_json
                );
            }
            peer.apply_cses_update(repaired.v1_update).unwrap();
            let stable = local.doc.transact().state_vector();
            let stable_json = local
                .doc
                .get_or_insert_map(ROOT_NAME)
                .to_json(&local.doc.transact());
            local.apply_block_snapshot(local.blocks()).unwrap();
            assert_eq!(local.doc.transact().state_vector(), stable);
            assert_eq!(
                local
                    .doc
                    .get_or_insert_map(ROOT_NAME)
                    .to_json(&local.doc.transact()),
                stable_json
            );
            let mut edited = local.blocks();
            edited[0].text.push('!');
            edited[0].segments.clear();
            let update = local.apply_block_snapshot(edited).unwrap();
            peer.apply_cses_update(update.v1_update).unwrap();
            for value in [&local, &peer] {
                assert_eq!(value.blocks()[0].text, "Item 0!");
                assert_eq!(
                    value
                        .blocks()
                        .iter()
                        .map(|b| b.ordered.as_ref().unwrap().order)
                        .collect::<Vec<_>>(),
                    expected_orders
                );
                let txn = value.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                for (index, heading) in [7_u32, 8, 7].iter().enumerate() {
                    let id = format!("ordered-{index}");
                    let block = map(&blocks, &txn, &id).unwrap();
                    let props = map(&block, &txn, "props").unwrap();
                    assert_eq!(out_u32(props.get(&txn, "heading")), Some(*heading));
                    assert_eq!(
                        out_u32(props.get(&txn, "order")),
                        Some(expected_orders[index])
                    );
                    assert_eq!(out_string(props.get(&txn, "custom")), Some(id));
                    let meta = map(&block, &txn, "meta").unwrap();
                    assert_eq!(
                        out_string(meta.get(&txn, "author")).as_deref(),
                        Some("fixture-user")
                    );
                }
            }
        }
    }

    /// 段落字段补丁不会重放旧快照；远端其他字段和未知属性仍为权威值。
    #[test]
    fn paragraph_defaults_patch_preserves_remote_next_style_and_metadata() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let blocks = e.doc.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = e.doc.transact_mut();
            let props = map(&blocks, &txn, "p1")
                .and_then(|b| map(&b, &txn, "props"))
                .unwrap();
            props.insert(&mut txn, "nextParagraphStyle", "same");
            props.insert(&mut txn, "custom", "keep");
        }
        let mut stale = e.blocks();
        {
            let mut txn = e.doc.transact_mut();
            let props = map(&blocks, &txn, "p1")
                .and_then(|b| map(&b, &txn, "props"))
                .unwrap();
            props.insert(&mut txn, "nextParagraphStyle", "body");
        }
        let target = stale.iter_mut().find(|b| b.id == "p1").unwrap();
        target.paragraph_style.as_mut().unwrap().property_edits = Some(
            r##"{"textDefaults":{"value":{"a:bold":true,"s:color":"#123456","t:px":24}}}"##.into(),
        );
        e.apply_block_snapshot(stale).unwrap();
        let txn = e.doc.transact();
        let props = map(&blocks, &txn, "p1")
            .and_then(|b| map(&b, &txn, "props"))
            .unwrap();
        assert_eq!(
            out_string(props.get(&txn, "nextParagraphStyle")).as_deref(),
            Some("body")
        );
        assert_eq!(
            out_string(props.get(&txn, "custom")).as_deref(),
            Some("keep")
        );
        assert!(matches!(
            props.get(&txn, "textDefaults"),
            Some(Out::Any(Any::Map(_)))
        ));
    }

    /// 新段落默认格式和输入的字体区间经 V1 增量及 SQLite 重开保持一致。
    #[test]
    fn paragraph_defaults_typography_converge_and_reopen() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-basic.update");
        let mut e = engine(fixture);
        let mut peer = engine(fixture);
        let mut desired = e.blocks();
        let mut next = desired.iter().find(|b| b.id == "p1").unwrap().clone();
        next.id = "typed-defaults".into();
        next.text = "样式".into();
        next.paragraph_style = Some(CollabResource { properties: r#"{"textDefaults":{"a:bold":true,"t:px":24,"t:ff":"courier"},"nextParagraphStyle":"same"}"#.into(), property_edits: None });
        next.segments[0].text = next.text.clone();
        next.segments[0].typography = Some(r#"{"t:ff":"courier","t:px":24}"#.into());
        desired.push(next);
        let update = e.apply_block_snapshot(desired).unwrap();
        peer.apply_cses_update(update.v1_update).unwrap();
        assert_eq!(e.blocks(), peer.blocks());
        let mut reopened = CollabEngine::open(e.document_id.clone(), e.database_path.clone())
            .unwrap()
            .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), e.blocks());
        let block = reopened
            .blocks()
            .into_iter()
            .find(|b| b.id == "typed-defaults")
            .unwrap();
        assert_eq!(
            block.segments[0].typography.as_deref(),
            Some(r#"{"t:ff":"courier","t:px":24}"#)
        );
    }

    /// 空标题回正文显式清除原始缩进，不能被投影默认值掩盖。
    #[test]
    fn paragraph_body_reset_clears_native_depth_and_typography() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let blocks = e.doc.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = e.doc.transact_mut();
            let props = map(&blocks, &txn, "p2")
                .and_then(|b| map(&b, &txn, "props"))
                .unwrap();
            props.insert(&mut txn, "depth", 3);
            props.insert(&mut txn, "fs", 28);
        }
        let mut desired = e.blocks();
        let target = desired.iter_mut().find(|b| b.id == "p2").unwrap();
        target.block_type = "paragraph".into();
        target.paragraph_style.as_mut().unwrap().property_edits = Some(r#"{"depth":{"value":0},"fs":{"value":null},"textDefaults":{"value":null},"nextParagraphStyle":{"value":null}}"#.into());
        e.apply_block_snapshot(desired).unwrap();
        let txn = e.doc.transact();
        let props = map(&blocks, &txn, "p2")
            .and_then(|b| map(&b, &txn, "props"))
            .unwrap();
        assert_eq!(out_u32(props.get(&txn, "depth")), Some(0));
        assert_eq!(props.get(&txn, "fs"), Some(Out::Any(Any::Null)));
        assert_eq!(
            e.blocks().iter().find(|b| b.id == "p2").unwrap().block_type,
            "paragraph"
        );
    }

    /// 非外观字段不能进入段落默认格式；失败在写事务前整次拒绝。
    #[test]
    fn paragraph_invalid_defaults_are_atomic() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let before = e.doc.transact().state_vector();
        let mut desired = e.blocks();
        desired[0].paragraph_style = Some(CollabResource {properties:"{}".into(), property_edits:Some(r#"{"textDefaults":{"value":{"a:link":"https://invalid.test","mentionId":"business"}}}"#.into())});
        assert!(e
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("INVALID_PARAGRAPH_STYLE"));
        assert_eq!(e.doc.transact().state_vector(), before);
    }

    /// 表格/行/单元格保留共享身份与未知属性，正文修改可收敛并从 SQLite 恢复。
    #[test]
    fn table_body_sync_and_sqlite_preserve_native_tree() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-table.update");
        let mut phone = engine(fixture);
        let mut desktop = engine(fixture);
        let before = phone.blocks();
        assert_eq!(before.len(), 18);
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "body-0-0")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("cell-0-0")
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "table-1")
                .unwrap()
                .resource
                .as_ref()
                .unwrap()
                .properties,
            "{\"colWidths\":[120,160,200]}"
        );
        let mut desired = before.clone();
        let body = desired.iter_mut().find(|b| b.id == "body-0-0").unwrap();
        body.text.push_str("手机");
        body.segments[0].text.push_str("手机");
        let update = phone.apply_block_snapshot(desired).unwrap();
        let mut remote = desktop.blocks();
        let body = remote.iter_mut().find(|b| b.id == "body-1-2").unwrap();
        body.text.push_str("桌面");
        body.segments[0].text.push_str("桌面");
        let remote_update = desktop.apply_block_snapshot(remote).unwrap();
        desktop.apply_cses_update(update.v1_update).unwrap();
        phone.apply_cses_update(remote_update.v1_update).unwrap();
        assert_eq!(phone.blocks(), desktop.blocks());
        {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            for id in ["table-1", "row-0", "cell-0-0"] {
                let native = map(&blocks, &txn, id).unwrap();
                let source_txn = desktop.doc.transact();
                let source_blocks = source_txn.get_map(ROOT_NAME).unwrap();
                assert_eq!(
                    native.to_json(&txn),
                    map(&source_blocks, &source_txn, id)
                        .unwrap()
                        .to_json(&source_txn)
                );
                assert!(map(&native, &txn, "meta")
                    .unwrap()
                    .contains_key(&txn, "customAudit"));
            }
        }
        let expected = phone.blocks();
        let vector = phone.doc.transact().state_vector();
        phone.apply_block_snapshot(expected.clone()).unwrap();
        assert_eq!(phone.doc.transact().state_vector(), vector);
        let mut reopened =
            CollabEngine::open(phone.document_id.clone(), phone.database_path.clone())
                .unwrap()
                .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), expected);
    }

    /// 单元格内类型转换和插入有序列表后，桌面派生 order 与移动端投影一致。
    #[test]
    fn table_cell_ordered_lists_update_native_counters() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-table.update"
        ));
        let mut desired = phone.blocks();
        let index = desired.iter().position(|b| b.id == "body-0-0").unwrap();
        let mut first = desired[index].clone();
        first.replaces_id = Some(first.id.clone());
        first.id = "table-list-1".into();
        first.block_type = "numbered_list".into();
        desired[index] = first.clone();
        first.id = "table-list-2".into();
        first.replaces_id = None;
        desired.insert(index + 1, first);
        phone.apply_block_snapshot(desired).unwrap();
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        for (id, number) in [("table-list-1", 0), ("table-list-2", 1)] {
            let props = map(&map(&blocks, &txn, id).unwrap(), &txn, "props").unwrap();
            assert_eq!(out_u32(props.get(&txn, "order")), Some(number));
        }
    }

    /// 直接读取Yjs桌面合并样本，隐藏格及正文身份保留，普通正文仍可编辑并恢复。
    #[test]
    fn desktop_merged_table_fixture_projects_without_flattening() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-table-merged.update"
        ));
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        let mut blocks = phone.blocks();
        assert_eq!(
            blocks
                .iter()
                .filter(|b| b.block_type == "table-cell")
                .count(),
            4
        );
        assert_eq!(
            blocks
                .iter()
                .find(|b| b.id == "merged-d")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("merged-c00")
        );
        let hidden = blocks.iter().find(|b| b.id == "merged-c11").unwrap();
        assert!(hidden
            .resource
            .as_ref()
            .unwrap()
            .properties
            .contains("none"));
        blocks[0].text.push_str("可编辑");
        blocks[0].segments[0].text.push_str("可编辑");
        phone.apply_block_snapshot(blocks).unwrap();
        let expected = phone.blocks();
        let mut reopened =
            CollabEngine::open(phone.document_id.clone(), phone.database_path.clone())
                .unwrap()
                .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), expected);
    }

    /// 删除行的原始共享类型保留供撤销；恢复时不得覆盖删除期间到达的远端正文。
    #[test]
    fn table_row_removal_restores_unknown_meta_and_latest_archived_text() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-table.update"
        ));
        let original = phone.blocks();
        let original_meta = {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            map(&map(&blocks, &txn, "cell-0-0").unwrap(), &txn, "meta")
                .unwrap()
                .to_json(&txn)
        };
        let remaining = original
            .iter()
            .filter(|b| {
                b.id != "row-0" && !b.id.starts_with("cell-0-") && !b.id.starts_with("body-0-")
            })
            .cloned()
            .collect();
        phone.apply_block_snapshot(remaining).unwrap();
        {
            let blocks = phone.doc.get_or_insert_map(ROOT_NAME);
            let mut txn = phone.doc.transact_mut();
            let body = map(&blocks, &txn, "body-0-0").unwrap();
            let Some(Out::YText(text)) = body.get(&txn, "children") else {
                panic!("archived Y.Text")
            };
            text.insert(&mut txn, 0, "远端更新");
        }
        phone.apply_block_snapshot(original).unwrap();
        assert!(phone
            .blocks()
            .iter()
            .find(|b| b.id == "body-0-0")
            .unwrap()
            .text
            .starts_with("远端更新"));
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let cell = map(&blocks, &txn, "cell-0-0").unwrap();
        assert_eq!(
            map(&cell, &txn, "meta").unwrap().to_json(&txn),
            original_meta
        );
        assert_eq!(
            out_string(map(&cell, &txn, "props").unwrap().get(&txn, "customCell")).as_deref(),
            Some("preserve")
        );
    }

    /// 列宽显式补丁与另一端正文编辑并发收敛，未触碰属性和共享内容不回放。
    #[test]
    fn table_width_patch_converges_with_remote_body_and_invalid_grid_is_atomic() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-table.update");
        let mut phone = engine(fixture);
        let mut desktop = engine(fixture);
        let mut desired = phone.blocks();
        desired
            .iter_mut()
            .find(|b| b.id == "table-1")
            .unwrap()
            .resource = Some(CollabResource {
            properties: "{\"colWidths\":[120,240,200]}".into(),
            property_edits: Some("{\"colWidths\":{\"value\":[120,240,200]}}".into()),
        });
        let local = phone.apply_block_snapshot(desired).unwrap();
        let mut remote = desktop.blocks();
        let body = remote.iter_mut().find(|b| b.id == "body-1-2").unwrap();
        body.text.push_str("另一端");
        body.segments[0].text.push_str("另一端");
        let update = desktop.apply_block_snapshot(remote).unwrap();
        phone.apply_cses_update(update.v1_update).unwrap();
        desktop.apply_cses_update(local.v1_update).unwrap();
        assert_eq!(phone.blocks(), desktop.blocks());
        let before = phone.doc.transact().state_vector();
        let mut bad = phone.blocks();
        let cell = bad.iter_mut().find(|b| b.id == "cell-0-0").unwrap();
        cell.resource = Some(CollabResource {
            properties: "{\"colspan\":50,\"verticalAlign\":\"top\"}".into(),
            property_edits: Some("{\"colspan\":{\"value\":50}}".into()),
        });
        assert!(phone.apply_block_snapshot(bad).is_err());
        assert_eq!(phone.doc.transact().state_vector(), before);
    }

    /// 非法删除父块、跨行错置或伪造空行必须在事务前拒绝；不一致合并保留原始子树。
    #[test]
    fn invalid_table_structure_and_inconsistent_merges_are_atomic() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-table.update"
        ));
        let before = phone.blocks();
        for mode in 0..4 {
            let mut desired = before.clone();
            match mode {
                0 => desired.retain(|b| b.id != "table-1"),
                1 => {
                    desired
                        .iter_mut()
                        .find(|b| b.id == "cell-0-0")
                        .unwrap()
                        .parent_id = Some("row-1".into())
                }
                2 => {
                    desired
                        .iter_mut()
                        .find(|b| b.id == "table-1")
                        .unwrap()
                        .resource = None
                }
                _ => {
                    let mut row = desired.iter().find(|b| b.id == "row-0").unwrap().clone();
                    row.id = "new-row".into();
                    desired.push(row);
                }
            }
            let vector = phone.doc.transact().state_vector();
            assert!(phone.apply_block_snapshot(desired).is_err());
            assert_eq!(phone.doc.transact().state_vector(), vector);
            assert_eq!(phone.blocks(), before);
        }
        {
            let blocks = phone.doc.get_or_insert_map(ROOT_NAME);
            let mut txn = phone.doc.transact_mut();
            map(&map(&blocks, &txn, "cell-0-0").unwrap(), &txn, "props")
                .unwrap()
                .insert(&mut txn, "colspan", 2);
        }
        let projected = phone.blocks();
        assert_eq!(projected.last().unwrap().block_type, UNSUPPORTED_BLOCK_TYPE);
        assert_eq!(projected.len(), 4);
        let mut desired = projected;
        desired[1].text.push_str("仍可编辑");
        phone.apply_block_snapshot(desired).unwrap();
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        assert!(map(&blocks, &txn, "body-0-0").is_some());
    }

    #[test]
    fn callout_tree_and_appearance_roundtrip_without_flattening_or_losing_extensions() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-callout.update");
        let mut phone = engine(fixture);
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        let mut desired = phone.blocks();
        let container = desired.iter_mut().find(|b| b.id == "callout-1").unwrap();
        assert_eq!(container.block_type, "callout");
        assert_eq!(container.callout_prefix.as_deref(), Some("🤪"));
        assert_eq!(container.text, "");
        container.callout_prefix = Some("👨‍👩‍👧‍👦".into());
        container.block_background_color = Some("#DFEAFC".into());
        container.block_border_color = Some("#2563EB".into());
        container.block_text_color = Some("#15803D".into());
        let body = desired.iter_mut().find(|b| b.id == "callout-body").unwrap();
        assert_eq!(body.parent_id.as_deref(), Some("callout-1"));
        body.text.push_str("手机修改");
        body.segments[0].text.push_str("手机修改");
        phone.apply_block_snapshot(desired).unwrap();
        {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let root = map(&blocks, &txn, "fixture-doc").unwrap();
            assert_eq!(children(&root, &txn), vec!["p1", "p2", "todo", "callout-1"]);
            let callout = map(&blocks, &txn, "callout-1").unwrap();
            assert_eq!(
                children(&callout, &txn),
                vec!["callout-body", "callout-second"]
            );
            assert_eq!(
                out_string(callout.get(&txn, "nodeType")).as_deref(),
                Some("block")
            );
            let props = map(&callout, &txn, "props").unwrap();
            assert!(props.contains_key(&txn, "customCallout"));
            assert_eq!(out_string(props.get(&txn, "prefix")).as_deref(), Some("👨‍👩‍👧‍👦"));
            assert_eq!(
                out_string(props.get(&txn, "backColor")).as_deref(),
                Some("#DFEAFC")
            );
            assert_eq!(
                out_string(props.get(&txn, "borderColor")).as_deref(),
                Some("#2563EB")
            );
            assert_eq!(
                out_string(props.get(&txn, "color")).as_deref(),
                Some("#15803D")
            );
            let body = map(&blocks, &txn, "callout-body").unwrap();
            let Some(Out::YText(text)) = body.get(&txn, "children") else {
                panic!("body must stay Y.Text")
            };
            assert_eq!(
                text.diff(&txn, |_| ())[0]
                    .attributes
                    .as_ref()
                    .unwrap()
                    .get("a:link"),
                Some(&Any::String("https://example.test/callout".into()))
            );
            assert!(map(&body, &txn, "props")
                .unwrap()
                .contains_key(&txn, "customBody"));
        }
        let expected = phone.blocks();
        let vector = phone.doc.transact().state_vector();
        phone.apply_block_snapshot(expected.clone()).unwrap();
        assert_eq!(phone.doc.transact().state_vector(), vector);
        let path = phone.database_path.clone();
        drop(phone);
        let mut reopened = CollabEngine::open("fixture-doc".into(), path).unwrap().0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), expected);
    }

    #[test]
    fn callout_changes_merge_with_remote_body_and_other_appearance_fields() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-callout.update");
        let mut a = engine(fixture);
        let mut b = engine(fixture);
        let mut left = a.blocks();
        let mut right = b.blocks();
        left.iter_mut()
            .find(|v| v.id == "callout-1")
            .unwrap()
            .callout_prefix = Some("💡".into());
        right
            .iter_mut()
            .find(|v| v.id == "callout-1")
            .unwrap()
            .block_background_color = Some("#DFEAFC".into());
        right
            .iter_mut()
            .find(|v| v.id == "callout-second")
            .unwrap()
            .text
            .push_str("远端");
        let ua = a.apply_block_snapshot(left).unwrap().v1_update;
        let ub = b.apply_block_snapshot(right).unwrap().v1_update;
        a.apply_cses_update(ub).unwrap();
        b.apply_cses_update(ua).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        assert_eq!(
            a.blocks()
                .iter()
                .find(|v| v.id == "callout-1")
                .unwrap()
                .callout_prefix
                .as_deref(),
            Some("💡")
        );
        assert_eq!(
            a.blocks()
                .iter()
                .find(|v| v.id == "callout-second")
                .unwrap()
                .text,
            "第二段正文远端"
        );
    }

    #[test]
    fn callout_child_order_insertion_removal_and_invalid_parent_are_atomic() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-callout.update"
        ));
        let mut desired = engine.blocks();
        let mut new = desired.last().unwrap().clone();
        new.id = "new-child".into();
        new.text = "新增子段落".into();
        desired.push(new);
        desired.swap(4, 5);
        engine.apply_block_snapshot(desired.clone()).unwrap();
        {
            let txn = engine.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let callout = map(&blocks, &txn, "callout-1").unwrap();
            assert_eq!(
                children(&callout, &txn),
                vec!["callout-second", "callout-body", "new-child"]
            );
        }
        let before = engine.doc.transact().state_vector();
        desired.last_mut().unwrap().parent_id = Some("p1".into());
        assert!(engine.apply_block_snapshot(desired).is_err());
        assert_eq!(engine.doc.transact().state_vector(), before);
        let desired: Vec<_> = engine
            .blocks()
            .into_iter()
            .filter(|b| b.id != "callout-1" && b.parent_id.is_none())
            .collect();
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        for id in ["callout-1", "callout-body", "callout-second", "new-child"] {
            assert!(!blocks.contains_key(&txn, id));
        }
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

    #[test]
    fn both_justified_alignments_sync_and_survive_text_edit_and_reopen() {
        let mut phone = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        let mut peer = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-basic.update"
        ));
        for alignment in ["justify", "distributed"] {
            let mut desired = phone.blocks();
            desired[0].alignment = alignment.into();
            let result = phone.apply_block_snapshot(desired).unwrap();
            peer.apply_cses_update(result.v1_update).unwrap();
            assert_eq!(peer.blocks()[0].alignment, alignment);
            let mut edited = peer.blocks();
            edited[0].text.push_str("修改正文");
            edited[0].segments.clear();
            let result = peer.apply_block_snapshot(edited).unwrap();
            phone.apply_cses_update(result.v1_update).unwrap();
            assert_eq!(phone.blocks(), peer.blocks());
            assert_eq!(phone.blocks()[0].alignment, alignment);
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let block = map(&blocks, &txn, &phone.blocks()[0].id).unwrap();
            assert_eq!(
                out_string(map(&block, &txn, "props").unwrap().get(&txn, "textAlign")).as_deref(),
                Some(alignment)
            );
        }
        let path = phone.database_path.clone();
        drop(phone);
        let mut reopened = CollabEngine::open("fixture-doc".into(), path).unwrap().0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks()[0].alignment, "distributed");
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

    #[test]
    fn six_resource_kinds_roundtrip_without_overwriting_native_extensions() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-resources.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        let mut desired = phone.blocks();
        assert_eq!(
            desired[3..]
                .iter()
                .map(|b| b.block_type.as_str())
                .collect::<Vec<_>>(),
            [
                "attachment",
                "audio",
                "bookmark",
                "embed",
                "juejin-embed",
                "figma-embed"
            ]
        );
        assert!(desired[3..]
            .iter()
            .all(|b| b.resource.is_some() && b.segments.is_empty()));
        desired[1].text.push_str("正文修改");
        desired[3].text = "https://example.test/new.pdf".into();
        desired[3].resource.as_mut().unwrap().property_edits = Some(
            r#"{"name":{"value":"新方案.pdf"},"url":{"value":"https://example.test/new.pdf"}}"#
                .into(),
        );
        desired[6].resource.as_mut().unwrap().property_edits =
            Some(r#"{"wr":{"value":60},"ar":{"value":2}}"#.into());
        let update = phone.apply_block_snapshot(desired).unwrap().v1_update;
        peer.apply_cses_update(update).unwrap();
        assert_eq!(phone.blocks(), peer.blocks());
        let actual = phone.blocks();
        assert_eq!(actual[3].text, "https://example.test/new.pdf");
        assert!(actual[3]
            .resource
            .as_ref()
            .unwrap()
            .properties
            .contains("新方案.pdf"));
        {
            let txn = peer.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            for block in actual.iter().skip(3) {
                let native = map(&blocks, &txn, &block.id).unwrap();
                let props = map(&native, &txn, "props").unwrap();
                assert!(props.contains_key(&txn, "customResource"));
                assert!(map(&native, &txn, "meta")
                    .unwrap()
                    .contains_key(&txn, "customAudit"));
                assert_eq!(
                    out_string(native.get(&txn, "nodeType")).as_deref(),
                    Some("void")
                );
                assert!(matches!(native.get(&txn, "children"), Some(Out::YArray(_))));
            }
        }
        let vector = phone.doc.transact().state_vector();
        phone.apply_block_snapshot(actual.clone()).unwrap();
        assert_eq!(vector, phone.doc.transact().state_vector());
        let mut reopened =
            CollabEngine::open(phone.document_id.clone(), phone.database_path.clone())
                .unwrap()
                .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(actual, reopened.blocks());
        let mut invalid = actual.clone();
        invalid[1].text.push_str("不得部分写入");
        invalid[3].resource.as_mut().unwrap().property_edits =
            Some(r#"{"customResource":{"value":"覆盖"}}"#.into());
        assert!(phone
            .apply_block_snapshot(invalid)
            .unwrap_err()
            .contains("INVALID_RESOURCE"));
        assert_eq!(actual, phone.blocks());
        assert_eq!(vector, phone.doc.transact().state_vector());
        // New resources create the desktop URL and void shared child type.
        let mut created = actual;
        let mut new = created[3].clone();
        new.id = "new-attachment".into();
        new.text = "https://example.test/created.pdf".into();
        new.resource = Some(CollabResource {
            properties: r#"{"name":"新建附件"}"#.into(),
            property_edits: None,
        });
        created.push(new);
        let mut frame = created[6].clone();
        frame.id = "new-embed".into();
        let dimensions = frame.resource.as_ref().unwrap().properties.clone();
        created.push(frame);
        let mut audio = created[4].clone();
        audio.id = "new-audio".into();
        audio.resource = Some(CollabResource {
            properties: r#"{"name":"上传音频","sourceType":"local"}"#.into(),
            property_edits: None,
        });
        created.push(audio);
        phone.apply_block_snapshot(created).unwrap();
        let actual = phone.blocks();
        assert_eq!(
            actual
                .iter()
                .find(|b| b.id == "new-attachment")
                .unwrap()
                .block_type,
            "attachment"
        );
        assert_eq!(
            actual
                .iter()
                .find(|b| b.id == "new-embed")
                .unwrap()
                .resource
                .as_ref()
                .unwrap()
                .properties,
            dimensions
        );
        assert!(actual
            .last()
            .unwrap()
            .resource
            .as_ref()
            .unwrap()
            .properties
            .contains("local"));
    }

    #[test]
    fn resource_field_patches_merge_without_replaying_stale_metadata_or_urls() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-resources.update");
        let mut a = engine(fixture);
        let mut b = engine(fixture);
        let mut left = a.blocks();
        let mut right = b.blocks();
        left[5].resource.as_mut().unwrap().property_edits = Some(
            r#"{"title":{"value":"甲标题"},"url":{"value":"https://example.test/new-article"}}"#
                .into(),
        );
        left[5].text = "https://example.test/new-article".into();
        right[5].resource.as_mut().unwrap().property_edits =
            Some(r#"{"description":{"value":"乙摘要"}}"#.into());
        let au = a.apply_block_snapshot(left).unwrap().v1_update;
        b.apply_cses_update(au).unwrap();
        // This older UI snapshot deliberately retains the original URL and title.
        let bu = b.apply_block_snapshot(right).unwrap().v1_update;
        a.apply_cses_update(bu).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        let bookmark = a.blocks()[5].clone();
        assert_eq!(bookmark.text, "https://example.test/new-article");
        let props = bookmark.resource.unwrap().properties;
        assert!(props.contains("甲标题") && props.contains("乙摘要"));
    }

    #[test]
    fn unsupported_resource_sources_stay_opaque_while_other_blocks_edit() {
        for (id, url) in [
            ("audio-1", "blob:pending"),
            ("attachment-1", ""),
            ("figma-1", "https://example.test/fake"),
            ("juejin-1", "https://example.test/fake"),
        ] {
            let mut phone = engine(include_bytes!(
                "../../tests/fixtures/blockcraft-resources.update"
            ));
            let original = {
                let mut txn = phone.doc.transact_mut();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                let native = map(&blocks, &txn, id).unwrap();
                map(&native, &txn, "props")
                    .unwrap()
                    .try_update(&mut txn, "url", url);
                native.to_json(&txn)
            };
            let mut desired = phone.blocks();
            assert!(project(&phone.doc, "fixture-doc").reason.is_none());
            assert_eq!(
                desired.iter().find(|b| b.id == id).unwrap().block_type,
                UNSUPPORTED_BLOCK_TYPE
            );
            desired[1].text.push_str("可编辑");
            phone.apply_block_snapshot(desired).unwrap();
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            assert_eq!(original, map(&blocks, &txn, id).unwrap().to_json(&txn));
        }
    }

    #[test]
    fn desktop_video_url_roundtrips_and_unsupported_sources_remain_opaque() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-video.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        let mut desired = phone.blocks();
        assert_eq!(desired[3].block_type, "video");
        assert_eq!(desired[3].text, "https://example.test/video.mp4");
        assert_eq!(desired[4], placeholder("empty-video".into(), None));
        assert_eq!(desired[5], placeholder("embed-video".into(), None));
        let original = {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            ["empty-video", "embed-video"].map(|id| map(&blocks, &txn, id).unwrap().to_json(&txn))
        };
        desired[1].text.push_str("手机修改");
        desired[3].text = "https://example.test/replaced.mp4".into();
        let update = phone
            .apply_block_snapshot(desired.clone())
            .unwrap()
            .v1_update;
        peer.apply_cses_update(update).unwrap();
        assert_eq!(peer.blocks(), desired);
        {
            let txn = peer.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let video = map(&blocks, &txn, "video-1").unwrap();
            let props = map(&video, &txn, "props").unwrap();
            assert_eq!(
                out_string(props.get(&txn, "url")).as_deref(),
                Some("https://example.test/replaced.mp4")
            );
            assert!(!props.contains_key(&txn, "src"));
            assert!(props.contains_key(&txn, "customVideo"));
            assert_eq!(
                out_string(props.get(&txn, "poster")).as_deref(),
                Some("https://example.test/poster.jpg")
            );
            assert_eq!(
                original,
                ["empty-video", "embed-video"]
                    .map(|id| map(&blocks, &txn, id).unwrap().to_json(&txn))
            );
        }
        let mut restored =
            CollabEngine::open(phone.document_id.clone(), phone.database_path.clone())
                .unwrap()
                .0;
        restored.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(restored.blocks(), desired);
    }

    #[test]
    fn video_source_projection_prefers_url_and_preserves_legacy_src() {
        for (url, source_type, expected) in [
            (None, "link", "video"),
            (Some(""), "link", UNSUPPORTED_BLOCK_TYPE),
            (Some("blob:desktop-only"), "local", UNSUPPORTED_BLOCK_TYPE),
            (
                Some("https://example.test/embed"),
                "embed",
                UNSUPPORTED_BLOCK_TYPE,
            ),
            (
                Some("https://example.test/video.mp4"),
                "future-source",
                UNSUPPORTED_BLOCK_TYPE,
            ),
        ] {
            let mut phone = engine(include_bytes!(
                "../../tests/fixtures/blockcraft-video.update"
            ));
            {
                let mut txn = phone.doc.transact_mut();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                let video = map(&blocks, &txn, "video-1").unwrap();
                let props = map(&video, &txn, "props").unwrap();
                props.try_update(&mut txn, "src", "https://example.test/legacy.mp4");
                props.try_update(&mut txn, "sourceType", source_type);
                if let Some(url) = url {
                    props.try_update(&mut txn, "url", url);
                } else {
                    props.remove(&mut txn, "url");
                }
            }
            let mut desired = phone.blocks();
            assert_eq!(desired[3].block_type, expected);
            if expected == "video" {
                assert_eq!(desired[3].text, "https://example.test/legacy.mp4");
            }
            assert!(project(&phone.doc, "fixture-doc").reason.is_none());
            let before = {
                let txn = phone.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                map(&blocks, &txn, "video-1").unwrap().to_json(&txn)
            };
            desired[1].text.push_str("仍可编辑");
            phone.apply_block_snapshot(desired).unwrap();
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            assert_eq!(before, map(&blocks, &txn, "video-1").unwrap().to_json(&txn));
        }
    }

    /// 占位与原始未知子树分离；编辑其他块、同步和缓存恢复均不改写未知内容。
    #[test]
    fn unknown_container_is_preserved_while_other_blocks_remain_editable() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-unknown.update");
        let mut phone = engine(fixture);
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        let before = phone.blocks();
        assert_eq!(
            before.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            ["p1", "p2", "todo", "table"]
        );
        assert_eq!(before.last().unwrap(), &placeholder("table".into(), None));
        let original = {
            let txn = phone.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            ["table", "cell"].map(|id| map(&blocks, &txn, id).unwrap().to_json(&txn))
        };
        let mut desired = before;
        desired[1].text.push_str("手机修改");
        desired[1].segments.clear();
        desired[2].checked = false;
        let update = phone
            .apply_block_snapshot(desired.clone())
            .unwrap()
            .v1_update;
        assert_eq!(phone.blocks(), desired);
        let mut desktop = engine(fixture);
        desktop.apply_cses_update(update).unwrap();
        assert_eq!(desktop.blocks(), desired);
        {
            let txn = desktop.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            assert_eq!(
                original,
                ["table", "cell"].map(|id| map(&blocks, &txn, id).unwrap().to_json(&txn))
            );
        }
        let mut restored =
            CollabEngine::open(phone.document_id.clone(), phone.database_path.clone())
                .unwrap()
                .0;
        restored.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(restored.blocks(), desired);
        assert!(project(&restored.doc, "fixture-doc").reason.is_none());
        {
            let txn = restored.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            assert_eq!(
                original,
                ["table", "cell"].map(|id| map(&blocks, &txn, id).unwrap().to_json(&txn))
            );
        }

        // Deleting/converting/editing an opaque block or reusing its hidden IDs is rejected atomically.
        let mut attempts = Vec::new();
        let mut deleted = desired.clone();
        deleted.pop();
        attempts.push(deleted);
        let mut edited = desired.clone();
        edited.last_mut().unwrap().text = "覆盖".into();
        attempts.push(edited);
        let mut converted = desired.clone();
        converted.last_mut().unwrap().block_type = "paragraph".into();
        attempts.push(converted);
        let mut hidden = desired.clone();
        hidden[1].id = "cell".into();
        attempts.push(hidden);
        let mut forged = desired.clone();
        forged.push(placeholder("fake".into(), None));
        attempts.push(forged);
        for mut invalid in attempts {
            invalid[1].text.push_str("不应写入");
            let vector = phone.doc.transact().state_vector();
            assert!(phone.apply_block_snapshot(invalid).is_err());
            assert_eq!(vector, phone.doc.transact().state_vector());
            assert_eq!(phone.blocks(), desired);
        }
    }

    #[test]
    fn nested_unknown_blocks_and_incompatible_known_shapes_stay_opaque() {
        for (fixture, target) in [
            (
                include_bytes!("../../tests/fixtures/blockcraft-callout.update").as_slice(),
                "callout-body",
            ),
            (
                include_bytes!("../../tests/fixtures/blockcraft-image.update").as_slice(),
                "image-1",
            ),
            (
                include_bytes!("../../tests/fixtures/blockcraft-unknown.update").as_slice(),
                "table",
            ),
        ] {
            let mut engine = engine(fixture);
            {
                let mut txn = engine.doc.transact_mut();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                let id = if target == "image-1" {
                    "caption-1"
                } else {
                    target
                };
                let block = map(&blocks, &txn, id).unwrap();
                block.try_update(
                    &mut txn,
                    "flavour",
                    if target == "table" {
                        "paragraph"
                    } else {
                        "future-block"
                    },
                );
            }
            let projection = project(&engine.doc, "fixture-doc");
            assert!(projection.reason.is_none());
            let opaque = projection.blocks.iter().find(|b| b.id == target).unwrap();
            assert_eq!(opaque.block_type, UNSUPPORTED_BLOCK_TYPE);
            assert!(opaque.text.is_empty());
            assert!(!projection
                .blocks
                .iter()
                .any(|b| b.id == "caption-1" || b.id == "cell"));
            let mut desired = projection.blocks;
            desired[1].text.push_str("修改");
            desired[1].segments.clear();
            engine.apply_block_snapshot(desired.clone()).unwrap();
            assert_eq!(engine.blocks(), desired);
            if target == "callout-body" {
                assert_eq!(
                    engine
                        .blocks()
                        .iter()
                        .find(|b| b.id == target)
                        .unwrap()
                        .parent_id
                        .as_deref(),
                    Some("callout-1")
                );
                let mut deleted_parent = engine.blocks();
                deleted_parent
                    .retain(|b| b.id != "callout-1" && b.parent_id.as_deref() != Some("callout-1"));
                assert!(engine
                    .apply_block_snapshot(deleted_parent)
                    .unwrap_err()
                    .contains("READ_ONLY_BLOCK"));
            }
        }
    }

    /// 锁只保护有效子树；拒绝写入时Doc和SQLite均保持不变。
    #[test]
    fn locked_content_is_preserved_and_read_only() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-locked.update"
        ));
        assert!(project(&e.doc, "fixture-doc").reason.is_none());
        let states = crate::api::block_locks::scan(&e.doc, "fixture-doc");
        let mut desired = e.blocks();
        let index = desired
            .iter()
            .position(|b| {
                states
                    .iter()
                    .any(|s| s.block_id == b.id && s.source_id.is_some())
            })
            .unwrap();
        let before = e
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let count = load_updates(&e.connection, &e.document_id).unwrap().len();
        desired[index].text.push_str("禁止写入");
        desired[index].segments.clear();
        assert!(e
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_BLOCK"));
        assert_eq!(
            before,
            e.doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default())
        );
        assert_eq!(
            count,
            load_updates(&e.connection, &e.document_id).unwrap().len()
        );
    }

    /// 普通锁、模板锁和陈旧命令遵循桌面权限，并通过V1更新双向传播及SQLite恢复。
    #[test]
    fn block_lock_owner_permissions_sync_and_reopen() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-basic.update");
        let mut phone = engine(fixture);
        let mut desktop = engine(fixture);
        let id = phone.blocks()[0].id.clone();
        let update = phone
            .set_block_lock(id.clone(), true, "alice".into(), false, None, false)
            .unwrap()
            .v1_update;
        desktop.apply_cses_update(update).unwrap();
        assert_eq!(
            crate::api::block_locks::scan(&phone.doc, "fixture-doc"),
            crate::api::block_locks::scan(&desktop.doc, "fixture-doc")
        );
        let count = load_updates(&phone.connection, &phone.document_id)
            .unwrap()
            .len();
        for (user, grant, owner) in [
            ("bob", false, Some("alice")),
            ("alice", false, Some("old")),
            ("", true, Some("alice")),
        ] {
            assert!(phone
                .set_block_lock(
                    id.clone(),
                    false,
                    user.into(),
                    grant,
                    owner.map(str::to_owned),
                    false
                )
                .is_err());
        }
        assert_eq!(
            count,
            load_updates(&phone.connection, &phone.document_id)
                .unwrap()
                .len()
        );
        // Unlocked blocks remain editable while the first block is locked.
        let mut desired = phone.blocks();
        desired[1].text.push_str("可编辑");
        desired[1].segments.clear();
        let result = phone.apply_block_snapshot(desired).unwrap();
        desktop.apply_cses_update(result.v1_update).unwrap();
        let update = desktop
            .set_block_lock(
                id.clone(),
                false,
                "bob".into(),
                true,
                Some("alice".into()),
                false,
            )
            .unwrap()
            .v1_update;
        phone.apply_cses_update(update).unwrap();
        assert!(!crate::api::block_locks::scan(&phone.doc, "fixture-doc")
            .iter()
            .any(|s| s.source_id.is_some()));
        phone
            .set_block_lock(id.clone(), true, "alice".into(), false, None, false)
            .unwrap();
        let path = phone.database_path.clone();
        drop(phone);
        let mut reopened = CollabEngine::open("fixture-doc".into(), path).unwrap().0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert!(crate::api::block_locks::scan(&reopened.doc, "fixture-doc")
            .iter()
            .any(|s| s.block_id == id && s.owner_id.as_deref() == Some("alice")));
        reopened
            .set_block_lock(
                id,
                false,
                "alice".into(),
                false,
                Some("alice".into()),
                false,
            )
            .unwrap();
    }

    /// 容器锁继承、父级删除和混合快照全部在写入前拒绝；外侧插入不误判成移动锁块。
    #[test]
    fn inherited_locks_guard_structure_and_atomic_snapshots() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-callout.update"
        ));
        let parent = e
            .blocks()
            .iter()
            .find(|b| b.block_type == "callout")
            .unwrap()
            .id
            .clone();
        e.set_block_lock(parent.clone(), true, "alice".into(), false, None, false)
            .unwrap();
        let previous = e.blocks();
        let child = previous
            .iter()
            .find(|b| b.parent_id.as_deref() == Some(&parent))
            .unwrap()
            .id
            .clone();
        assert!(e
            .set_block_lock(child.clone(), false, "alice".into(), true, None, false)
            .is_err());
        let vector = e.doc.transact().state_vector();
        for case in 0..5 {
            let mut desired = previous.clone();
            match case {
                0 => {
                    let b = desired.iter_mut().find(|b| b.id == child).unwrap();
                    b.text.push('X');
                    b.segments.clear();
                }
                1 => desired.retain(|b| b.id != parent && b.parent_id.as_deref() != Some(&parent)),
                2 => {
                    let mut b = previous.iter().find(|b| b.id == child).unwrap().clone();
                    b.id = "new-child".into();
                    desired.push(b);
                }
                3 => {
                    desired
                        .iter_mut()
                        .find(|b| b.id == child)
                        .unwrap()
                        .parent_id = None
                }
                _ => {
                    desired
                        .iter_mut()
                        .find(|b| b.id == parent)
                        .unwrap()
                        .callout_prefix = Some("X".into());
                }
            }
            assert!(e.apply_block_snapshot(desired).is_err(), "case {case}");
            assert_eq!(vector, e.doc.transact().state_vector());
        }
        let mut desired = previous.clone();
        let mut outside = previous
            .iter()
            .find(|b| b.parent_id.is_none() && b.block_type == "paragraph")
            .unwrap()
            .clone();
        outside.id = "outside".into();
        desired.insert(0, outside);
        e.apply_block_snapshot(desired).unwrap();
        e.set_block_lock(
            parent,
            false,
            "alice".into(),
            false,
            Some("alice".into()),
            false,
        )
        .unwrap();
    }

    /// 表格隐藏结构与图片题注也参与完整锁图，不能经父级删除绕过保护。
    #[test]
    fn table_and_caption_locks_protect_hidden_and_visible_descendants() {
        let mut table = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-table.update"
        ));
        let original = table.blocks();
        let cell = original
            .iter()
            .find(|b| b.block_type == "table-cell")
            .unwrap()
            .id
            .clone();
        let inner = original
            .iter()
            .find(|b| b.parent_id.as_deref() == Some(&cell) && b.block_type == "paragraph")
            .unwrap()
            .id
            .clone();
        table
            .set_block_lock(cell.clone(), true, "alice".into(), false, None, false)
            .unwrap();
        assert!(crate::api::block_locks::scan(&table.doc, "fixture-doc")
            .iter()
            .any(|s| s.block_id == inner && s.source_id.as_deref() == Some(&cell)));
        let mut desired = table.blocks();
        let target = desired.iter_mut().find(|b| b.id == inner).unwrap();
        target.text.push('X');
        target.segments.clear();
        assert!(table
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_BLOCK"));
        let mut desired = table.blocks();
        if let Some(other) = desired.iter_mut().find(|b| {
            b.block_type == "paragraph" && b.id != inner && b.parent_id.as_deref() != Some(&cell)
        }) {
            other.text.push('Y');
            other.segments.clear();
            table.apply_block_snapshot(desired).unwrap();
        }
        let mut image = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-image.update"
        ));
        let original = image.blocks();
        let source = original
            .iter()
            .find(|b| b.image.as_ref().is_some_and(|v| !v.captions.is_empty()))
            .unwrap();
        let caption = source.image.as_ref().unwrap().captions[0].id.clone();
        let image_id = source.id.clone();
        image
            .set_block_lock(caption, true, "alice".into(), false, None, false)
            .unwrap();
        assert!(crate::api::block_locks::scan(&image.doc, "fixture-doc")
            .iter()
            .any(|s| s.block_id == image_id && s.source_id.is_none() && s.contains_lock));
        let mut desired = image.blocks();
        desired
            .iter_mut()
            .find(|b| b.id == image_id)
            .unwrap()
            .image
            .as_mut()
            .unwrap()
            .captions[0]
            .text
            .push('X');
        assert!(image
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_BLOCK"));
        let mut desired = image.blocks();
        desired.retain(|b| b.id != image_id);
        assert!(image
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_BLOCK"));
    }

    #[test]
    fn code_header_projects_without_overwriting_desktop_props() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-code.update"
        ));
        let before = engine.blocks();
        let code = before.last().unwrap();
        assert_eq!(code.code.as_ref().unwrap().language, "Dart");
        assert_eq!(code.code.as_ref().unwrap().name, "这是一段dart代码");
        let mut desired = before;
        let code = desired.last_mut().unwrap();
        code.text.push_str("// 手机修改\n");
        // Display-only projections must never overwrite newer native props.
        code.code = Some(CollabCode {
            language: "PlainText".into(),
            name: "stale".into(),
            collapsed: true,
            properties: "{}".into(),
            property_edits: None,
        });
        engine.apply_block_snapshot(desired).unwrap();
        let after = engine.blocks();
        let code = after.last().unwrap();
        assert!(code.text.ends_with("// 手机修改\n"));
        assert_eq!(code.code.as_ref().unwrap().language, "Dart");
        assert_eq!(code.code.as_ref().unwrap().name, "这是一段dart代码");
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let props = map(&map(&blocks, &txn, "code-1").unwrap(), &txn, "props").unwrap();
        assert_eq!(out_u32(props.get(&txn, "h")), Some(240));
        assert!(props.contains_key(&txn, "customCode"));
    }

    #[test]
    fn code_property_patches_merge_and_undo_only_the_selected_field() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-code.update");
        let mut a = engine(fixture);
        let mut b = engine(fixture);
        let mut left = a.blocks();
        let mut right = b.blocks();
        left.last_mut()
            .unwrap()
            .code
            .as_mut()
            .unwrap()
            .property_edits =
            Some(r#"{"blockName":{"value":"手机名称"},"collapse":{"value":true}}"#.into());
        right
            .last_mut()
            .unwrap()
            .code
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"lang":{"value":"Python"}}"#.into());
        let au = a.apply_block_snapshot(left).unwrap().v1_update;
        let bu = b.apply_block_snapshot(right).unwrap().v1_update;
        a.apply_cses_update(bu).unwrap();
        b.apply_cses_update(au).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        let result = a.blocks();
        let code = result.last().unwrap().code.as_ref().unwrap();
        assert_eq!(code.name, "手机名称");
        assert_eq!(code.language, "Python");
        assert!(code.collapsed);
        assert!(code.property_edits.is_none());
        let mut undo = a.blocks();
        undo.last_mut()
            .unwrap()
            .code
            .as_mut()
            .unwrap()
            .property_edits =
            Some(r#"{"blockName":{"value":"这是一段dart代码"},"collapse":{}}"#.into());
        let update = a.apply_block_snapshot(undo).unwrap().v1_update;
        b.apply_cses_update(update).unwrap();
        assert_eq!(a.blocks(), b.blocks());
        let result = b.blocks();
        let code = result.last().unwrap().code.as_ref().unwrap();
        assert_eq!(code.name, "这是一段dart代码");
        assert_eq!(code.language, "Python");
        assert!(!code.collapsed);
        assert!(!code.properties.contains("collapse"));
    }

    #[test]
    fn invalid_code_patch_is_atomic_and_native_null_is_distinct_from_missing() {
        let mut engine = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-code.update"
        ));
        for patch in [
            r#"{"lang":{"value":false}}"#,
            r#"{"h":{"value":10}}"#,
            r#"{"blockName":{"value":"partial"},"collapse":{"value":"true"}}"#,
        ] {
            let before = engine.doc.transact().state_vector();
            let mut desired = engine.blocks();
            desired
                .last_mut()
                .unwrap()
                .code
                .as_mut()
                .unwrap()
                .property_edits = Some(patch.into());
            assert!(engine
                .apply_block_snapshot(desired)
                .unwrap_err()
                .contains("INVALID_CODE_PROPERTIES"));
            assert_eq!(engine.doc.transact().state_vector(), before);
        }
        for (patch, present) in [
            (r#"{"collapse":{"value":null}}"#, true),
            (r#"{"collapse":{}}"#, false),
        ] {
            let mut desired = engine.blocks();
            desired
                .last_mut()
                .unwrap()
                .code
                .as_mut()
                .unwrap()
                .property_edits = Some(patch.into());
            engine.apply_block_snapshot(desired).unwrap();
            let txn = engine.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let props = map(&map(&blocks, &txn, "code-1").unwrap(), &txn, "props").unwrap();
            assert_eq!(props.contains_key(&txn, "collapse"), present);
            assert!(props.contains_key(&txn, "customCode"));
            assert_eq!(out_u32(props.get(&txn, "h")), Some(240));
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
                paragraph_style: None,
                id: "new-p".into(),
                block_type: "quote".into(),
                text: "新引用".into(),
                segments: Vec::new(),
                checked: false,
                alignment: "center".into(),
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
            paragraph_style: None,
            id: "media".into(),
            block_type: "image".into(),
            text: "https://example.test/image.png".into(),
            segments: Vec::new(),
            checked: false,
            alignment: "left".into(),
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
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
        desired[3].image.as_mut().unwrap().captions[0]
            .text
            .push('X');
        assert!(engine
            .apply_block_snapshot(desired)
            .unwrap_err()
            .contains("READ_ONLY_BLOCK"));
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
    /// 混合正文与公式占一个 UTF-16 位置；修改对象保留原生格式，删除不损坏周围 emoji。
    #[test]
    fn inline_formulas_project_edit_insert_delete_and_preserve_extensions() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-inline-formula.update");
        let mut engine = engine(fixture);
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
        let before = engine.blocks();
        let body = before.iter().find(|b| b.id == "p1").unwrap();
        assert_eq!(body.text, "前😀\u{fffc}后\u{fffc}\u{fffc}\u{fffc}");
        assert_eq!(
            body.segments
                .iter()
                .filter(|s| s.inline_latex.is_some())
                .count(),
            3
        );
        assert_eq!(body.segments.last().unwrap().inline_latex, None);
        let mut desired = before.clone();
        desired
            .iter_mut()
            .find(|b| b.id == "p1")
            .unwrap()
            .segments
            .iter_mut()
            .find(|s| s.inline_latex.is_some())
            .unwrap()
            .inline_latex = Some("a^2".into());
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let root = txn.get_map(ROOT_NAME).unwrap();
        let block = map(&root, &txn, "p1").unwrap();
        let Some(Out::YText(text)) = block.get(&txn, "children") else {
            panic!()
        };
        let chunks = text.diff(&txn, |_| ());
        let formula = chunks
            .iter()
            .find(|c| inline_latex_value(&c.insert).as_deref() == Some("a^2"))
            .unwrap();
        assert_eq!(
            formula.attributes.as_ref().unwrap().get("customInline"),
            Some(&Any::String("preserve-formula".into()))
        );
        assert_eq!(text.len(&txn), 8);
        assert!(chunks.iter().any(|c| c
            .attributes
            .as_ref()
            .is_some_and(|a| a.contains_key("a:link"))));
        drop(txn);
        // 插到既有公式前，新对象不得把已有对象当成普通 U+FFFC 替换。
        let mut desired = engine.blocks();
        let body = desired.iter_mut().find(|b| b.id == "p1").unwrap();
        let mut inserted = body
            .segments
            .iter()
            .find(|s| s.inline_latex.is_some())
            .unwrap()
            .clone();
        inserted.inline_latex = Some("inserted".into());
        inserted.bold = false;
        body.segments.insert(1, inserted);
        body.text = body.segments.iter().map(|s| s.text.as_str()).collect();
        engine.apply_block_snapshot(desired).unwrap();
        let after = engine.blocks();
        let body = after.iter().find(|b| b.id == "p1").unwrap();
        assert_eq!(
            body.segments
                .iter()
                .filter_map(|s| s.inline_latex.as_deref())
                .collect::<Vec<_>>(),
            ["inserted", "a^2", "x^2", "x^2"]
        );
        let mut deleted = after;
        let body = deleted.iter_mut().find(|b| b.id == "p1").unwrap();
        body.segments
            .retain(|s| s.inline_latex.as_deref() != Some("inserted"));
        body.text = body.segments.iter().map(|s| s.text.as_str()).collect();
        engine.apply_block_snapshot(deleted).unwrap();
        assert_eq!(
            engine.blocks().iter().find(|b| b.id == "p1").unwrap().text,
            before[0].text
        );
        let unchanged = engine.blocks();
        let mut invalid = unchanged.clone();
        invalid
            .iter_mut()
            .find(|b| b.id == "p1")
            .unwrap()
            .segments
            .iter_mut()
            .find(|s| s.inline_latex.is_some())
            .unwrap()
            .inline_latex = Some("😀".repeat(10001));
        assert!(engine
            .apply_block_snapshot(invalid)
            .unwrap_err()
            .contains("INVALID_INLINE_FORMULA"));
        assert_eq!(engine.blocks(), unchanged);
    }

    /// 行内公式修改与另一端正文追加交换增量后收敛，两个操作不互相覆盖。
    #[test]
    fn inline_formula_and_adjacent_text_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-inline-formula.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut a = left.blocks();
        a[0].segments
            .iter_mut()
            .find(|s| s.inline_latex.is_some())
            .unwrap()
            .inline_latex = Some("remote^2".into());
        let ua = left.apply_block_snapshot(a).unwrap();
        let mut b = right.blocks();
        b[0].segments.last_mut().unwrap().text.push_str("追加");
        b[0].text.push_str("追加");
        let ub = right.apply_block_snapshot(b).unwrap();
        left.apply_cses_update(ub.v1_update).unwrap();
        right.apply_cses_update(ua.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        assert!(left.blocks()[0].text.ends_with("追加"));
        assert_eq!(
            left.blocks()[0]
                .segments
                .iter()
                .find_map(|s| s.inline_latex.as_deref()),
            Some("remote^2")
        );
    }

    /// 正式/历史用户属性与公式混排，修改仅替换原子且保留扩展属性；无效快照不写入。
    #[test]
    fn user_mentions_roundtrip_preserve_identity_and_extensions() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-user-mention.update");
        let mut e = engine(fixture);
        assert!(project(&e.doc, "fixture-doc").reason.is_none());
        let before = e.blocks();
        assert_eq!(before[0].text, "前😀\u{fffc}\u{fffc}\u{fffc}\u{fffc}后");
        assert_eq!(
            before[0]
                .segments
                .iter()
                .filter_map(|s| s.mention_id.as_deref())
                .collect::<Vec<_>>(),
            ["u1", "u2"]
        );
        let mut desired = before.clone();
        desired[0]
            .segments
            .iter_mut()
            .find(|s| s.mention_id.as_deref() == Some("u1"))
            .unwrap()
            .inline_mention = Some("新姓名".into());
        e.apply_block_snapshot(desired).unwrap();
        {
            let txn = e.doc.transact();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let p = map(&blocks, &txn, "p1").unwrap();
            let Some(Out::YText(text)) = p.get(&txn, "children") else {
                panic!()
            };
            let chunks = text.diff(&txn, |_| ());
            let user = chunks
                .iter()
                .find(|c| {
                    inline_mention_identity(&c.insert, c.attributes.as_deref())
                        .is_some_and(|v| v.1 == "u1")
                })
                .unwrap();
            assert_eq!(
                user.attributes.as_ref().unwrap().get("customInline"),
                Some(&Any::String("user".into()))
            );
            let legacy = chunks
                .iter()
                .find(|c| {
                    inline_mention_identity(&c.insert, c.attributes.as_deref())
                        .is_some_and(|v| v.1 == "u2")
                })
                .unwrap();
            assert!(!legacy
                .attributes
                .as_ref()
                .unwrap()
                .contains_key("mentionId"));
            assert_eq!(text.len(&txn), 8);
        }
        let unchanged = e.blocks();
        let mut invalid = unchanged.clone();
        invalid[0]
            .segments
            .iter_mut()
            .find(|s| s.mention_id.is_some())
            .unwrap()
            .mention_id = None;
        assert!(e
            .apply_block_snapshot(invalid)
            .unwrap_err()
            .contains("INVALID_INLINE_MENTION"));
        assert_eq!(e.blocks(), unchanged);
        let mut desired = unchanged.clone();
        let user = desired[0]
            .segments
            .iter()
            .find(|s| s.mention_id.is_some())
            .unwrap()
            .clone();
        desired[0].segments.insert(1, user);
        desired[0].text = desired[0]
            .segments
            .iter()
            .map(|s| s.text.as_str())
            .collect();
        e.apply_block_snapshot(desired).unwrap();
        assert_eq!(
            e.blocks()[0]
                .segments
                .iter()
                .filter(|s| s.mention_id.is_some())
                .count(),
            3
        );
        let mut desired = e.blocks();
        desired[0].segments.remove(1);
        desired[0].text = desired[0]
            .segments
            .iter()
            .map(|s| s.text.as_str())
            .collect();
        e.apply_block_snapshot(desired).unwrap();
        assert_eq!(e.blocks(), unchanged);
    }

    /// 用户修改与另一端普通正文追加合并，不丢失用户ID、公式或未知属性。
    #[test]
    fn user_mention_and_text_edits_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-user-mention.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut a = left.blocks();
        a[0].segments
            .iter_mut()
            .find(|s| s.mention_id.is_some())
            .unwrap()
            .inline_mention = Some("新姓名".into());
        let ua = left.apply_block_snapshot(a).unwrap();
        let mut b = right.blocks();
        b[0].text.push_str("追加");
        b[0].segments.last_mut().unwrap().text.push_str("追加");
        let ub = right.apply_block_snapshot(b).unwrap();
        left.apply_cses_update(ub.v1_update).unwrap();
        right.apply_cses_update(ua.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        assert_eq!(
            left.blocks()[0]
                .segments
                .iter()
                .find_map(|s| s.inline_mention.as_deref()),
            Some("新姓名")
        );
        assert!(left.blocks()[0].text.ends_with("追加"));
    }

    /// 未知实体、缺身份与代码块对象只保护所在块；相邻编辑不改变原始对象。
    #[test]
    fn non_user_and_invalid_mentions_remain_protected() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-user-mention.update");
        for (kind, node_kind, id) in [
            ("future-doc", "paragraph", "u1"),
            ("future-meeting", "paragraph", "meeting-1"),
            ("future-task", "paragraph", "task-1"),
            ("user", "code", "u1"),
            ("user", "paragraph", ""),
        ] {
            let source = engine(fixture);
            {
                let mut txn = source.doc.transact_mut();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                let p = map(&blocks, &txn, "p1").unwrap();
                p.try_update(&mut txn, "flavour", node_kind);
                let Some(Out::YText(text)) = p.get(&txn, "children") else {
                    panic!()
                };
                text.insert_embed_with_attributes(
                    &mut txn,
                    0,
                    Any::Map(std::sync::Arc::new(HashMap::from([(
                        "mention".into(),
                        Any::String("姓名".into()),
                    )]))),
                    Attrs::from([
                        ("mentionType".into(), Any::String(kind.into())),
                        ("mentionId".into(), Any::String(id.into())),
                    ]),
                );
            }
            let state = source
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default());
            let mut e = engine(&state);
            let projection = project(&e.doc, "fixture-doc");
            assert!(projection.reason.is_none());
            assert_eq!(projection.blocks[0], placeholder("p1".into(), None));
            let original = {
                let txn = e.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                {
                    let block = map(&blocks, &txn, "p1").unwrap();
                    let Some(Out::YText(text)) = block.get(&txn, "children") else {
                        panic!()
                    };
                    (block.to_json(&txn), text.diff(&txn, |_| ()))
                }
            };
            let mut desired = projection.blocks;
            desired[2].text.push_str("手机修改");
            desired[2]
                .segments
                .last_mut()
                .unwrap()
                .text
                .push_str("手机修改");
            e.apply_block_snapshot(desired.clone()).unwrap();
            {
                let txn = e.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                assert_eq!(
                    {
                        let block = map(&blocks, &txn, "p1").unwrap();
                        let Some(Out::YText(text)) = block.get(&txn, "children") else {
                            panic!()
                        };
                        (block.to_json(&txn), text.diff(&txn, |_| ()))
                    },
                    original
                );
            }
            for operation in ["delete", "edit", "convert"] {
                let vector = e.doc.transact().state_vector();
                let mut invalid = desired.clone();
                match operation {
                    "delete" => {
                        invalid.remove(0);
                    }
                    "edit" => invalid[0].text = "覆盖".into(),
                    _ => invalid[0].block_type = "paragraph".into(),
                }
                assert!(e
                    .apply_block_snapshot(invalid)
                    .unwrap_err()
                    .contains("READ_ONLY_BLOCK"));
                assert_eq!(e.doc.transact().state_vector(), vector);
            }
            let mut restored = CollabEngine::open(e.document_id.clone(), e.database_path.clone())
                .unwrap()
                .0;
            restored.blockcraft_root_id = Some("fixture-doc".into());
            assert_eq!(restored.blocks(), desired);
        }
    }

    /// 四类对象混排仍各占一位；三类业务实体删除后重插入完整恢复属性，非法快照不写入。
    #[test]
    fn entity_mentions_restore_full_attributes_and_validate_atomically() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-entity-mention.update");
        for (block_index, kind) in [(0, "meeting"), (0, "task"), (0, "doc"), (1, "meeting")] {
            let mut e = engine(fixture);
            assert!(project(&e.doc, "fixture-doc").reason.is_none());
            let original = e.blocks();
            assert!(original
                .iter()
                .all(|b| b.block_type != UNSUPPORTED_BLOCK_TYPE));
            let index = original[block_index]
                .segments
                .iter()
                .position(|s| s.mention_type.as_deref() == Some(kind))
                .unwrap();
            let saved = original[block_index].segments[index].clone();
            let metadata: Attrs =
                serde_json::from_str(saved.mention_attributes.as_ref().unwrap()).unwrap();
            assert!(metadata.contains_key("customInline"));
            assert_eq!(
                original[1].segments[0].mention_type.as_deref(),
                Some("meeting")
            );
            assert_eq!(
                original.last().unwrap().parent_id.as_deref(),
                Some("entity-callout")
            );
            let mut removed = original.clone();
            removed[block_index].segments.remove(index);
            removed[block_index].text = removed[block_index]
                .segments
                .iter()
                .map(|s| s.text.as_str())
                .collect();
            e.apply_block_snapshot(removed).unwrap();
            e.apply_block_snapshot(original.clone()).unwrap();
            assert_eq!(e.blocks(), original);
            for invalid_data in [
                None,
                Some("[]".into()),
                Some(r#"{"mentionType":"user","mentionId":"wrong"}"#.into()),
                Some("x".repeat(65_537)),
            ] {
                let before = e.doc.transact().state_vector();
                let mut invalid = original.clone();
                invalid[block_index].segments[index].mention_attributes = invalid_data;
                assert!(e
                    .apply_block_snapshot(invalid)
                    .unwrap_err()
                    .contains("INVALID_INLINE_MENTION"));
                assert_eq!(e.doc.transact().state_vector(), before);
            }
            let mut restored = CollabEngine::open(e.document_id.clone(), e.database_path.clone())
                .unwrap()
                .0;
            restored.blockcraft_root_id = Some("fixture-doc".into());
            assert_eq!(restored.blocks(), original);
        }
    }

    /// 周围文字和名称的双端修改收敛；陈旧展示快照不能覆盖远端新状态。
    #[test]
    fn entity_mentions_converge_and_do_not_replay_stale_business_attributes() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-entity-mention.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        let mut left = phone.blocks();
        let mut right = peer.blocks();
        left[0].segments[0].text.push_str("手机");
        left[0].text = left[0].segments.iter().map(|s| s.text.as_str()).collect();
        right[0]
            .segments
            .iter_mut()
            .find(|s| s.mention_type.as_deref() == Some("meeting"))
            .unwrap()
            .inline_mention = Some("桌面更新的会议".into());
        let a = phone.apply_block_snapshot(left).unwrap().v1_update;
        let b = peer.apply_block_snapshot(right).unwrap().v1_update;
        phone.apply_cses_update(b).unwrap();
        peer.apply_cses_update(a).unwrap();
        assert_eq!(phone.blocks(), peer.blocks());
        let mut stale = phone.blocks();
        let vector = peer.doc.transact().state_vector();
        {
            let mut txn = peer.doc.transact_mut();
            let blocks = txn.get_map(ROOT_NAME).unwrap();
            let Some(Out::YText(text)) = map(&blocks, &txn, "p1").unwrap().get(&txn, "children")
            else {
                panic!()
            };
            let offset = 5;
            text.format(
                &mut txn,
                offset,
                1,
                Attrs::from([("status".into(), Any::String("远端新状态".into()))]),
            );
        }
        phone
            .apply_cses_update(peer.doc.transact().encode_state_as_update_v1(&vector))
            .unwrap();
        stale[2].text.push_str("继续编辑");
        phone.apply_block_snapshot(stale).unwrap();
        let current = phone.blocks();
        let attrs = &current[0]
            .segments
            .iter()
            .find(|s| s.mention_type.as_deref() == Some("meeting"))
            .unwrap()
            .mention_attributes;
        assert!(attrs.as_ref().unwrap().contains("远端新状态"));
    }

    /// 嵌套会议对象保留父子关系与完整属性；双端相邻编辑收敛，父容器不可连带删除。
    #[test]
    fn opaque_inline_blocks_preserve_nested_data_and_converge() {
        for fixture in [
            include_bytes!("../../tests/fixtures/blockcraft-embed.update").as_slice(),
            include_bytes!("../../tests/fixtures/blockcraft-opaque-mention.update").as_slice(),
        ] {
            let mut phone = engine(fixture);
            let mut peer = engine(fixture);
            let original = {
                let txn = phone.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                ["p1", "opaque-child"].map(|id| {
                    map(&blocks, &txn, id).map(|b| {
                        let Some(Out::YText(text)) = b.get(&txn, "children") else {
                            panic!()
                        };
                        (b.to_json(&txn), text.diff(&txn, |_| ()))
                    })
                })
            };
            let mut left = phone.blocks();
            let mut right = peer.blocks();
            assert!(project(&phone.doc, "fixture-doc").reason.is_none());
            assert_eq!(left[0].block_type, UNSUPPORTED_BLOCK_TYPE);
            left[1].text.push_str("手机");
            right[2].text.push_str("桌面");
            let a = phone.apply_block_snapshot(left).unwrap().v1_update;
            let b = peer.apply_block_snapshot(right).unwrap().v1_update;
            phone.apply_cses_update(b).unwrap();
            peer.apply_cses_update(a).unwrap();
            assert_eq!(phone.blocks(), peer.blocks());
            {
                let txn = phone.doc.transact();
                let blocks = txn.get_map(ROOT_NAME).unwrap();
                assert_eq!(
                    original,
                    ["p1", "opaque-child"].map(|id| map(&blocks, &txn, id).map(|b| {
                        let Some(Out::YText(text)) = b.get(&txn, "children") else {
                            panic!()
                        };
                        (b.to_json(&txn), text.diff(&txn, |_| ()))
                    }))
                );
            }
            if let Some(child) = phone.blocks().iter().find(|b| b.id == "opaque-child") {
                assert_eq!(child.parent_id.as_deref(), Some("opaque-callout"));
                let mut deleted_parent = phone.blocks();
                deleted_parent.retain(|b| {
                    b.id != "opaque-callout" && b.parent_id.as_deref() != Some("opaque-callout")
                });
                assert!(phone
                    .apply_block_snapshot(deleted_parent)
                    .unwrap_err()
                    .contains("READ_ONLY_BLOCK"));
            }
        }
    }

    /// 行内提及转换遵循桌面拆分结构；前后对象原始属性跨增量保留，撤销和重做收敛。
    #[test]
    fn mention_card_split_preserves_neighbor_atoms_and_converges() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-entity-mention.update");
        for kind in ["meeting", "task"] {
            let mut phone = engine(fixture);
            let mut peer = engine(fixture);
            let before = phone.blocks();
            let source = &before[0];
            let index = source
                .segments
                .iter()
                .position(|s| s.mention_type.as_deref() == Some(kind))
                .unwrap();
            let atom = &source.segments[index];
            let mut desired = before.clone();
            desired[0].segments.truncate(index);
            desired[0].text = desired[0]
                .segments
                .iter()
                .map(|s| s.text.as_str())
                .collect();
            let mut card = source.clone();
            card.id = format!("converted-{kind}");
            card.block_type = kind.into();
            card.text.clear();
            card.segments.clear();
            let id_key = if kind == "meeting" {
                "meetingId"
            } else {
                "taskId"
            };
            let mut props = serde_json::Map::new();
            props.insert(id_key.into(), atom.mention_id.clone().unwrap().into());
            props.insert("title".into(), atom.inline_mention.clone().unwrap().into());
            card.resource = Some(CollabResource {
                properties: serde_json::Value::Object(props).to_string(),
                property_edits: None,
            });
            let mut tail = source.clone();
            tail.id = "split-tail".into();
            tail.segments = source.segments[index + 1..].to_vec();
            tail.text = tail.segments.iter().map(|s| s.text.as_str()).collect();
            desired.insert(1, card);
            desired.insert(2, tail);
            let a = phone
                .apply_block_snapshot(desired.clone())
                .unwrap()
                .v1_update;
            peer.apply_cses_update(a).unwrap();
            assert_eq!(phone.blocks(), peer.blocks());
            assert_eq!(phone.blocks()[2].segments, source.segments[index + 1..]);
            let undo = phone
                .apply_block_snapshot(before.clone())
                .unwrap()
                .v1_update;
            peer.apply_cses_update(undo).unwrap();
            assert_eq!(phone.blocks(), before);
            assert_eq!(phone.blocks(), peer.blocks());
            let redo = phone.apply_block_snapshot(desired).unwrap().v1_update;
            peer.apply_cses_update(redo).unwrap();
            assert_eq!(phone.blocks(), peer.blocks());
            assert_eq!(phone.blocks()[1].block_type, kind);
        }
    }

    /// 任务正式void结构和原生属性保留；并发标题更新与新增卡片增量收敛，非法写入原子拒绝。
    #[test]
    fn task_cards_preserve_properties_validate_and_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-task-card.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        let before = phone.blocks();
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        assert_eq!(before.iter().filter(|b| b.block_type == "task").count(), 1);
        assert!(before
            .iter()
            .filter(|b| b.id == "task-invalid" || b.id == "task-bad-children")
            .all(|b| b.block_type == UNSUPPORTED_BLOCK_TYPE));
        let original = before.iter().find(|b| b.id == "task-card").unwrap().clone();
        let mut desired = before.clone();
        let mut card = original.clone();
        card.id = "new-task-card".into();
        card.resource.as_mut().unwrap().properties =
            r#"{"taskId":"new-id","title":"新引用"}"#.into();
        desired.push(card);
        let a = phone.apply_block_snapshot(desired).unwrap().v1_update;
        let mut remote = before.clone();
        remote
            .iter_mut()
            .find(|b| b.id == "task-card")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"title":{"value":"桌面标题"}}"#.into());
        let b = peer.apply_block_snapshot(remote).unwrap().v1_update;
        phone.apply_cses_update(b).unwrap();
        peer.apply_cses_update(a).unwrap();
        assert_eq!(phone.blocks(), peer.blocks());
        let mut stale = phone.blocks();
        *stale.iter_mut().find(|b| b.id == "task-card").unwrap() = original;
        phone.apply_block_snapshot(stale).unwrap();
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let card = map(&blocks, &txn, "task-card").unwrap();
        let props = map(&card, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "title")).as_deref(),
            Some("桌面标题")
        );
        assert!(props.contains_key(&txn, "customTask") && props.contains_key(&txn, "priority"));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        let new_card = map(&blocks, &txn, "new-task-card").unwrap();
        assert!(matches!(
            new_card.get(&txn, "children"),
            Some(Out::YArray(_))
        ));
        assert_eq!(
            out_string(new_card.get(&txn, "nodeType")).as_deref(),
            Some("void")
        );
        drop(txn);
        for patch in [
            r#"{"taskId":{"value":""}}"#,
            r#"{"taskId":{}}"#,
            r#"{"url":{"value":"https://example.test"}}"#,
            r#"{"title":{"value":5}}"#,
        ] {
            let before = phone.blocks();
            let mut invalid = before.clone();
            invalid
                .iter_mut()
                .find(|b| b.id == "task-card")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(patch.into());
            assert!(phone.apply_block_snapshot(invalid).is_err());
            assert_eq!(phone.blocks(), before);
        }
        let txn = phone.doc.transact();
        let update = txn.encode_state_as_update_v1(&StateVector::default());
        drop(txn);
        let restored = engine(&update);
        assert_eq!(phone.blocks(), restored.blocks());
    }

    /// KR只投影会议引用；插入、删除恢复与并发收敛，业务快照/布局事实不被重放。
    #[test]
    fn kr_list_reference_roundtrip_and_validation() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-meeting.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        let before = phone.blocks();
        let mut kr = before.iter().find(|b| b.id == "meeting-1").unwrap().clone();
        kr.id = "kr-list-1".into();
        kr.block_type = "kr-list".into();
        kr.resource = Some(CollabResource {
            properties: r#"{"meetingId":"m1"}"#.into(),
            property_edits: None,
        });
        let mut desired = before.clone();
        desired.push(kr.clone());
        let update = phone.apply_block_snapshot(desired).unwrap().v1_update;
        peer.apply_cses_update(update).unwrap();
        assert_eq!(phone.blocks(), peer.blocks());
        let projected = phone.blocks();
        assert_eq!(
            projected
                .iter()
                .find(|b| b.id == kr.id)
                .unwrap()
                .resource
                .as_ref()
                .unwrap()
                .properties,
            r#"{"meetingId":"m1"}"#
        );
        {
            let blocks = phone.doc.get_or_insert_map(ROOT_NAME);
            let mut txn = phone.doc.transact_mut();
            let props = map(&blocks, &txn, &kr.id)
                .and_then(|b| map(&b, &txn, "props"))
                .unwrap();
            props.insert(&mut txn, "estimatedHeight", 999);
            props.insert(&mut txn, "future", "keep");
        }
        let current = phone.blocks();
        phone.apply_block_snapshot(current.clone()).unwrap();
        {
            let blocks = phone.doc.get_or_insert_map(ROOT_NAME);
            let txn = phone.doc.transact();
            let props = map(&blocks, &txn, &kr.id)
                .and_then(|b| map(&b, &txn, "props"))
                .unwrap();
            assert_eq!(
                out_string(props.get(&txn, "future")).as_deref(),
                Some("keep")
            );
            assert_eq!(out_u32(props.get(&txn, "estimatedHeight")), Some(999));
        }
        phone.apply_block_snapshot(before).unwrap();
        assert!(!phone.blocks().iter().any(|b| b.id == kr.id));
        phone.apply_block_snapshot(current).unwrap();
        assert!(phone.blocks().iter().any(|b| b.id == kr.id));
        for invalid in [
            r#"{}"#,
            r#"{"meetingId":""}"#,
            r#"{"meetingId":12}"#,
            r#"{"meetingId":"m1","items":[]}"#,
        ] {
            assert!(parse_resource_edit("kr-list", invalid, true).is_err());
        }
        assert!(parse_resource_edit("kr-list", r#"{"meetingId":{}}"#, false).is_err());
        let txn = phone.doc.transact();
        let update = txn.encode_state_as_update_v1(&StateVector::default());
        drop(txn);
        assert_eq!(phone.blocks(), engine(&update).blocks());
    }

    /// 会议引用的正式结构、精确补丁、并发与未知数据保护。
    #[test]
    fn meeting_references_preserve_schema_and_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-meeting.update");
        let mut phone = engine(fixture);
        let mut peer = engine(fixture);
        let before = phone.blocks();
        assert!(project(&phone.doc, "fixture-doc").reason.is_none());
        assert_eq!(
            before.iter().filter(|b| b.block_type == "meeting").count(),
            2
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "meeting-empty")
                .unwrap()
                .block_type,
            UNSUPPORTED_BLOCK_TYPE
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "meeting-bad")
                .unwrap()
                .block_type,
            UNSUPPORTED_BLOCK_TYPE
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "nested-meeting")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("meeting-callout")
        );
        let mut local = before.clone();
        local
            .iter_mut()
            .find(|b| b.id == "meeting-1")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"title":{"value":"手机标题"}}"#.into());
        let a = phone.apply_block_snapshot(local).unwrap().v1_update;
        let mut remote = before.clone();
        remote
            .iter_mut()
            .find(|b| b.id == "meeting-1")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"number":{"value":"654321"}}"#.into());
        let b = peer.apply_block_snapshot(remote).unwrap().v1_update;
        phone.apply_cses_update(b).unwrap();
        peer.apply_cses_update(a).unwrap();
        assert_eq!(phone.blocks(), peer.blocks());
        phone.apply_block_snapshot(before.clone()).unwrap(); // stale snapshots must not replay props
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let meeting = map(&blocks, &txn, "meeting-1").unwrap();
        let props = map(&meeting, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "title")).as_deref(),
            Some("手机标题")
        );
        assert_eq!(
            out_string(props.get(&txn, "number")).as_deref(),
            Some("654321")
        );
        assert!(props.contains_key(&txn, "customMeeting"));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        assert!(matches!(
            meeting.get(&txn, "children"),
            Some(Out::YArray(_))
        ));
        let malformed = map(&blocks, &txn, "meeting-bad").unwrap().to_json(&txn);
        drop(txn);
        for patch in [
            r#"{"meetingId":{"value":""}}"#.to_owned(),
            r#"{"meetingId":{}}"#.into(),
            r#"{"url":{"value":"https://example.test"}}"#.into(),
            serde_json::json!({"title":{"value":"😀".repeat(1001)}}).to_string(),
        ] {
            let unchanged = phone.blocks();
            let mut invalid = unchanged.clone();
            invalid
                .iter_mut()
                .find(|b| b.id == "meeting-1")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(patch);
            assert!(phone.apply_block_snapshot(invalid).is_err());
            assert_eq!(phone.blocks(), unchanged);
        }
        let mut created = before.iter().find(|b| b.id == "meeting-1").unwrap().clone();
        created.id = "new-meeting".into();
        created.resource.as_mut().unwrap().properties =
            r#"{"meetingId":"new","title":"新引用"}"#.into();
        let mut desired = phone.blocks();
        desired.push(created);
        phone.apply_block_snapshot(desired).unwrap();
        let mut desired = phone.blocks();
        desired.retain(|b| b.id != "new-meeting");
        phone.apply_block_snapshot(desired).unwrap();
        let txn = phone.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        assert_eq!(
            malformed,
            map(&blocks, &txn, "meeting-bad").unwrap().to_json(&txn)
        );
    }

    /// 公式保留 void 结构、扩展属性和 TeX 原文；非法补丁在任何写入前拒绝。
    #[test]
    fn formula_projection_patches_and_validation_are_atomic() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-formula.update");
        let mut engine = engine(fixture);
        let before = engine.blocks();
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
        assert_eq!(
            before.iter().filter(|b| b.block_type == "formula").count(),
            5
        );
        assert!(before
            .iter()
            .filter(|b| b.block_type == "formula")
            .all(|b| b.text.is_empty() && b.segments.is_empty() && b.resource.is_some()));
        assert_eq!(
            before.last().unwrap().parent_id.as_deref(),
            Some("formula-callout")
        );
        let mut desired = before.clone();
        desired
            .iter_mut()
            .find(|b| b.id == "formula-1")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"latex":{"value":"E=mc^2"}}"#.into());
        engine.apply_block_snapshot(desired).unwrap();
        // 陈旧完整属性只是投影，无显式补丁不重放。
        engine.apply_block_snapshot(before).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let formula = map(&blocks, &txn, "formula-1").unwrap();
        let props = map(&formula, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "latex")).as_deref(),
            Some("E=mc^2")
        );
        assert!(props.contains_key(&txn, "customFormula"));
        assert!(!props.contains_key(&txn, "url"));
        assert!(!props.contains_key(&txn, "src"));
        assert!(matches!(
            formula.get(&txn, "children"),
            Some(Out::YArray(_))
        ));
        drop(txn);
        for patch in [
            r#"{"latex":{"value":123}}"#.to_owned(),
            r#"{"url":{"value":"https://example.test"}}"#.to_owned(),
            serde_json::json!({"latex": {"value": "😀".repeat(10001)}}).to_string(),
        ] {
            let unchanged = engine.blocks();
            let mut desired = unchanged.clone();
            desired
                .iter_mut()
                .find(|b| b.id == "formula-1")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(patch);
            assert!(engine.apply_block_snapshot(desired).is_err());
            assert_eq!(engine.blocks(), unchanged);
        }
        for (patch, expected) in [
            (r#"{"latex":{}}"#, "{}"),
            (r#"{"latex":{"value":null}}"#, r#"{"latex":null}"#),
            (r#"{"latex":{"value":""}}"#, r#"{"latex":""}"#),
        ] {
            let mut desired = engine.blocks();
            desired
                .iter_mut()
                .find(|b| b.id == "formula-empty")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(patch.into());
            engine.apply_block_snapshot(desired).unwrap();
            assert_eq!(
                engine
                    .blocks()
                    .iter()
                    .find(|b| b.id == "formula-empty")
                    .unwrap()
                    .resource
                    .as_ref()
                    .unwrap()
                    .properties,
                expected
            );
        }
        let mut desired = engine.blocks();
        let original = desired
            .iter()
            .find(|b| b.id == "formula-empty")
            .unwrap()
            .clone();
        let mut new = original;
        new.id = "new-formula".into();
        new.resource.as_mut().unwrap().properties = r#"{"latex":"x^2"}"#.into();
        new.resource.as_mut().unwrap().property_edits = None;
        desired.push(new);
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let new = map(&blocks, &txn, "new-formula").unwrap();
        assert_eq!(
            out_string(new.get(&txn, "nodeType")).as_deref(),
            Some("void")
        );
        let props = map(&new, &txn, "props").unwrap();
        assert_eq!(out_string(props.get(&txn, "latex")).as_deref(), Some("x^2"));
        assert!(!props.contains_key(&txn, "src"));
    }

    /// 两端同时修改同一公式后交换 Yjs update，按 CRDT 冲突规则收敛。
    #[test]
    fn concurrent_formula_edits_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-formula.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut a = left.blocks();
        a.iter_mut()
            .find(|b| b.id == "formula-1")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"latex":{"value":"a^2"}}"#.into());
        let ua = left.apply_block_snapshot(a).unwrap();
        let mut b = right.blocks();
        b.iter_mut()
            .find(|b| b.id == "formula-1")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"latex":{"value":"b^2"}}"#.into());
        let ub = right.apply_block_snapshot(b).unwrap();
        left.apply_cses_update(ub.v1_update).unwrap();
        right.apply_cses_update(ua.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
    }

    /// 发布分页符保持 void；非法旧嵌套与子块只读保留，正文修改不覆盖扩展属性。
    #[test]
    fn page_divider_projection_preserves_opaque_legacy_nodes() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-page-divider.update"
        ));
        let before = e.blocks();
        assert!(project(&e.doc, "fixture-doc").reason.is_none());
        assert_eq!(
            before
                .iter()
                .filter(|b| b.block_type == "page-divider")
                .count(),
            2
        );
        for id in ["nested-break", "malformed-break"] {
            assert_eq!(
                before.iter().find(|b| b.id == id).unwrap().block_type,
                UNSUPPORTED_BLOCK_TYPE
            );
        }
        let mut desired = before.clone();
        let tail = desired.iter_mut().find(|b| b.id == "tail").unwrap();
        tail.text = "手机编辑正文".into();
        tail.segments.clear();
        e.apply_block_snapshot(desired).unwrap();
        let txn = e.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let block = map(&blocks, &txn, "break-1").unwrap();
        let props = map(&block, &txn, "props").unwrap();
        assert!(props.contains_key(&txn, "futureProp"));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        assert_eq!(
            out_string(map(&block, &txn, "meta").unwrap().get(&txn, "audit")).as_deref(),
            Some("desktop")
        );
        assert_eq!(
            children(&map(&blocks, &txn, "malformed-break").unwrap(), &txn),
            vec!["hidden"]
        );
    }

    /// 发布版日期卡片按void投影，外观补丁不覆盖日期、扩展属性和元数据。
    #[test]
    fn date_card_published_projection_and_field_patches() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-date-card.update"
        ));
        assert_eq!(
            e.blocks()
                .iter()
                .filter(|b| b.block_type == "date-card")
                .count(),
            13
        );
        assert_eq!(
            e.blocks()
                .iter()
                .find(|b| b.id == "nested-date")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("box")
        );
        assert_eq!(
            e.blocks()
                .iter()
                .find(|b| b.id == "malformed-date")
                .unwrap()
                .block_type,
            UNSUPPORTED_BLOCK_TYPE
        );
        let mut desired = e.blocks();
        desired[0].resource.as_mut().unwrap().property_edits = Some(r##"{"style":{"value":"pill"},"fg":{"value":"#123456"},"fsCalendar":{"value":"- 24"}}"##.into());
        e.apply_block_snapshot(desired).unwrap();
        let txn = e.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let card = map(&blocks, &txn, "date-0").unwrap();
        let props = map(&card, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "date")).as_deref(),
            Some("2026-10-25T09:30")
        );
        assert_eq!(
            out_string(props.get(&txn, "style")).as_deref(),
            Some("pill")
        );
        assert!(props.contains_key(&txn, "futureProp"));
        assert_eq!(
            out_string(map(&card, &txn, "meta").unwrap().get(&txn, "audit")).as_deref(),
            Some("desktop")
        );
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        assert!(matches!(card.get(&txn, "children"), Some(Out::YArray(ref a)) if a.len(&txn) == 0));
    }

    /// 非法写入整次拒绝，旧未知日期外观不会因其他字段编辑被规范化。
    #[test]
    fn date_card_invalid_edits_are_atomic() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-date-card.update"
        ));
        let before = e
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        for patch in [
            r#"{"style":{"value":"future"}}"#,
            r#"{"format":{"value":"invalid"}}"#,
            r#"{"width":{"value":0}}"#,
            r#"{"bw":{"value":"100px solid"}}"#,
            r#"{"fg":{"value":false}}"#,
            r#"{"url":{"value":"https://example.test"}}"#,
            r#"{"date":{"value":42}}"#,
            r#"{"futureProp":{"value":null}}"#,
        ] {
            let mut desired = e.blocks();
            desired[0].resource.as_mut().unwrap().property_edits = Some(patch.into());
            assert!(e.apply_block_snapshot(desired).is_err(), "{patch}");
            assert_eq!(
                e.doc
                    .transact()
                    .encode_state_as_update_v1(&StateVector::default()),
                before
            );
        }
        let mut desired = e.blocks();
        desired[0].text = "invalid text".into();
        assert!(e.apply_block_snapshot(desired).is_err());
        assert_eq!(
            e.doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default()),
            before
        );
    }

    /// 不同端编辑日期卡片独立字段后收敛，新建、删除和恢复不引入URL或正文。
    #[test]
    fn date_card_concurrent_fields_and_creation_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-date-card.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut a = left.blocks();
        let mut b = right.blocks();
        a[0].resource.as_mut().unwrap().property_edits =
            Some(r#"{"style":{"value":"rail"}}"#.into());
        b[0].resource.as_mut().unwrap().property_edits =
            Some(r#"{"format":{"value":"min"}}"#.into());
        let ua = left.apply_block_snapshot(a).unwrap();
        let ub = right.apply_block_snapshot(b).unwrap();
        left.apply_cses_update(ub.v1_update).unwrap();
        right.apply_cses_update(ua.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        let merged = left.blocks();
        let properties = &merged[0].resource.as_ref().unwrap().properties;
        assert!(
            properties.contains("rail")
                && properties.contains("min")
                && properties.contains("2026-10-25")
        );
        let mut desired = left.blocks();
        let mut new = desired[0].clone();
        new.id = "mobile-date".into();
        new.resource = Some(CollabResource {
            properties: r#"{"date":"2026-10-25T10:00","style":"calendar"}"#.into(),
            property_edits: None,
        });
        desired.insert(1, new);
        left.apply_block_snapshot(desired.clone()).unwrap();
        let mut removed = left.blocks();
        removed.retain(|b| b.id != "mobile-date");
        left.apply_block_snapshot(removed).unwrap();
        left.apply_block_snapshot(desired).unwrap();
        let txn = left.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let props = map(&map(&blocks, &txn, "mobile-date").unwrap(), &txn, "props").unwrap();
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
    }

    /// 非根级、正文、资源补丁和占位删除在事务前拒绝，失败不产生部分写入。
    #[test]
    fn page_divider_invalid_snapshots_are_atomic() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-page-divider.update"
        ));
        for kind in ["text", "nested", "resource", "remove-opaque"] {
            let mut desired = e.blocks();
            let first = desired.iter_mut().find(|b| b.id == "break-1").unwrap();
            match kind {
                "text" => first.text = "非法正文".into(),
                "nested" => {
                    let mut nested = first.clone();
                    nested.id = "new-nested".into();
                    nested.parent_id = Some("box".into());
                    let index = desired.iter().position(|b| b.id == "box").unwrap() + 1;
                    desired.insert(index, nested);
                }
                "resource" => {
                    first.resource = Some(CollabResource {
                        properties: "{}".into(),
                        property_edits: Some(r#"{"url":{"value":"https://example.test"}}"#.into()),
                    })
                }
                _ => desired.retain(|b| b.id != "malformed-break"),
            }
            let before = e
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default());
            assert!(e.apply_block_snapshot(desired).is_err(), "{kind}");
            assert_eq!(
                e.doc
                    .transact()
                    .encode_state_as_update_v1(&StateVector::default()),
                before,
                "{kind}"
            );
        }
    }

    /// 新增分页符与另一端正文并发收敛；删除恢复和 SQLite 重开保持正式无正文结构。
    #[test]
    fn page_divider_creation_delete_restore_and_concurrent_text_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-page-divider.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut desired = left.blocks();
        let mut new = desired[0].clone();
        new.id = "mobile-break".into();
        desired.insert(2, new.clone());
        let inserted = left.apply_block_snapshot(desired).unwrap();
        let mut other = right.blocks();
        let tail = other.iter_mut().find(|b| b.id == "tail").unwrap();
        tail.text = "桌面编辑😀".into();
        tail.segments.clear();
        let edited = right.apply_block_snapshot(other).unwrap();
        left.apply_cses_update(edited.v1_update).unwrap();
        right.apply_cses_update(inserted.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        let mut removed = left.blocks();
        removed.retain(|b| b.id != new.id);
        let deletion = left.apply_block_snapshot(removed).unwrap();
        right.apply_cses_update(deletion.v1_update).unwrap();
        let mut restored = left.blocks();
        restored.insert(2, new);
        let restoration = left.apply_block_snapshot(restored).unwrap();
        right.apply_cses_update(restoration.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        let mut reopened = CollabEngine::open(left.document_id.clone(), left.database_path.clone())
            .unwrap()
            .0;
        reopened.blockcraft_root_id = Some("fixture-doc".into());
        assert_eq!(reopened.blocks(), left.blocks());
        let txn = reopened.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let block = map(&blocks, &txn, "mobile-break").unwrap();
        let props = map(&block, &txn, "props").unwrap();
        assert_eq!(
            out_string(block.get(&txn, "nodeType")).as_deref(),
            Some("void")
        );
        assert!(matches!(block.get(&txn, "children"), Some(Out::YArray(a)) if a.len(&txn) == 0));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
    }

    /// 桌面全部分割线与嵌套结构投影为 void；单字段补丁保留扩展属性及 null/缺失语义。
    #[test]
    fn divider_projection_patches_and_invalid_edits_are_atomic() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-divider.update");
        let mut engine = engine(fixture);
        let before = engine.blocks();
        assert!(project(&engine.doc, "fixture-doc").reason.is_none());
        assert_eq!(
            before.iter().filter(|b| b.block_type == "divider").count(),
            23
        );
        assert_eq!(
            before.last().unwrap().parent_id.as_deref(),
            Some("divider-callout")
        );
        assert!(before
            .iter()
            .filter(|b| b.block_type == "divider")
            .all(|b| b.text.is_empty() && b.segments.is_empty() && b.resource.is_some()));
        let mut desired = before.clone();
        let item = desired.iter_mut().find(|b| b.id == "divider-0").unwrap();
        item.resource.as_mut().unwrap().property_edits =
            Some(r##"{"style":{"value":"edge-vine"},"lineColor":{"value":"#EF4444"}}"##.into());
        engine.apply_block_snapshot(desired).unwrap();
        let txn = engine.doc.transact();
        let blocks = txn.get_map(ROOT_NAME).unwrap();
        let block = map(&blocks, &txn, "divider-0").unwrap();
        let props = map(&block, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "style")).as_deref(),
            Some("edge-vine")
        );
        assert_eq!(
            out_string(props.get(&txn, "text")).as_deref(),
            Some("legacy label preserved")
        );
        assert!(props.contains_key(&txn, "customDivider"));
        assert!(map(&block, &txn, "meta")
            .unwrap()
            .contains_key(&txn, "customAudit"));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        assert!(matches!(block.get(&txn, "children"), Some(Out::YArray(_))));
        drop(txn);
        let state = engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        for patch in [
            r#"{"url":{"value":"https://example.test"}}"#,
            r#"{"opacity":{"value":0}}"#,
            r#"{"length":{"value":"huge"}}"#,
            r#"{"style":{"value":"future"}}"#,
            r#"{"customDivider":{"value":null}}"#,
        ] {
            let mut invalid = engine.blocks();
            invalid
                .iter_mut()
                .find(|b| b.id == "divider-0")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(patch.into());
            assert!(engine.apply_block_snapshot(invalid).is_err());
            assert_eq!(
                engine
                    .doc
                    .transact()
                    .encode_state_as_update_v1(&StateVector::default()),
                state
            );
        }
        let mut invalid = engine.blocks();
        invalid
            .iter_mut()
            .find(|b| b.id == "divider-0")
            .unwrap()
            .text = "cannot store text".into();
        assert!(engine.apply_block_snapshot(invalid).is_err());
        assert_eq!(
            engine
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default()),
            state
        );
        let mut desired = engine.blocks();
        desired
            .iter_mut()
            .find(|b| b.id == "legacy-divider")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"opacity":{}}"#.into());
        engine.apply_block_snapshot(desired).unwrap();
        assert!(!engine
            .blocks()
            .iter()
            .find(|b| b.id == "legacy-divider")
            .unwrap()
            .resource
            .as_ref()
            .unwrap()
            .properties
            .contains("opacity"));
        let mut desired = engine.blocks();
        desired
            .iter_mut()
            .find(|b| b.id == "legacy-divider")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"opacity":{"value":null}}"#.into());
        engine.apply_block_snapshot(desired).unwrap();
        assert!(engine
            .blocks()
            .iter()
            .find(|b| b.id == "legacy-divider")
            .unwrap()
            .resource
            .as_ref()
            .unwrap()
            .properties
            .contains("null"));
    }

    /// 两端独立修改分割线的不同字段后收敛，陈旧完整投影不能覆盖另一端显式设置。
    #[test]
    fn divider_field_edits_converge_and_creation_has_no_url_or_text() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-divider.update");
        let mut left = engine(fixture);
        let mut right = engine(fixture);
        let mut a = left.blocks();
        a.iter_mut()
            .find(|b| b.id == "divider-0")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"style":{"value":"wave"}}"#.into());
        let ua = left.apply_block_snapshot(a).unwrap();
        let mut b = right.blocks();
        b.iter_mut()
            .find(|b| b.id == "divider-0")
            .unwrap()
            .resource
            .as_mut()
            .unwrap()
            .property_edits = Some(r#"{"length":{"value":"short"}}"#.into());
        let ub = right.apply_block_snapshot(b).unwrap();
        left.apply_cses_update(ub.v1_update).unwrap();
        right.apply_cses_update(ua.v1_update).unwrap();
        assert_eq!(left.blocks(), right.blocks());
        let mut desired = left.blocks();
        let mut new = desired
            .iter()
            .find(|b| b.id == "divider-0")
            .unwrap()
            .clone();
        new.id = "new-divider".into();
        new.resource = Some(CollabResource {
            properties: r#"{"style":"double"}"#.into(),
            property_edits: None,
        });
        new.parent_id = None;
        desired.push(new);
        left.apply_block_snapshot(desired).unwrap();
        let txn = left.doc.transact();
        let root = txn.get_map(ROOT_NAME).unwrap();
        let block = map(&root, &txn, "new-divider").unwrap();
        let props = map(&block, &txn, "props").unwrap();
        assert_eq!(
            out_string(block.get(&txn, "nodeType")).as_deref(),
            Some("void")
        );
        assert!(matches!(block.get(&txn, "children"), Some(Out::YArray(_))));
        assert!(!props.contains_key(&txn, "url") && !props.contains_key(&txn, "src"));
        assert_eq!(
            out_string(props.get(&txn, "style")).as_deref(),
            Some("double")
        );
    }
    /// 发布版 Mermaid 的容器和源码共享类型保持独立，普通编辑不覆盖模式或扩展属性。
    #[test]
    fn mermaid_source_roundtrips_without_replacing_container_or_extensions() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-mermaid.update"
        ));
        let before = e.blocks();
        assert_eq!(
            before.iter().filter(|b| b.block_type == "mermaid").count(),
            2
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "mermaid-source-1")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("mermaid-1")
        );
        assert_eq!(
            before
                .iter()
                .find(|b| b.id == "nested-mermaid")
                .unwrap()
                .parent_id
                .as_deref(),
            Some("box")
        );
        let mut desired = before.clone();
        desired
            .iter_mut()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .text = "flowchart TD\nA[中文😀]-->C".into();
        let update = e.apply_block_snapshot(desired.clone()).unwrap();
        assert!(!update.v1_update.is_empty());
        assert_eq!(e.blocks(), desired);
        let blocks = e.doc.get_or_insert_map(ROOT_NAME);
        let txn = e.doc.transact();
        let outer = map(&blocks, &txn, "mermaid-1").unwrap();
        let props = map(&outer, &txn, "props").unwrap();
        assert_eq!(
            out_string(props.get(&txn, "mode")).as_deref(),
            Some("default")
        );
        assert!(props.get(&txn, "customDiagram").is_some());
        assert_eq!(children(&outer, &txn), vec!["mermaid-source-1"]);
        let source = map(&blocks, &txn, "mermaid-source-1").unwrap();
        assert!(matches!(source.get(&txn, "children"), Some(Out::YText(_))));
        assert!(map(&source, &txn, "props")
            .unwrap()
            .get(&txn, "customSource")
            .is_some());
        assert!(map(&outer, &txn, "meta")
            .unwrap()
            .get(&txn, "customAudit")
            .is_some());
    }

    /// 同一源码的独立文本增量与其他正文修改在两个真实 Yrs 副本收敛。
    #[test]
    fn mermaid_concurrent_source_edits_converge() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-mermaid.update");
        let mut phone = engine(fixture);
        let mut desktop = engine(fixture);
        let mut a = phone.blocks();
        a.iter_mut()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .text
            .push_str("\nB-->C");
        let local = phone.apply_block_snapshot(a).unwrap().v1_update;
        let mut b = desktop.blocks();
        b.iter_mut()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .text
            .insert_str(0, "%% remote\n");
        b.iter_mut()
            .find(|b| b.id == "tail")
            .unwrap()
            .text
            .push_str("远端正文");
        let remote = desktop.apply_block_snapshot(b).unwrap().v1_update;
        phone.apply_cses_update(remote).unwrap();
        desktop.apply_cses_update(local).unwrap();
        assert_eq!(phone.blocks(), desktop.blocks());
        let merged = phone
            .blocks()
            .into_iter()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .text;
        assert!(merged.starts_with("%% remote\n"));
        assert!(merged.ends_with("B-->C"));
    }

    /// 创建写入桌面容器与唯一源码；删除后原快照可以恢复投影内容及身份。
    #[test]
    fn mermaid_creation_deletion_and_snapshot_restore_keep_formal_structure() {
        let mut e = engine(include_bytes!(
            "../../tests/fixtures/blockcraft-mermaid.update"
        ));
        let original = e.blocks();
        let mut desired = original.clone();
        let mut outer = original
            .iter()
            .find(|b| b.id == "mermaid-1")
            .unwrap()
            .clone();
        outer.id = "new-mermaid".into();
        let mut source = original
            .iter()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .clone();
        source.id = "new-source".into();
        source.parent_id = Some(outer.id.clone());
        source.text = String::new();
        desired.extend([outer, source]);
        e.apply_block_snapshot(desired.clone()).unwrap();
        {
            let blocks = e.doc.get_or_insert_map(ROOT_NAME);
            let txn = e.doc.transact();
            let outer = map(&blocks, &txn, "new-mermaid").unwrap();
            assert_eq!(
                out_string(outer.get(&txn, "nodeType")).as_deref(),
                Some("block")
            );
            assert_eq!(
                out_string(map(&outer, &txn, "props").unwrap().get(&txn, "mode")).as_deref(),
                Some("default")
            );
            assert_eq!(children(&outer, &txn), vec!["new-source"]);
        }
        e.apply_block_snapshot(original.clone()).unwrap();
        assert_eq!(e.blocks(), original);
        e.apply_block_snapshot(desired.clone()).unwrap();
        assert_eq!(e.blocks(), desired);
    }

    /// 共享 mode 仅允许三种桌面值；显式补丁不影响源码、未知属性或其他块，拒绝非法值时原子回滚。
    #[test]
    fn mermaid_modes_project_patch_validate_and_preserve_unknown_fields() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-mermaid.update");
        let mut e = engine(fixture);
        for mode in ["text", "graph", "default"] {
            let mut desired = e.blocks();
            let outer = desired.iter_mut().find(|b| b.id == "mermaid-1").unwrap();
            outer.resource = Some(CollabResource {
                properties: format!(r#"{{"mode":"{mode}"}}"#),
                property_edits: Some(format!(r#"{{"mode":{{"value":"{mode}"}}}}"#)),
            });
            e.apply_block_snapshot(desired).unwrap();
            let current = e.blocks();
            let outer = current.iter().find(|b| b.id == "mermaid-1").unwrap();
            assert_eq!(
                outer.resource.as_ref().unwrap().properties,
                format!(r#"{{"mode":"{mode}"}}"#)
            );
            let blocks = e.doc.get_or_insert_map(ROOT_NAME);
            let txn = e.doc.transact();
            let native = map(&blocks, &txn, "mermaid-1").unwrap();
            assert!(map(&native, &txn, "props")
                .unwrap()
                .get(&txn, "customDiagram")
                .is_some());
        }
        for invalid in [
            r#"{"mode":{"value":"invalid"}}"#,
            r#"{"url":{"value":"https://example.test"}}"#,
            r#"{"mode":{"value":1}}"#,
        ] {
            let original = e.blocks();
            let mut desired = original.clone();
            desired
                .iter_mut()
                .find(|b| b.id == "mermaid-1")
                .unwrap()
                .resource
                .as_mut()
                .unwrap()
                .property_edits = Some(invalid.into());
            desired
                .iter_mut()
                .find(|b| b.id == "mermaid-source-1")
                .unwrap()
                .text = "must not commit".into();
            assert!(e.apply_block_snapshot(desired).is_err());
            assert_eq!(e.blocks(), original);
        }
        // Ordinary source edits do not normalize a future desktop mode.
        {
            let blocks = e.doc.get_or_insert_map(ROOT_NAME);
            let mut txn = e.doc.transact_mut();
            let outer = map(&blocks, &txn, "mermaid-1").unwrap();
            map(&outer, &txn, "props")
                .unwrap()
                .insert(&mut txn, "mode", "future");
        }
        let mut desired = e.blocks();
        desired
            .iter_mut()
            .find(|b| b.id == "mermaid-source-1")
            .unwrap()
            .text = "flowchart LR\nA-->C".into();
        e.apply_block_snapshot(desired).unwrap();
        assert_eq!(
            e.blocks()
                .iter()
                .find(|b| b.id == "mermaid-1")
                .unwrap()
                .resource
                .as_ref()
                .unwrap()
                .properties,
            r#"{"mode":"future"}"#
        );
    }

    /// 非法父子结构、超长源码以及嵌入对象在任何共享写入之前拒绝。
    #[test]
    fn mermaid_invalid_mutations_are_atomic_and_malformed_remote_trees_stay_opaque() {
        let fixture = include_bytes!("../../tests/fixtures/blockcraft-mermaid.update");
        for variant in 0..4 {
            let mut e = engine(fixture);
            let original = e.blocks();
            let mut desired = original.clone();
            let index = desired
                .iter()
                .position(|b| b.id == "mermaid-source-1")
                .unwrap();
            match variant {
                0 => {
                    desired.remove(index);
                }
                1 => desired[index].parent_id = None,
                2 => desired[index].text = "😀".repeat(50_001),
                _ => desired[index].block_type = "paragraph".into(),
            }
            assert!(e.apply_block_snapshot(desired).is_err());
            assert_eq!(e.blocks(), original);
        }
        let e = engine(fixture);
        let blocks = e.doc.get_or_insert_map(ROOT_NAME);
        {
            let mut txn = e.doc.transact_mut();
            let source = map(&blocks, &txn, "mermaid-source-1").unwrap();
            let Some(Out::YText(text)) = source.get(&txn, "children") else {
                panic!("source text")
            };
            text.insert_embed(
                &mut txn,
                0,
                Any::Map(std::sync::Arc::new(HashMap::from([(
                    "latex".into(),
                    Any::String("x".into()),
                )]))),
            );
        }
        let projected = e.blocks();
        assert_eq!(
            projected
                .iter()
                .find(|b| b.id == "mermaid-1")
                .unwrap()
                .block_type,
            UNSUPPORTED_BLOCK_TYPE
        );
        assert!(!projected.iter().any(|b| b.id == "mermaid-source-1"));
        assert!(projected
            .iter()
            .any(|b| b.id == "tail" && b.block_type == "paragraph"));
    }
}
