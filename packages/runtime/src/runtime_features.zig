const options = @import("runtime_feature_options");

pub const live_reload = if (options.enable_live_reload)
    @import("live_reload.zig")
else
    @import("live_reload_stub.zig");
