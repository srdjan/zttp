/// Existing global entry budget for process-local module stores. Cache and
/// rate-limit state share it so one request-scoped runtime cannot retain an
/// unbounded number of attacker-controlled keys.
pub const max_entries: usize = 10_000;
pub const max_bytes: usize = 16 * 1024 * 1024;
