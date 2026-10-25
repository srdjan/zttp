//! Leaf helper: the packed key that identifies a (scope, slot) binding.

const ir = @import("zts-engine").parser.ir;

pub fn packBindingKey(scope_id: ir.ScopeId, slot: u16) u32 {
    return (@as(u32, scope_id) << 16) | @as(u32, slot);
}
