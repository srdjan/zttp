//! Stand-in for the acceptance kernel in the release probe: a separate module
//! whose function enables runtime safety in its own body, as every kernel
//! function does. The probe imports it from a ReleaseFast root, which is the
//! shape of the shipped binaries.

pub fn indexAt(bytes: []const u8, index: usize) u8 {
    @setRuntimeSafety(true);
    return bytes[index];
}
