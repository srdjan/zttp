//! Closed request-policy values shared by request construction and evidence.

pub const Purpose = enum { normal, summarization };
pub const CachePolicy = enum { enabled, disabled };
