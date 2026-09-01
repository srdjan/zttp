const std = @import("std");
const zts = @import("zts");

/// The exact contract and configured policy accepted by one analyzer run.
/// Both values own their backing storage and stay together until the runtime
/// pool has copied their projected policy into a generation.
pub const CheckedPolicy = struct {
    contract: zts.HandlerContract,
    policy: zts.HandlerPolicy,

    pub fn deinit(self: *CheckedPolicy, allocator: std.mem.Allocator) void {
        self.contract.deinit(allocator);
        self.policy.deinit(allocator);
        self.* = undefined;
    }
};
