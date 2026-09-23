//! The outbound HTTP backend: `std.Io.Threaded` with its connect replaced by
//! one that obeys the fetch deadline.
//!
//! std cannot bound a connect or a TLS handshake itself. `ConnectTcpOptions`
//! declares a `timeout` that `std.http.Client.connectTcpOptions` never reads,
//! and the Threaded backend panics on a connect timeout. This backend connects
//! without blocking, waits with `poll` until the fetch deadline, and arms the
//! fetch's watchdog on the new socket before it returns, so std runs the TLS
//! handshake on a socket the watchdog already covers. The design and the
//! alternatives it rejected are in
//! `docs/plans/2026-09-23-m4-t1b-connect-deadline-design.md`.
//!
//! One fetch at a time per backend: a handler instance runs one request at a
//! time, and each `zttp:io` worker owns its own backend. The connects inside one
//! fetch can run at the same time, because `HostName.connect` tries every
//! resolved address at once on `Io` tasks. The first connect that succeeds
//! claims the watchdog; a later one closes its socket and reports a failure
//! that `HostName.connect` does not treat as fatal.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const Threaded = Io.Threaded;
const FetchDeadline = @import("fetch_deadline.zig").FetchDeadline;

const ConnectError = net.IpAddress.ConnectError;

pub const OutboundIo = struct {
    /// `io().userdata` points here, so every entry this type does not replace
    /// still receives the `*Threaded` it expects.
    threaded: Threaded,
    vtable: Io.VTable,
    base: *const Io.VTable,
    /// The fetch whose connect this backend is serving, from `beginFetch` to
    /// `endFetch`.
    fetch: ?*FetchDeadline = null,
    /// Set by the first connect of a fetch that succeeds.
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(gpa: std.mem.Allocator) OutboundIo {
        var threaded = Threaded.init(gpa, .{ .environ = .empty });
        const base = threaded.io().vtable;
        var vtable = base.*;
        vtable.netConnectIp = netConnectIp;
        vtable.netClose = netClose;
        return .{ .threaded = threaded, .vtable = vtable, .base = base };
    }

    pub fn deinit(self: *OutboundIo) void {
        self.threaded.deinit();
    }

    /// The returned `Io` points into `self`, which must not move while it is
    /// in use.
    pub fn io(self: *OutboundIo) Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    /// Fixes the end of the fetch and binds it to the connects that follow.
    /// Call it after name resolution, which this deadline does not bound.
    pub fn beginFetch(self: *OutboundIo, deadline: *FetchDeadline) error{ZeroTimeout}!void {
        try deadline.begin();
        self.claimed.store(false, .release);
        self.fetch = deadline;
    }

    /// Joins the watchdog, then unbinds the fetch. Run it before the client
    /// releases its connections, so no close can outlive the watchdog's view
    /// of the fd.
    pub fn endFetch(self: *OutboundIo) void {
        if (self.fetch) |deadline| deadline.disarm();
        self.fetch = null;
    }

    fn fromUserdata(userdata: ?*anyopaque) *OutboundIo {
        const threaded: *Threaded = @ptrCast(@alignCast(userdata));
        return @alignCast(@fieldParentPtr("threaded", threaded));
    }

    fn netConnectIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) ConnectError!net.Socket {
        const self = fromUserdata(userdata);
        // A connect with no fetch deadline would be unbounded: refuse it.
        const deadline = self.fetch orelse return error.OptionUnsupported;
        if (options.mode != .stream) return error.SocketModeUnsupported;

        const socket = try connectBounded(address, deadline);
        errdefer closeFd(socket.handle);
        // One watchdog per fetch. A concurrent attempt that lost the race is
        // not fatal to `HostName.connect`, which returns the winner.
        if (self.claimed.swap(true, .acq_rel)) return error.ConnectionPending;
        deadline.stream = .{ .socket = socket };
        deadline.arm() catch return error.SystemResources;
        return socket;
    }

    /// Joins an armed watchdog before its fd closes. std closes the fd itself
    /// when the TLS handshake fails, before the caller can disarm.
    fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
        const self = fromUserdata(userdata);
        if (self.fetch) |deadline| {
            if (deadline.isArmed()) {
                for (handles) |handle| {
                    if (handle == deadline.stream.socket.handle) {
                        deadline.disarm();
                        break;
                    }
                }
            }
        }
        self.base.netClose(userdata, handles);
    }
};

fn connectBounded(address: *const net.IpAddress, deadline: *const FetchDeadline) ConnectError!net.Socket {
    const socket_rc = posix.system.socket(Threaded.posixAddressFamily(address), posix.SOCK.STREAM, 0);
    switch (posix.errno(socket_rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
        else => return error.Unexpected,
    }
    const fd: posix.fd_t = @intCast(socket_rc);
    errdefer closeFd(fd);

    try fcntlSet(fd, posix.F.SETFD, posix.FD_CLOEXEC);
    const status_rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(status_rc) != .SUCCESS) return error.Unexpected;
    const blocking_flags: usize = @intCast(status_rc);
    const nonblock: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    try fcntlSet(fd, posix.F.SETFL, blocking_flags | nonblock);

    var storage: Threaded.PosixAddress = undefined;
    var addr_len = Threaded.addressToPosix(address, &storage);
    while (true) {
        switch (posix.errno(posix.system.connect(fd, &storage.any, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .INPROGRESS, .AGAIN => {
                try waitConnected(fd, deadline);
                break;
            },
            else => |err| return mapConnectErrno(err),
        }
    }

    // Blocking again: Threaded treats EAGAIN on a socket as a bug.
    try fcntlSet(fd, posix.F.SETFL, blocking_flags);

    switch (posix.errno(posix.system.getsockname(fd, &storage.any, &addr_len))) {
        .SUCCESS => {},
        .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
    return .{ .handle = fd, .address = Threaded.addressFromPosix(&storage) };
}

/// Waits for a non-blocking connect to finish, until the fetch deadline.
fn waitConnected(fd: posix.fd_t, deadline: *const FetchDeadline) ConnectError!void {
    while (true) {
        const remaining_ms = deadline.remainingMs();
        if (remaining_ms == 0) return error.Timeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        const rc = posix.system.poll(&fds, fds.len, remaining_ms);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return error.Timeout else break,
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }

    var so_error: i32 = 0;
    var len: posix.socklen_t = @sizeOf(i32);
    switch (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &so_error, &len))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    if (so_error != 0) return mapConnectErrno(@enumFromInt(so_error));
}

/// The same mapping Threaded's own connect uses, less the arms that report a
/// programmer bug there.
fn mapConnectErrno(err: posix.E) ConnectError {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        else => error.Unexpected,
    };
}

fn fcntlSet(fd: posix.fd_t, cmd: i32, arg: usize) ConnectError!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, cmd, arg))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}
