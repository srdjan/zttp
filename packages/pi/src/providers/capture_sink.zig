//! Strict, provider-neutral capture boundary for one model exchange.
//!
//! The request snapshot and raw response borrow from the caller and are valid
//! only for the synchronous `record` call. A sink must copy any data it keeps.
//! The sink owns call ordering and advances its cursor only after the injected
//! recorder succeeds.

const model_request = @import("model_request.zig");

pub const CaptureSink = struct {
    context: *anyopaque,
    record_fn: *const fn (
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void,
    next_call_index: usize = 0,

    pub fn record(
        self: *CaptureSink,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) !void {
        try self.record_fn(self.context, self.next_call_index, snapshot, raw_response);
        self.next_call_index += 1;
    }
};
