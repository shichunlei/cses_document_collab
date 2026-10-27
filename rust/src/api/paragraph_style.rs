//! BlockCraft 0.11.20 段落族的字段投影与显式写入校验，不拥有文档或事务。
use super::*;
use std::collections::{BTreeMap, HashMap};

pub(super) const KEYS: &[&str] = &[
    "textDefaults",
    "nextParagraphStyle",
    "heading",
    "depth",
    "fs",
    "pfs",
    "lh",
    "psb",
    "psa",
    "decoration",
];
pub(super) const TYPOGRAPHY_KEYS: &[&str] = &[
    "t:ff",
    "t:px",
    "t:fs",
    "t:ls",
    "s:fontFamily",
    "s:fontSize",
    "s:letterSpacing",
];

/// 只对可编辑段落族开放共享样式；代码和资源保持各自输入规则。
pub(super) fn supports(kind: &str) -> bool {
    matches!(
        kind,
        "paragraph" | "quote" | "bulleted_list" | "numbered_list" | "todo_list"
    ) || kind.starts_with("heading_")
}

/// 原样读取已建模字段，保留缺失/null 供字段级撤销；不写共享数据。
pub(super) fn project<T: ReadTxn>(kind: &str, props: &MapRef, txn: &T) -> String {
    let values: BTreeMap<_, _> = KEYS
        .iter()
        .filter_map(|key| {
            // 常规列表深度仍由独立 indent 通道持有；仅保留该通道尚未覆盖的原始深度。
            if *key == "depth" {
                if let Some(depth) = out_u32(props.get(txn, key)) {
                    if depth == 0 || (is_indentable_block_type(kind) && depth <= 6) {
                        return None;
                    }
                }
            }
            match props.get(txn, key) {
                Some(Out::Any(value)) => Some((*key, value)),
                _ => None,
            }
        })
        .collect();
    serde_json::to_string(&canonical_mention_value(
        serde_json::to_value(&values).unwrap(),
    ))
    .unwrap()
}

/// 提取字符外观白名单，未知键留在原 Y.Text，不成为新输入的默认属性。
pub(super) fn read_typography(attrs: Option<&Attrs>) -> Option<String> {
    let values: BTreeMap<_, _> = TYPOGRAPHY_KEYS
        .iter()
        .filter_map(|key| {
            attrs
                .and_then(|a| a.get(*key))
                .filter(|v| !matches!(v, Any::Null))
                .map(|v| (*key, v.clone()))
        })
        .collect();
    (!values.is_empty()).then(|| {
        serde_json::to_string(&canonical_mention_value(
            serde_json::to_value(&values).unwrap(),
        ))
        .unwrap()
    })
}

/// 校验可往返的字体/字号/字距 JSON，拒绝业务元数据和超大载荷。
pub(super) fn typography(input: Option<&str>) -> Result<Attrs, String> {
    let Some(input) = input else {
        return Ok(Attrs::new());
    };
    let invalid = || "INVALID_TYPOGRAPHY: 字符外观属性无效".to_owned();
    if input.len() > 8192 {
        return Err(invalid());
    }
    let Any::Map(values) = Any::from_json(input).map_err(|_| invalid())? else {
        return Err(invalid());
    };
    if values.iter().any(|(k, v)| {
        !TYPOGRAPHY_KEYS.contains(&k.as_str()) || !matches!(v, Any::String(_) | Any::Number(_))
    }) {
        return Err(invalid());
    }
    Ok(values
        .iter()
        .map(|(k, v)| (k.as_str().into(), v.clone()))
        .collect())
}

/// 校验初始化值或单字段包装补丁；仅修改明确携带的字段，缺失字段保持远端权威值。
/// heading 仅接受 0～6 的整数，0 表示正文；超范围在事务开始前拒绝。
pub(super) fn parse(input: &str, initial: bool) -> Result<HashMap<String, Option<Any>>, String> {
    let invalid = || "INVALID_PARAGRAPH_STYLE: 段落属性无效".to_owned();
    if input.len() > 32768 {
        return Err(invalid());
    }
    let Any::Map(values) = Any::from_json(input).map_err(|_| invalid())? else {
        return Err(invalid());
    };
    values.iter().map(|(key, wrapper)| {
        if !KEYS.contains(&key.as_str()) { return Err(invalid()); }
        let value = if initial { Some(wrapper.clone()) } else {
            let Any::Map(v) = wrapper else { return Err(invalid()); };
            if v.keys().any(|k| k != "value") { return Err(invalid()); }
            v.get("value").cloned()
        };
        if let Some(v) = &value {
            let valid = matches!(v, Any::Null) || match key.as_str() {
                "heading" => matches!(v, Any::Number(level) if level.is_finite()
                    && level.fract() == 0.0 && (0.0..=6.0).contains(level)),
                "textDefaults" => matches!(v, Any::Map(m) if m.iter().all(|(k,v)|
                    (matches!(k.as_str(), "a:bold"|"a:italic"|"a:underline"|"a:strike"|"a:code"|"a:sup"|"a:sub") && matches!(v, Any::Bool(_)))
                    || (matches!(k.as_str(), "s:color"|"s:background") && matches!(v, Any::String(_)))
                    || (TYPOGRAPHY_KEYS.contains(&k.as_str()) && matches!(v, Any::String(_)|Any::Number(_))))),
                "nextParagraphStyle" => matches!(v, Any::String(s) if matches!(s.as_ref(), "same"|"body")),
                "decoration" => matches!(v, Any::String(_) | Any::Map(_) | Any::Array(_)),
                _ => matches!(v, Any::Number(_) | Any::String(_)),
            };
            if !valid { return Err(invalid()); }
        }
        Ok((key.clone(), value))
    }).collect()
}
