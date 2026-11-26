//! Full-write POSIX descriptor helper for Pi terminal and stderr output.

const std = @import("std");

/// Write all bytes to `fd`, retrying on EINTR and continuing across short
/// writes. Fatal write errors stop output instead of panicking terminal UI paths.
pub fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rest = bytes[offset..];
        const written = std.c.write(fd, rest.ptr, rest.len);
        if (written < 0) {
            if (std.posix.errno(written) == .INTR) continue;
            return;
        }
        if (written == 0) return;
        offset += @intCast(written);
    }
}
