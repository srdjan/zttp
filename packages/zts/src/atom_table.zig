//! Dynamic atom table: string interning with an O(1) reverse lookup.
//!
//! Lives outside context.zig so the parser, the code generator, and the
//! analyzers (flow, effect, path, contract) can intern names without
//! importing the runtime `Context` they never touch. `context.AtomTable`
//! stays as a re-export, so existing call sites are unaffected.

const std = @import("std");
const object = @import("object.zig");

/// Dynamic atom table with O(1) reverse lookup
pub const AtomTable = struct {
    strings: std.StringHashMap(object.Atom),
    reverse: std.AutoHashMap(object.Atom, []const u8), // O(1) reverse lookup
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AtomTable {
        return .{
            .strings = std.StringHashMap(object.Atom).init(allocator),
            .reverse = std.AutoHashMap(object.Atom, []const u8).init(allocator),
            .next_id = object.Atom.FIRST_DYNAMIC,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtomTable) void {
        // Free owned key storage from the reverse map. The string-key map uses
        // those same slices for lookup, but the reverse map is the canonical
        // atom->name store we query during runtime.
        var it = self.reverse.valueIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.deinit();
        self.reverse.deinit();
    }

    /// Intern a string and get its atom
    pub fn intern(self: *AtomTable, s: []const u8) !object.Atom {
        if (object.lookupPredefinedAtom(s)) |predef| {
            return predef;
        }
        if (self.strings.get(s)) |existing| {
            return existing;
        }

        // Dynamic atom ids must stay below the reserved hidden-class transition
        // sentinels 0xFFFE/0xFFFF (HiddenClassPool.getOrCreateFunctionClass keys
        // its transition with atom 0xFFFE; http.zig skips atoms >= 0xFFFE as
        // reserved). Fail closed rather than let the 65293rd distinct interned
        // name alias a sentinel and silently corrupt an object's shape layout.
        if (self.next_id >= 0xFFFE) return error.OutOfMemory;
        const atom: object.Atom = @enumFromInt(self.next_id);
        const key = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(key);

        try self.strings.put(key, atom);
        errdefer _ = self.strings.remove(key);

        try self.reverse.put(atom, key);
        self.next_id += 1;

        return atom;
    }

    /// Prune unused atoms during major GC
    /// Takes a set of atoms that are still in use (referenced by live objects)
    pub fn pruneUnused(self: *AtomTable, used_atoms: *const std.AutoHashMap(object.Atom, void)) void {
        // Build list of atoms to remove (can't mutate maps during iteration).
        var atoms_to_remove: std.ArrayList(object.Atom) = .empty;
        defer atoms_to_remove.deinit(self.allocator);

        var it = self.reverse.iterator();
        while (it.next()) |entry| {
            const atom = entry.key_ptr.*;
            // Keep predefined atoms (they're always in use)
            if (atom.isPredefined()) continue;

            // Check if this dynamic atom is still referenced
            if (!used_atoms.contains(atom)) {
                atoms_to_remove.append(self.allocator, atom) catch continue;
            }
        }

        // Remove unreferenced atoms from both maps
        for (atoms_to_remove.items) |atom| {
            const key = self.reverse.get(atom) orelse continue;
            _ = self.strings.remove(key);
            _ = self.reverse.remove(atom);
            self.allocator.free(key);
        }
    }

    /// Reset atom table to initial state (for request isolation)
    pub fn reset(self: *AtomTable) void {
        var it = self.reverse.valueIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.clearRetainingCapacity();
        self.reverse.clearRetainingCapacity();
        self.next_id = object.Atom.FIRST_DYNAMIC;
    }

    /// Get current atom count (for monitoring)
    pub fn count(self: *AtomTable) usize {
        return self.strings.count();
    }

    /// Get string name for an atom - O(1) using reverse lookup map
    pub fn getName(self: *AtomTable, atom: object.Atom) ?[]const u8 {
        // Check predefined atoms first (already O(1) via switch)
        if (atom.isPredefined()) {
            return atom.toPredefinedName();
        }
        // O(1) lookup for dynamic atoms
        return self.reverse.get(atom);
    }
};

test "AtomTable getName" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    const atom = try atoms.intern("testName");
    const name = atoms.getName(atom);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("testName", name.?);
}

test "AtomTable count" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    try std.testing.expectEqual(@as(usize, 0), atoms.count());

    _ = try atoms.intern("first");
    try std.testing.expectEqual(@as(usize, 1), atoms.count());

    _ = try atoms.intern("second");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());

    // Interning same string shouldn't increase count
    _ = try atoms.intern("first");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());
}

test "AtomTable reset" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    _ = try atoms.intern("one");
    _ = try atoms.intern("two");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());

    atoms.reset();
    try std.testing.expectEqual(@as(usize, 0), atoms.count());
}
