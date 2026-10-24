const std = @import("std");

// Stream writes through the supplied descriptor and preserve write errors.
pub const FdWriter = struct {
    interface: std.Io.Writer,
    fd: c_int,

    pub fn init(fd: c_int, buffer: []u8) FdWriter {
        return .{
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
            .fd = fd,
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);

        // Flush pre-buffered bytes first. The Io.Writer contract lets us
        // fully consume buffer[0..end] before the data slices.
        const buffered_bytes = w.buffer[0..w.end];
        if (buffered_bytes.len > 0) {
            try writeFd(self.fd, buffered_bytes);
            w.end = 0;
        }

        if (data.len == 0) return 0;

        // Write all but the last element once.
        var written: usize = 0;
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 1) {
            try writeFd(self.fd, data[i]);
            written += data[i].len;
        }

        // The last element is repeated `splat` times.
        const tail = data[data.len - 1];
        var remaining = splat;
        while (remaining > 0) : (remaining -= 1) {
            try writeFd(self.fd, tail);
            written += tail.len;
        }
        return written;
    }

    fn writeFd(fd: c_int, bytes: []const u8) std.Io.Writer.Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const rest = bytes[offset..];
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }
};
