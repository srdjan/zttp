const handles = @import("handle.zig");
const value = @import("value.zig");

const ModuleHandle = handles.ModuleHandle;
const RuntimeError = handles.RuntimeError;
const JSValue = value.JSValue;

extern fn zttpSdkParseJson(handle: *ModuleHandle, json_ptr: [*]const u8, json_len: usize, out: *JSValue) bool;

/// Parse a JSON string into a JSValue owned by the runtime GC.
pub fn parseJson(handle: *ModuleHandle, json: []const u8) RuntimeError!JSValue {
    var out: JSValue = undefined;
    if (!zttpSdkParseJson(handle, json.ptr, json.len, &out)) return error.RuntimeFailure;
    return out;
}
