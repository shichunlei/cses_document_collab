pub mod api;
mod frb_generated;

/// Opt-in native experiment, separate from the production FRB document engine.
#[cfg(any(test, feature = "history-prototype"))]
pub mod history_prototype;
