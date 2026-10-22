//! Native JS-callable runtime builtins extracted from the handler instance.
//!
//! HandlerInstance registers native adapters that pass explicit HTTP state
//! to these body readers. The helpers used here
//! (`beginBodyRead`, `getStringData`) live with the HTTP natives they
//! belong to.

const std = @import("std");
const zq = @import("zts");
const http = @import("runtime_http.zig");
const natives = @import("runtime_natives.zig");

pub fn bodyText(ctx: *zq.Context, state: ?*http.HttpState, allocator: std.mem.Allocator, this: zq.JSValue) anyerror!zq.JSValue {
    const body_val = http.beginBodyRead(ctx, state, allocator, this);
    if (ctx.hasException()) return zq.JSValue.exception_val;
    if (body_val.isNull() or body_val.isUndefined()) {
        return ctx.createString("");
    }
    if (body_val.isAnyString()) {
        return body_val;
    }
    return ctx.createString("");
}

pub fn bodyJson(ctx: *zq.Context, state: ?*http.HttpState, allocator: std.mem.Allocator, this: zq.JSValue) anyerror!zq.JSValue {
    const body_val = http.beginBodyRead(ctx, state, allocator, this);
    if (ctx.hasException()) return zq.JSValue.exception_val;
    if (body_val.isNull() or body_val.isUndefined()) {
        return zq.JSValue.undefined_val;
    }
    const body = natives.getStringData(body_val) orelse return zq.JSValue.undefined_val;
    return zq.builtins.parseJsonValue(ctx, body) catch zq.JSValue.undefined_val;
}
