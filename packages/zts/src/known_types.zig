//! The type names a handler may write without declaring or importing them.
//!
//! The parser-tier name check (`type_names`) reads this list, and
//! `ambient_names.types` publishes the same names with their origin. A test in
//! `ambient_names` compares the two, so a name added to one and not the other
//! fails the build.

/// The ambient type names: the primitives, `Dict`, `DictKey`, the capsule
/// aliases, and the handler ABI aliases. Each is a row of `ambient_names.types`.
pub const ambient = [_][]const u8{
    "boolean",
    "Bytes",
    "never",
    "null",
    "number",
    "string",
    "undefined",
    "unknown",
    "Dict",
    "DictKey",
    "Effects",
    "Proof",
    "Request",
    "Response",
};
