//! Multi-File Module Compiler
//!
//! Compiles all modules in a dependency graph with shared AtomTable and StringTable.
//! Atom consistency is guaranteed because all files share the same tables:
//! `put_global(atom)` in file A matches `get_global(atom)` in file B.

const std = @import("std");
const module_graph = @import("module_graph.zig");
const zts_parser = @import("../../parser/root.zig");
const context = @import("../../context.zig");
const string = @import("../../string.zig");
const bytecode = @import("../../bytecode.zig");
const object = @import("../../object.zig");

pub const CompiledModule = struct {
    func: bytecode.FunctionBytecode,
    shapes: []const []const object.Atom,
    local_count: u8,
    constants: []const @import("../../value.zig").JSValue,
    root: zts_parser.NodeIndex,
};

pub const ModuleCompiler = struct {
    allocator: std.mem.Allocator,
    atoms: *context.AtomTable,
    strings: *string.StringTable,

    pub fn init(
        allocator: std.mem.Allocator,
        atoms: *context.AtomTable,
        strings: *string.StringTable,
    ) ModuleCompiler {
        return .{
            .allocator = allocator,
            .atoms = atoms,
            .strings = strings,
        };
    }

    /// Compile all modules in the graph's execution order.
    /// Returns a list of CompiledModule structs. The caller must manage
    /// the lifetime of the underlying parser/codegen state through the
    /// returned ParserState handles.
    ///
    /// Each module is compiled independently but shares the same atom table,
    /// so global variable references are consistent across modules.
    pub fn compileAll(
        self: *ModuleCompiler,
        graph: *module_graph.ModuleGraph,
    ) !CompileResult {
        const count = graph.execution_order.len;
        const compiled = try self.allocator.alloc(CompiledModule, count);
        errdefer self.allocator.free(compiled);
        const parsers = try self.allocator.alloc(zts_parser.JsParser, count);
        errdefer self.allocator.free(parsers);
        const codegens = try self.allocator.alloc(zts_parser.CodeGen, count);
        errdefer self.allocator.free(codegens);
        var completed: usize = 0;
        errdefer {
            for (codegens[0..completed]) |*cg| {
                cg.freeOwnedConstantPayloads();
                cg.deinit();
            }
            for (parsers[0..completed]) |*parser| parser.deinit();
        }
        for (graph.execution_order, 0..) |mod_idx, index| {
            const module = &graph.module_list.items[mod_idx];
            const parser = &parsers[index];
            parser.* = try module.initParser(self.allocator);
            errdefer parser.deinit();
            parser.setAtomTable(self.atoms);
            const root = module.parse(parser) catch |err| {
                if (!@import("builtin").is_test) std.log.err("Parse error in module '{s}': {}", .{ module.path, err });
                var err_buf: [1024]u8 = undefined;
                const formatted = parser.errors.formatFirstError(&err_buf);
                if (formatted.len > 0) if (!@import("builtin").is_test) std.log.err("{s}", .{formatted});
                return err;
            };
            if (module.source_profile == .direct) {
                try parser.type_store.validateRuntimeOwners(self.allocator, zts_parser.IrView.fromIRStore(&parser.nodes, &parser.constants));
            }
            const cg = &codegens[index];
            cg.* = zts_parser.CodeGen.initWithIRStore(self.allocator, &parser.nodes, &parser.constants, &parser.scopes, self.strings, self.atoms);
            errdefer {
                cg.freeOwnedConstantPayloads();
                cg.deinit();
            }
            const func = cg.generate(root) catch |err| {
                if (!@import("builtin").is_test) std.log.err("Codegen error in module '{s}': {}", .{ module.path, err });
                return err;
            };
            compiled[index] = .{
                .func = func,
                .shapes = cg.shapes.items,
                .local_count = @intCast(func.local_count),
                .constants = func.constants,
                .root = root,
            };
            completed += 1;
        }
        return .{ .modules = compiled, .parsers = parsers, .codegens = codegens, .allocator = self.allocator };
    }
};

/// Result of compiling all modules. Owns the parser/codegen state that
/// bytecode slices borrow from. Must be deinitialized when done.
pub const CompileResult = struct {
    modules: []CompiledModule,
    parsers: []zts_parser.JsParser,
    codegens: []zts_parser.CodeGen,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompileResult) void {
        for (self.codegens) |*cg| cg.deinit();
        self.allocator.free(self.codegens);
        for (self.parsers) |*p| p.deinit();
        self.allocator.free(self.parsers);
        self.allocator.free(self.modules);
    }
};

test "compileAll returns a clean error instead of panicking when parser-init allocation fails" {
    const allocator = std.testing.allocator;

    var graph = module_graph.ModuleGraph.init(allocator);
    defer graph.deinit();

    try graph.module_list.append(allocator, .{
        .path = try allocator.dupe(u8, "entry.ts"),
        .source = try allocator.dupe(u8, "const x = 1;"),
        .source_profile = .raw,
        .dependencies = &.{},
        .state = .visited,
    });
    graph.execution_order = try allocator.dupe(module_graph.ModuleIndex, &.{0});

    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = string.StringTable.init(allocator);
    defer strings.deinit();

    // Three final slices precede parser initialization.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 3 });
    var module_compiler = ModuleCompiler.init(failing.allocator(), &atoms, &strings);

    try std.testing.expectError(error.OutOfMemory, module_compiler.compileAll(&graph));
}

test "selected graph profiles preserve reads bytecode and complete atoms" {
    const allocator = std.testing.allocator;
    const BytecodeExpectation = struct {
        len: usize,
        sha256: []const u8,
    };
    const Case = struct {
        entry: []const u8,
        dependency: ?[]const u8 = null,
        entry_profile: module_graph.Module.SourceProfile,
        dependency_profile: module_graph.Module.SourceProfile = .direct,
        reads: usize,
        parse_error: ?anyerror = null,
        bytecode: []const BytecodeExpectation = &.{},
        atom_names: []const []const u8 = &.{},
    };
    const cases = [_]Case{
        .{ .entry = "import { value } from \"./dep.ts\"; /* unfinished\n", .dependency = "export const value = 1;\n", .entry_profile = .raw, .reads = 1, .bytecode = &.{
            .{ .len = 51, .sha256 = "aa6352585d0b7732aa25aefee8d07a573c4c62c9aa0ed3ebdc29377fc89e27c6" },
            .{ .len = 53, .sha256 = "a18994befbbfb3e5240251fef74d30491434ffdb9d3991b9299412834ae84636" },
        }, .atom_names = &.{"existing_prefix"} },
        .{ .entry = "import { value } from \"./dep.ts\"; export const result = value;\n", .dependency = "export const value = 1; /* unfinished\n", .entry_profile = .direct, .dependency_profile = .raw, .reads = 1, .bytecode = &.{
            .{ .len = 51, .sha256 = "aa6352585d0b7732aa25aefee8d07a573c4c62c9aa0ed3ebdc29377fc89e27c6" },
            .{ .len = 84, .sha256 = "66b7fd09c12f1f05040a1c27d93f5a1461020411d67a1802670ccbfe19338b04" },
        }, .atom_names = &.{ "existing_prefix", "result" } },
        .{ .entry = "import { value } from \"./dep.ts\"; /* closed */\n", .dependency = "export const value = 1; /* closed */\n", .entry_profile = .direct, .reads = 1, .bytecode = &.{
            .{ .len = 51, .sha256 = "aa6352585d0b7732aa25aefee8d07a573c4c62c9aa0ed3ebdc29377fc89e27c6" },
            .{ .len = 53, .sha256 = "a18994befbbfb3e5240251fef74d30491434ffdb9d3991b9299412834ae84636" },
        }, .atom_names = &.{"existing_prefix"} },
        .{ .entry = "/*\n", .entry_profile = .raw, .reads = 0, .bytecode = &.{.{ .len = 42, .sha256 = "2c78e9e9d91bb19892b64a6cfa0e59415c64094ea7352143f03170af42897e10" }}, .atom_names = &.{"existing_prefix"} },
        .{ .entry = "import { value } from \"./dep.ts\"; /* unfinished", .dependency = "export const value = 1;\n", .entry_profile = .raw, .reads = 0, .parse_error = error.MissingSemicolon },
        .{ .entry = "import { value } from \"./dep.ts\"; export const result = value;\n", .dependency = "export const value = 1; /* unfinished", .entry_profile = .direct, .dependency_profile = .raw, .reads = 1, .parse_error = error.MissingSemicolon },
        .{ .entry = "/*", .entry_profile = .raw, .reads = 0, .bytecode = &.{.{ .len = 42, .sha256 = "2c78e9e9d91bb19892b64a6cfa0e59415c64094ea7352143f03170af42897e10" }}, .atom_names = &.{"existing_prefix"} },
        .{ .entry = "import { value } from \"./dep.ts\"; export const result = value;\n", .dependency = "export const value: number = 1; /* unfinished\n", .entry_profile = .direct, .dependency_profile = .raw, .reads = 1, .parse_error = error.MissingSemicolon },
        .{ .entry = "import { value } from \"./dep.ts\"; export const result = value;\n", .dependency = "const marker: \"open\n = \"open\"; export const value = 1;\n", .entry_profile = .direct, .reads = 1, .bytecode = &.{
            .{ .len = 89, .sha256 = "ecb3ef0fc0786551d6cd77934550dd9c5626190474e4ecfe8cb0e9dcfa9568a9" },
            .{ .len = 84, .sha256 = "a387c5d27495651f6d7b988fc430052958ce145a8e10175203148d20ceb491e7" },
        }, .atom_names = &.{ "existing_prefix", "marker", "result" } },
    };
    const Reader = struct {
        var source: ?[]const u8 = null;
        var reads: usize = 0;
        fn read(a: std.mem.Allocator, path: []const u8) module_graph.ReadFileError![]const u8 {
            if (!std.mem.eql(u8, "/probe/dep.ts", path)) return error.FileNotFound;
            reads += 1;
            return a.dupe(u8, source orelse return error.FileNotFound);
        }
    };
    try std.testing.expectEqual(@as(usize, 9), cases.len);
    for (cases) |case| {
        Reader.source = case.dependency;
        Reader.reads = 0;
        var graph = module_graph.ModuleGraph.init(allocator);
        defer graph.deinit();
        try graph.build("/probe/entry.ts", case.entry, Reader.read);
        try std.testing.expectEqual(case.reads, Reader.reads);
        try std.testing.expectEqual(case.entry_profile, graph.module_list.items[0].source_profile);
        try std.testing.expectEqual(case.reads + 1, graph.module_list.items.len);
        if (case.reads != 0) {
            try std.testing.expectEqual(case.dependency_profile, graph.module_list.items[1].source_profile);
            try std.testing.expectEqualSlices(module_graph.ModuleIndex, &.{ 1, 0 }, graph.execution_order);
            try std.testing.expectEqualSlices(module_graph.ModuleIndex, &.{1}, graph.module_list.items[0].dependencies);
        } else try std.testing.expectEqualSlices(module_graph.ModuleIndex, &.{0}, graph.execution_order);
        if (case.parse_error) |expected| {
            const failed_index: usize = if (case.reads != 0) 1 else 0;
            const module = &graph.module_list.items[failed_index];
            var parser = try module.initParser(allocator);
            defer parser.deinit();
            try std.testing.expectError(expected, module.parse(&parser));
            var atoms = context.AtomTable.init(allocator);
            defer atoms.deinit();
            _ = try atoms.intern("existing_prefix");
            var strings = string.StringTable.init(allocator);
            defer strings.deinit();
            var compiler = ModuleCompiler.init(allocator, &atoms, &strings);
            try std.testing.expectError(expected, compiler.compileAll(&graph));
            continue;
        }
        var atoms = context.AtomTable.init(allocator);
        defer atoms.deinit();
        _ = try atoms.intern("existing_prefix");
        var strings = string.StringTable.init(allocator);
        defer strings.deinit();
        var compiler = ModuleCompiler.init(allocator, &atoms, &strings);
        Reader.source = "export const value = 999;\n";
        var actual = try compiler.compileAll(&graph);
        defer actual.deinit();
        defer for (actual.codegens) |*cg| cg.freeOwnedConstantPayloads();
        try std.testing.expectEqual(case.reads, Reader.reads);
        try std.testing.expectEqual(case.atom_names.len, atoms.next_id - object.Atom.FIRST_DYNAMIC);
        for (case.atom_names, object.Atom.FIRST_DYNAMIC..) |name, id| {
            try std.testing.expectEqualStrings(name, atoms.getName(@enumFromInt(id)).?);
        }
        try std.testing.expect(graph.execution_order.len > 0);
        try std.testing.expectEqual(graph.execution_order.len, actual.modules.len);
        try std.testing.expectEqual(case.bytecode.len, actual.modules.len);
        for (actual.modules, actual.parsers, actual.codegens, case.bytecode) |*module, *parser, *cg, expected| {
            try std.testing.expect(cg.scopes == &parser.scopes);
            try std.testing.expect(cg.ir.ir_constants == &parser.constants);
            try std.testing.expect(cg.ir.impl.ir_store == &parser.nodes);
            var buffer: [4096]u8 = undefined;
            const cache = @import("../../bytecode_cache.zig");
            var writer = cache.SliceWriter{ .buffer = &buffer };
            try cache.serializeBytecodeWithAtomsAndShapes(&module.func, &atoms, module.shapes, &writer, allocator);
            try std.testing.expectEqual(expected.len, writer.getWritten().len);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(writer.getWritten(), &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            try std.testing.expectEqualStrings(expected.sha256, &hex);
        }
    }
}

test "ordered compilation allocation failures release completed owners" {
    const allocator = std.testing.allocator;
    const Reader = struct {
        fn read(a: std.mem.Allocator, _: []const u8) module_graph.ReadFileError![]const u8 {
            return a.dupe(u8, "export const helper = () => 1.25;\n");
        }
    };
    var graph = module_graph.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build("/probe/entry.ts", "import { helper } from \"./dep.ts\"; const result: number = helper(); const tail = 3.75;\n", Reader.read);
    const Run = struct {
        fn compile(graph_owner: *module_graph.ModuleGraph, failing: *std.testing.FailingAllocator, after_progress: *usize, after_dependency: *usize) !void {
            var atoms = context.AtomTable.init(std.testing.allocator);
            defer atoms.deinit();
            _ = try atoms.intern("existing_prefix");
            const prefix = atoms.next_id;
            var strings = string.StringTable.init(std.testing.allocator);
            defer strings.deinit();
            var compiler = ModuleCompiler.init(failing.allocator(), &atoms, &strings);
            var result = compiler.compileAll(graph_owner) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
                if (atoms.next_id > prefix) after_progress.* += 1;
                if (atoms.strings.contains("tail")) after_dependency.* += 1;
                return error.OutOfMemory;
            };
            defer result.deinit();
            defer for (result.codegens) |*cg| cg.freeOwnedConstantPayloads();
            try std.testing.expectEqual(@as(usize, 2), result.modules.len);
            try std.testing.expect(atoms.next_id > prefix);
        }
    };
    var progress: usize = 0;
    var dependency_progress: usize = 0;
    var calibration = std.testing.FailingAllocator.init(allocator, .{});
    try Run.compile(&graph, &calibration, &progress, &dependency_progress);
    try std.testing.expect(calibration.alloc_index > 0);
    var failures: usize = 0;
    for (0..calibration.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = index });
        Run.compile(&graph, &failing, &progress, &dependency_progress) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        };
    }
    try std.testing.expect(failures > 0);
    try std.testing.expect(progress > 0);
    try std.testing.expect(dependency_progress > 0);
}
