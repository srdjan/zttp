//! zttp:collections - the pure operations over `Dict<K, V>` (spec 6.2).
//!
//! Zero capabilities and no state: every export reads its arguments and
//! returns a new value. `dictSet` and `dictRemove` return new dictionaries, so
//! a Dict a caller still holds is never changed underneath it.
//!
//! The module lives on this side of the package boundary rather than in
//! `packages/modules/src/` because a Dict is an engine value kind: minting one
//! needs `object.JSObject.createDict`, which the SDK does not expose and should
//! not - the SDK's surface is for modules built out of values that already
//! exist.

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const object = @import("../../object.zig");
const dict = @import("../../dict.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");
const helpers = @import("../../builtins/helpers.zig");

const JSValue = value.JSValue;
const JSObject = object.JSObject;

pub const binding = mb.ModuleBinding{
    .specifier = "zttp:collections",
    .name = "collections",
    .required_capabilities = &.{},
    .exports = &.{
        .{ .name = "dictEmpty", .func = dictEmptyNative, .arg_count = 0, .required_arg_count = 0, .effect = .none, .returns = .dict, .param_types = &.{}, .laws = &.{.pure} },
        .{ .name = "dictFromEntries", .func = dictFromEntriesNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.object}, .laws = &.{.pure} },
        .{ .name = "dictGet", .func = dictGetNative, .arg_count = 2, .effect = .none, .returns = .unknown, .param_types = &.{ .dict, .unknown }, .laws = &.{.pure} },
        .{ .name = "dictSet", .func = dictSetNative, .arg_count = 3, .effect = .none, .returns = .dict, .param_types = &.{ .dict, .unknown, .unknown }, .laws = &.{.pure} },
        .{ .name = "dictRemove", .func = dictRemoveNative, .arg_count = 2, .effect = .none, .returns = .dict, .param_types = &.{ .dict, .unknown }, .laws = &.{.pure} },
        .{ .name = "dictHas", .func = dictHasNative, .arg_count = 2, .effect = .none, .returns = .boolean, .param_types = &.{ .dict, .unknown }, .laws = &.{.pure} },
        .{ .name = "dictEntries", .func = dictEntriesNative, .arg_count = 1, .effect = .none, .returns = .object, .param_types = &.{.dict}, .laws = &.{.pure} },
        .{ .name = "dictMapValues", .func = dictMapValuesNative, .arg_count = 2, .effect = .none, .returns = .dict, .param_types = &.{ .dict, .object }, .laws = &.{.pure} },
        .{ .name = "dictFilter", .func = dictFilterNative, .arg_count = 2, .effect = .none, .returns = .dict, .param_types = &.{ .dict, .object }, .laws = &.{.pure} },
        .{ .name = "dictFold", .func = dictFoldNative, .arg_count = 3, .effect = .none, .returns = .unknown, .param_types = &.{ .dict, .object, .unknown }, .laws = &.{.pure} },
    },
};

pub const exports = binding.toModuleExports();

fn dictArg(args: []const JSValue, index: usize) ?*JSObject {
    if (args.len <= index) return null;
    return dict.asDict(args[index]);
}

fn argAt(args: []const JSValue, index: usize) JSValue {
    if (args.len <= index) return JSValue.undefined_val;
    return args[index];
}

fn dictEmptyNative(ctx_ptr: *anyopaque, _: JSValue, _: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const out = try dict.empty(ctx);
    return JSValue.fromPtr(out);
}

/// `dictFromEntries(entries)`: a duplicate key is the caller's error, not a
/// silent last-wins. Spec 6.2 separates this from the `dictEmpty` plus
/// `dictSet` fold on exactly that behavior, so the two are never
/// interchangeable.
fn dictFromEntriesNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    if (args.len == 0 or !args[0].isObject()) return helpers.createResultErr(ctx, JSValue.undefined_val);
    const entries = JSObject.fromValue(args[0]);
    if (entries.class_id != .array) return helpers.createResultErr(ctx, JSValue.undefined_val);

    var out = try dict.empty(ctx);
    const len = entries.getArrayLength();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const pair_val = entries.getSlot(@intCast(i + 1));
        if (!pair_val.isObject()) return duplicateKeyError(ctx, JSValue.undefined_val);
        const pair = JSObject.fromValue(pair_val);
        if (pair.class_id != .array or pair.getArrayLength() < 2) {
            return duplicateKeyError(ctx, JSValue.undefined_val);
        }
        const key = pair.getSlot(1);
        const val = pair.getSlot(2);
        if (dict.has(out, key)) return duplicateKeyError(ctx, key);
        out = try dict.set(ctx, out, key, val);
    }
    return helpers.createResultOk(ctx, JSValue.fromPtr(out));
}

/// `{ kind: "duplicate-key", key }`, the error shape spec 6.2 declares.
fn duplicateKeyError(ctx: *context.Context, key: JSValue) JSValue {
    const pool = ctx.hidden_class_pool orelse return helpers.createResultErr(ctx, JSValue.undefined_val);
    const obj = ctx.createObject(null) catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    const kind_text = ctx.createString("duplicate-key") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    const kind_atom = ctx.atoms.intern("kind") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    const key_atom = ctx.atoms.intern("key") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    obj.setProperty(ctx.allocator, pool, kind_atom, kind_text) catch {};
    obj.setProperty(ctx.allocator, pool, key_atom, key) catch {};
    return helpers.createResultErr(ctx, JSValue.fromPtr(obj));
}

fn dictGetNative(_: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    return dict.get(d, argAt(args, 1));
}

fn dictSetNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const out = try dict.set(ctx, d, argAt(args, 1), argAt(args, 2));
    return JSValue.fromPtr(out);
}

fn dictRemoveNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const out = try dict.remove(ctx, d, argAt(args, 1));
    return JSValue.fromPtr(out);
}

fn dictHasNative(_: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const d = dictArg(args, 0) orelse return JSValue.false_val;
    return if (dict.has(d, argAt(args, 1))) JSValue.true_val else JSValue.false_val;
}

fn dictEntriesNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const out = helpers.createArrayWithPrototype(ctx) orelse return JSValue.undefined_val;

    const total = dict.count(d);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const pair = helpers.createArrayWithPrototype(ctx) orelse return JSValue.undefined_val;
        try pair.setIndex(ctx.allocator, 0, dict.keyAt(d, i));
        try pair.setIndex(ctx.allocator, 1, dict.valueAt(d, i));
        try out.setIndex(ctx.allocator, i, JSValue.fromPtr(pair));
    }
    return JSValue.fromPtr(out);
}

/// The three callback-taking exports run their callback once per entry in
/// insertion order and return a `Dict` rather than a `Result`: a
/// transformation of an existing dictionary cannot produce a duplicate key, so
/// there is no impossible error for the caller to handle.
fn dictMapValuesNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const callback = helpers.getCallbackArg(args[1..]) orelse return JSValue.undefined_val;
    const call_fn = helpers.getCallFn(ctx) orelse return JSValue.undefined_val;

    var out = try dict.empty(ctx);
    const total = dict.count(d);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const key = dict.keyAt(d, i);
        const mapped = helpers.invokeCallback(ctx, call_fn, callback, &.{ dict.valueAt(d, i), key }) orelse
            return JSValue.undefined_val;
        out = try dict.set(ctx, out, key, mapped);
    }
    return JSValue.fromPtr(out);
}

fn dictFilterNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const callback = helpers.getCallbackArg(args[1..]) orelse return JSValue.undefined_val;
    const call_fn = helpers.getCallFn(ctx) orelse return JSValue.undefined_val;

    var out = try dict.empty(ctx);
    const total = dict.count(d);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const key = dict.keyAt(d, i);
        const val = dict.valueAt(d, i);
        const keep = helpers.invokeCallback(ctx, call_fn, callback, &.{ val, key }) orelse
            return JSValue.undefined_val;
        if (keep.toConditionBool() orelse false) {
            out = try dict.set(ctx, out, key, val);
        }
    }
    return JSValue.fromPtr(out);
}

fn dictFoldNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const d = dictArg(args, 0) orelse return JSValue.undefined_val;
    const callback = helpers.getCallbackArg(args[1..]) orelse return JSValue.undefined_val;
    const call_fn = helpers.getCallFn(ctx) orelse return JSValue.undefined_val;

    var acc = argAt(args, 2);
    const total = dict.count(d);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        acc = helpers.invokeCallback(ctx, call_fn, callback, &.{ acc, dict.valueAt(d, i), dict.keyAt(d, i) }) orelse
            return JSValue.undefined_val;
    }
    return acc;
}
