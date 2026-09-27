pub fn check(ok: bool) void {
    @setRuntimeSafety(true);
    if (!ok) @panic("proof-checker invariant violated");
}

test "check accepts a true invariant" {
    check(true);
}
