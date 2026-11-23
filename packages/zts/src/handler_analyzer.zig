//! HTTP Handler Pattern Analyzer
//!
//! Detects static response patterns at compile time and builds a fast dispatch table.
//! Enables native fast path for requests that bypass the bytecode interpreter entirely.
//!
//! Detectable patterns:
//! - `if (url === '/api/health') return Response.json({status: 'ok'})`
//! - `if (path === '/api/health') return Response.json({status: 'ok'})`
//! - `if (url.indexOf('/api/greet/') === 0) ...` (prefix match)
//! - `if (path.indexOf('/api/greet/') === 0) ...` (prefix match)

const std = @import("std");
const bytecode = @import("bytecode.zig");
const ir = @import("parser/ir.zig");
const object = @import("object.zig");
const context = @import("context.zig");

const HandlerPattern = bytecode.HandlerPattern;
const PatternDispatchTable = bytecode.PatternDispatchTable;
const PatternType = bytecode.PatternType;
const HandlerFlags = bytecode.HandlerFlags;
const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;

/// Handler analyzer state
pub const HandlerAnalyzer = struct {
    allocator: std.mem.Allocator,
    ir: IrView,
    atoms: ?*context.AtomTable,

    // Analysis state
    patterns: std.ArrayList(HandlerPattern),
    route_binding_slot: ?u16, // Local slot of `url` or `path` variable
    route_atom: object.Atom, // Which request field is bound (`url` or `path`)
    request_binding_slot: ?u16, // Local slot of request parameter

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
    ) HandlerAnalyzer {
        return .{
            .allocator = allocator,
            .ir = ir_view,
            .atoms = atoms,
            .patterns = .empty,
            .route_binding_slot = null,
            .route_atom = .url,
            .request_binding_slot = null,
        };
    }

    pub fn deinit(self: *HandlerAnalyzer) void {
        // Don't free patterns - they're transferred to the dispatch table
        self.patterns.deinit(self.allocator);
    }

    /// Main entry point: analyze a function for static handler patterns.
    /// Returns a dispatch table if patterns were found, null otherwise.
    pub fn analyze(self: *HandlerAnalyzer, func_node: NodeIndex) !?*PatternDispatchTable {
        const func = self.ir.getFunction(func_node) orelse return null;

        // Handler must have exactly 1 parameter (request)
        if (func.params_count != 1) return null;

        self.patterns.clearRetainingCapacity();
        self.route_binding_slot = null;
        self.route_atom = .url;
        self.request_binding_slot = null;

        self.findRequestBinding(func);

        // Find route binding in function body:
        //   const url = request.url
        //   const path = request.path
        self.findRouteBinding(func.body);
        if (self.route_binding_slot == null) return null;

        // Extract patterns from if-chain in function body
        try self.extractPatternsFromBlock(func.body);

        // Build dispatch table if we found any patterns
        if (self.patterns.items.len == 0) return null;

        const dispatch = try self.allocator.create(PatternDispatchTable);
        dispatch.* = PatternDispatchTable.init(self.allocator);

        // Transfer patterns
        dispatch.patterns = try self.allocator.dupe(HandlerPattern, self.patterns.items);

        // Build exact match hash map and pre-built responses for exact matches
        for (dispatch.patterns, 0..) |*pattern, i| {
            if (pattern.pattern_type == .exact) {
                const hash = std.hash.Wyhash.hash(0, pattern.url_bytes);
                try dispatch.exact_match_map.put(self.allocator, hash, @intCast(i));
                // Build pre-serialized full HTTP response for fast path
                try pattern.buildPrebuiltResponse(self.allocator);
            }
        }

        return dispatch;
    }

    /// Find `const route = request.url` or `const route = request.path` binding.
    fn findRequestBinding(self: *HandlerAnalyzer, func: Node.FunctionExpr) void {
        if (func.params_count == 0) return;
        const req_param = self.ir.getListIndex(func.params_start, 0);
        if (self.getBindableSlot(req_param)) |slot| {
            self.request_binding_slot = slot;
            return;
        }
        const req_tag = self.ir.getTag(req_param) orelse return;
        if (req_tag != .pattern_element) return;
        const elem = self.ir.getPatternElem(req_param) orelse return;
        if (bindingSlotIfBindable(elem.binding)) |slot| {
            self.request_binding_slot = slot;
        }
    }

    /// Find `const route = request.url` or `const route = request.path` binding.
    fn findRouteBinding(self: *HandlerAnalyzer, body_node: NodeIndex) void {
        const tag = self.ir.getTag(body_node) orelse return;

        if (tag == .block or tag == .program) {
            const block = self.ir.getBlock(body_node) orelse return;
            var i: u16 = 0;
            while (i < block.stmts_count) : (i += 1) {
                const stmt_idx = self.ir.getListIndex(block.stmts_start, i);
                self.findRouteBindingInStmt(stmt_idx);
                if (self.route_binding_slot != null) return;
            }
        }
    }

    fn findRouteBindingInStmt(self: *HandlerAnalyzer, stmt_node: NodeIndex) void {
        const tag = self.ir.getTag(stmt_node) orelse return;

        if (tag == .var_decl) {
            const decl = self.ir.getVarDecl(stmt_node) orelse return;

            // Check if init is a member access
            if (decl.init == null_node) return;
            const member = self.getMemberAccess(decl.init) orelse return;

            // Check if property is request.url or request.path
            if (member.property == @backingInt(object.Atom.url) or
                member.property == @backingInt(object.Atom.path))
            {
                // Route binding must come from request.url/path.
                if (!self.matchesOptionalSlot(member.object, self.request_binding_slot)) return;

                // This is `const route = something.url/path`
                // Store the binding slot
                const slot = bindingSlotIfBindable(decl.binding) orelse return;
                self.route_binding_slot = slot;
                self.route_atom = @fromBackingInt(@intCast(member.property));
            }
        }
    }

    /// Extract patterns from if-chain in a block
    fn extractPatternsFromBlock(self: *HandlerAnalyzer, body_node: NodeIndex) !void {
        const tag = self.ir.getTag(body_node) orelse return;

        if (tag == .block or tag == .program) {
            const block = self.ir.getBlock(body_node) orelse return;
            var i: u16 = 0;
            while (i < block.stmts_count) : (i += 1) {
                const stmt_idx = self.ir.getListIndex(block.stmts_start, i);
                try self.extractPatternFromStmt(stmt_idx);
            }
        }
    }

    /// Extract pattern from a single statement (`if` or `switch`).
    fn extractPatternFromStmt(self: *HandlerAnalyzer, stmt_node: NodeIndex) !void {
        const tag = self.ir.getTag(stmt_node) orelse return;

        switch (tag) {
            .if_stmt => try self.extractPatternFromIfStmt(stmt_node),
            .return_stmt => try self.extractPatternFromReturnMatch(stmt_node),
            else => return,
        }
    }

    fn extractPatternFromIfStmt(self: *HandlerAnalyzer, stmt_node: NodeIndex) !void {
        const if_stmt = self.ir.getIfStmt(stmt_node) orelse return;

        // Analyze condition for route pattern
        const route_pattern = self.analyzeCondition(if_stmt.condition) orelse return;

        // Analyze then branch for static response (exact matches)
        const static_response = try self.analyzeStaticReturn(if_stmt.then_branch);
        if (static_response == null) {
            self.allocator.free(route_pattern.url_bytes);
            return;
        }

        // Found a static pattern!
        const response = static_response.?;
        try self.patterns.append(self.allocator, .{
            .pattern_type = route_pattern.pattern_type,
            .url_atom = route_pattern.url_atom,
            .url_bytes = route_pattern.url_bytes,
            .static_body = response.body,
            .status = response.status,
            .content_type_idx = response.content_type_idx,
        });
    }

    fn extractPatternFromReturnMatch(self: *HandlerAnalyzer, stmt_node: NodeIndex) !void {
        // Check if this return statement returns a match expression
        const return_val = self.ir.getOptValue(stmt_node) orelse return;
        if (return_val == null_node) return;
        const val_tag = self.ir.getTag(return_val) orelse return;
        if (val_tag != .match_expr) return;

        const match_e = self.ir.getMatchExpr(return_val) orelse return;

        // Check if discriminant is the request binding
        const discr_tag = self.ir.getTag(match_e.discriminant) orelse return;
        if (discr_tag != .identifier) return;

        var i: u8 = 0;
        while (i < match_e.arms_count) : (i += 1) {
            const arm_idx = self.ir.getListIndex(match_e.arms_start, i);
            const arm = self.ir.getMatchArm(arm_idx) orelse continue;
            if (arm.pattern == null_node) continue; // default arm
            // Fluent arms evaluate callbacks under a selected pattern. The
            // native table only represents a static response keyed by URL.
            if (arm.kind != .value) return;

            const pattern_tag = self.ir.getTag(arm.pattern) orelse continue;

            if (pattern_tag == .match_pattern) {
                // Object pattern: extract method/path from properties
                try self.extractPatternFromMatchObject(arm.pattern, arm.body);
            } else if (pattern_tag == .lit_string) {
                // Literal pattern on request - treat as route match
                const route_info = self.analyzeSwitchCaseExact(arm.pattern) orelse continue;
                const response = (try self.analyzeResponseCall(arm.body)) orelse {
                    self.allocator.free(route_info.url_bytes);
                    continue;
                };
                try self.patterns.append(self.allocator, .{
                    .pattern_type = route_info.pattern_type,
                    .url_atom = route_info.url_atom,
                    .url_bytes = route_info.url_bytes,
                    .static_body = response.body,
                    .status = response.status,
                    .content_type_idx = response.content_type_idx,
                });
            }
        }
    }

    fn extractPatternFromMatchObject(self: *HandlerAnalyzer, pattern_node: NodeIndex, body: NodeIndex) !void {
        const pattern = self.ir.getMatchPattern(pattern_node) orelse return;
        var path_str: ?[]const u8 = null;

        // Scan every property (no early break): a `method` constraint may follow
        // the `path` key and must still veto the pattern.
        var j: u8 = 0;
        while (j < pattern.props_count) : (j += 1) {
            const prop_idx = self.ir.getListIndex(pattern.props_start, j);
            const prop = self.ir.getProperty(prop_idx) orelse continue;
            const key_str_idx = self.ir.getStringIdx(prop.key) orelse continue;
            const key_str = self.ir.getString(key_str_idx) orelse continue;

            if (std.mem.eql(u8, key_str, "method")) {
                // The native fast path matches on URL only. When an arm pins the
                // method (`{ method: "POST", ... }`), turning it into a URL-only
                // pattern would serve that arm's response to any method, diverging
                // from the interpreter which enforces the method. Decline to
                // fast-path it and let the bytecode path run the match.
                if (prop.value != null_node) {
                    const method_tag = self.ir.getTag(prop.value) orelse continue;
                    if (method_tag == .lit_string) return;
                }
            } else if (std.mem.eql(u8, key_str, "path") or std.mem.eql(u8, key_str, "url")) {
                if (prop.value != null_node) {
                    const val_tag = self.ir.getTag(prop.value) orelse continue;
                    if (val_tag == .lit_string) {
                        const val_str_idx = self.ir.getStringIdx(prop.value) orelse continue;
                        path_str = self.ir.getString(val_str_idx);
                    }
                }
            }
        }

        const route_str = path_str orelse return;
        const response = (try self.analyzeResponseCall(body)) orelse return;
        const url_bytes = self.allocator.dupe(u8, route_str) catch return;
        try self.patterns.append(self.allocator, .{
            .pattern_type = .exact,
            .url_atom = self.route_atom,
            .url_bytes = url_bytes,
            .static_body = response.body,
            .status = response.status,
            .content_type_idx = response.content_type_idx,
        });
    }

    fn analyzeSwitchCaseExact(self: *HandlerAnalyzer, test_expr: NodeIndex) ?UrlPatternInfo {
        const test_tag = self.ir.getTag(test_expr) orelse return null;
        if (test_tag != .lit_string) return null;
        const str_idx = self.ir.getStringIdx(test_expr) orelse return null;
        const route_str = self.ir.getString(str_idx) orelse return null;
        const url_bytes = self.allocator.dupe(u8, route_str) catch return null;
        return .{
            .pattern_type = .exact,
            .url_atom = self.route_atom,
            .url_bytes = url_bytes,
        };
    }

    const UrlPatternInfo = struct {
        pattern_type: PatternType,
        url_atom: object.Atom,
        url_bytes: []const u8,
    };

    fn getBindableSlot(self: *HandlerAnalyzer, node: NodeIndex) ?u16 {
        const tag = self.ir.getTag(node) orelse return null;
        if (tag != .identifier) return null;
        const binding = self.ir.getBinding(node) orelse return null;
        return bindingSlotIfBindable(binding);
    }

    fn getMemberAccess(self: *HandlerAnalyzer, node: NodeIndex) ?Node.MemberExpr {
        const tag = self.ir.getTag(node) orelse return null;
        if (tag != .member_access and tag != .optional_chain) return null;
        return self.ir.getMember(node);
    }

    fn matchesSlot(self: *HandlerAnalyzer, node: NodeIndex, slot: u16) bool {
        const binding = self.ir.getBinding(node) orelse return false;
        return binding.slot == slot;
    }

    fn matchesOptionalSlot(self: *HandlerAnalyzer, node: NodeIndex, maybe_slot: ?u16) bool {
        const slot = maybe_slot orelse return true;
        return self.matchesSlot(node, slot);
    }

    fn isGlobalIdentifier(self: *HandlerAnalyzer, node: NodeIndex, atom: object.Atom) bool {
        const tag = self.ir.getTag(node) orelse return false;
        if (tag != .identifier) return false;

        const binding = self.ir.getBinding(node) orelse return false;
        if (binding.kind != .global and binding.kind != .undeclared_global) return false;
        return binding.name_atom == @backingInt(atom);
    }

    /// Analyze condition for URL matching pattern
    fn analyzeCondition(self: *HandlerAnalyzer, cond_node: NodeIndex) ?UrlPatternInfo {
        const tag = self.ir.getTag(cond_node) orelse return null;

        if (tag == .binary_op) {
            const binary = self.ir.getBinary(cond_node) orelse return null;

            // Pattern 1: url === '/api/health'
            if (binary.op == .strict_eq) {
                const exact = self.analyzeExactMatch(binary);
                if (exact != null) return exact;
                // If exact match fails, try prefix match
                return self.analyzePrefixMatch(binary);
            }
        }

        return null;
    }

    /// Analyze `url === '/api/health'` pattern
    fn analyzeExactMatch(self: *HandlerAnalyzer, binary: Node.BinaryExpr) ?UrlPatternInfo {
        // Left side should be identifier (url)
        var url_side: NodeIndex = null_node;
        var str_side: NodeIndex = null_node;

        const left_tag = self.ir.getTag(binary.left);
        const right_tag = self.ir.getTag(binary.right);

        if (left_tag == .identifier and right_tag == .lit_string) {
            url_side = binary.left;
            str_side = binary.right;
        } else if (left_tag == .lit_string and right_tag == .identifier) {
            url_side = binary.right;
            str_side = binary.left;
        } else {
            return null;
        }

        // Verify route side matches the discovered route binding
        const binding = self.ir.getBinding(url_side) orelse return null;
        if (binding.slot != self.route_binding_slot.?) return null;

        // Get URL string
        const str_idx = self.ir.getStringIdx(str_side) orelse return null;
        const url_str = self.ir.getString(str_idx) orelse return null;

        // Duplicate the URL string for storage
        const url_bytes = self.allocator.dupe(u8, url_str) catch return null;

        return .{
            .pattern_type = .exact,
            .url_atom = self.route_atom,
            .url_bytes = url_bytes,
        };
    }

    /// Analyze `url.indexOf('/api/greet/') === 0` pattern
    fn analyzePrefixMatch(self: *HandlerAnalyzer, binary: Node.BinaryExpr) ?UrlPatternInfo {
        // Right side should be 0
        const right_tag = self.ir.getTag(binary.right) orelse return null;
        if (right_tag != .lit_int) return null;
        const right_val = self.ir.getIntValue(binary.right) orelse return null;
        if (right_val != 0) return null;

        // Left side should be call to indexOf
        const left_tag = self.ir.getTag(binary.left) orelse return null;
        if (left_tag != .call) return null;

        const call = self.ir.getCall(binary.left) orelse return null;
        if (call.args_count != 1) return null;

        // Callee should be member access
        const member = self.getMemberAccess(call.callee) orelse return null;

        // Property should be 'indexOf'
        if (member.property != @backingInt(object.Atom.indexOf)) return null;

        // Object should be the url identifier
        if (!self.matchesSlot(member.object, self.route_binding_slot.?)) return null;

        // Get the prefix string from the argument
        const arg_idx = self.ir.getListIndex(call.args_start, 0);
        const arg_tag = self.ir.getTag(arg_idx) orelse return null;
        if (arg_tag != .lit_string) return null;

        const str_idx = self.ir.getStringIdx(arg_idx) orelse return null;
        const prefix_str = self.ir.getString(str_idx) orelse return null;

        const url_bytes = self.allocator.dupe(u8, prefix_str) catch return null;

        return .{
            .pattern_type = .prefix,
            .url_atom = self.route_atom,
            .url_bytes = url_bytes,
        };
    }

    pub const StaticResponseInfo = struct {
        body: []const u8,
        status: u16,
        content_type_idx: u8,
    };

    const ResponseKind = enum {
        json_obj,
        raw_json,
        text,
        html,
    };

    /// Analyze then branch for static Response.json({...}) return
    fn analyzeStaticReturn(self: *HandlerAnalyzer, then_node: NodeIndex) !?StaticResponseInfo {
        const tag = self.ir.getTag(then_node) orelse return null;

        // Could be a block or direct return
        if (tag == .block) {
            const block = self.ir.getBlock(then_node) orelse return null;
            // Look for first return statement
            var i: u16 = 0;
            while (i < block.stmts_count) : (i += 1) {
                const stmt_idx = self.ir.getListIndex(block.stmts_start, i);
                const stmt_tag = self.ir.getTag(stmt_idx) orelse continue;
                if (stmt_tag == .return_stmt) {
                    return try self.analyzeReturnStmt(stmt_idx);
                }
            }
        } else if (tag == .return_stmt) {
            return try self.analyzeReturnStmt(then_node);
        }

        return null;
    }

    /// Analyze handler body for a direct static return (no if-chain)
    /// Returns null if the body is not a static Response.* return.
    pub fn analyzeDirectReturn(self: *HandlerAnalyzer, func_node: NodeIndex) !?StaticResponseInfo {
        const func = self.ir.getFunction(func_node) orelse return null;
        self.request_binding_slot = null;
        self.findRequestBinding(func);
        return try self.analyzeStaticReturn(func.body);
    }

    fn analyzeReturnStmt(self: *HandlerAnalyzer, return_node: NodeIndex) !?StaticResponseInfo {
        const return_val = self.ir.getOptValue(return_node) orelse return null;
        if (return_val == null_node) return null;

        return try self.analyzeResponseCall(return_val);
    }

    /// Analyze Response.json({...}), Response.rawJson("..."), Response.text("..."), or Response.html("...")
    fn analyzeResponseCall(self: *HandlerAnalyzer, call_node: NodeIndex) !?StaticResponseInfo {
        const tag = self.ir.getTag(call_node) orelse return null;
        if (tag != .call) return null;

        const call = self.ir.getCall(call_node) orelse return null;
        if (call.args_count < 1) return null;

        // Callee should be Response.json or Response.text
        const member = self.getMemberAccess(call.callee) orelse return null;
        if (!self.isGlobalIdentifier(member.object, object.Atom.Response)) return null;

        const response_kind: ResponseKind = if (member.property == @backingInt(object.Atom.json))
            .json_obj
        else if (member.property == @backingInt(object.Atom.rawJson))
            .raw_json
        else if (member.property == @backingInt(object.Atom.text))
            .text
        else if (member.property == @backingInt(object.Atom.html))
            .html
        else
            return null;

        const content_type_idx: u8 = switch (response_kind) {
            .text => 1,
            .html => 2,
            .json_obj, .raw_json => 0,
        };

        // Get the first argument
        const arg_idx = self.ir.getListIndex(call.args_start, 0);

        // Try to serialize the argument
        switch (response_kind) {
            .json_obj => {
                // Check for status in second arg (options object)
                var status: u16 = 200;
                if (call.args_count >= 2) {
                    const opts_idx = self.ir.getListIndex(call.args_start, 1);
                    status = self.extractStatusFromOptions(opts_idx) orelse 200;
                }

                // JSON - serialize object literal when possible.
                const body = try self.serializeObjectLiteral(arg_idx);
                if (body != null) {
                    return .{
                        .body = body.?,
                        .status = status,
                        .content_type_idx = content_type_idx,
                    };
                }

                return null;
            },
            .raw_json, .text, .html => {
                // Raw JSON/text/html - first arg must be a static string literal
                const arg_tag = self.ir.getTag(arg_idx) orelse return null;
                if (arg_tag != .lit_string) return null;

                const str_idx = self.ir.getStringIdx(arg_idx) orelse return null;
                const str = self.ir.getString(str_idx) orelse return null;
                const body = try self.allocator.dupe(u8, str);

                var status: u16 = 200;
                if (call.args_count >= 2) {
                    const opts_idx = self.ir.getListIndex(call.args_start, 1);
                    status = self.extractStatusFromOptions(opts_idx) orelse 200;
                }

                return .{
                    .body = body,
                    .status = status,
                    .content_type_idx = content_type_idx,
                };
            },
        }

        // Unreachable with current response_kind variants
        return null;
    }

    /// Extract status from options object: {status: 404}
    fn extractStatusFromOptions(self: *HandlerAnalyzer, opts_node: NodeIndex) ?u16 {
        const tag = self.ir.getTag(opts_node) orelse return null;
        if (tag != .object_literal) return null;

        const obj = self.ir.getObject(opts_node) orelse return null;

        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir.getTag(prop_idx) orelse continue;
            if (prop_tag != .object_property) continue;

            const prop = self.ir.getProperty(prop_idx) orelse continue;

            // Check if key is 'status'
            const key_tag = self.ir.getTag(prop.key) orelse continue;
            if (key_tag == .lit_string) {
                const key_str_idx = self.ir.getStringIdx(prop.key) orelse continue;
                const key_str = self.ir.getString(key_str_idx) orelse continue;
                if (std.mem.eql(u8, key_str, "status")) {
                    const val_tag = self.ir.getTag(prop.value) orelse continue;
                    if (val_tag == .lit_int) {
                        const val = self.ir.getIntValue(prop.value) orelse continue;
                        if (val >= 100 and val <= 599) {
                            return @intCast(val);
                        }
                    }
                }
            }
        }

        return null;
    }

    /// Serialize an object literal to JSON at compile time
    fn serializeObjectLiteral(self: *HandlerAnalyzer, node: NodeIndex) std.mem.Allocator.Error!?[]const u8 {
        const tag = self.ir.getTag(node) orelse return null;
        if (tag != .object_literal) return null;

        const obj = self.ir.getObject(node) orelse return null;

        var buf: std.ArrayList(u8) = .empty;
        // `defer` (not `errdefer`): several `return null` paths below bail when a
        // property value isn't statically serializable (e.g. a member access like
        // `forecast.latitude`). errdefer would skip those, leaking the partial
        // buffer. On success `toOwnedSlice` empties buf, so deinit is a no-op.
        defer buf.deinit(self.allocator);

        try buf.append(self.allocator, '{');

        var first = true;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir.getTag(prop_idx) orelse return null;
            if (prop_tag != .object_property) return null;

            const prop = self.ir.getProperty(prop_idx) orelse return null;

            // Get key
            const key_tag = self.ir.getTag(prop.key) orelse return null;
            if (key_tag != .lit_string) return null;
            const key_str_idx = self.ir.getStringIdx(prop.key) orelse return null;
            const key_str = self.ir.getString(key_str_idx) orelse return null;

            if (!first) {
                try buf.append(self.allocator, ',');
            }
            first = false;

            // Write key (with JSON escaping)
            try buf.append(self.allocator, '"');
            for (key_str) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                    '\n' => try buf.appendSlice(self.allocator, "\\n"),
                    '\r' => try buf.appendSlice(self.allocator, "\\r"),
                    '\t' => try buf.appendSlice(self.allocator, "\\t"),
                    else => try buf.append(self.allocator, c),
                }
            }
            try buf.appendSlice(self.allocator, "\":");

            // Serialize value
            const val_serialized = try self.serializeValue(prop.value);
            if (val_serialized == null) return null;
            try buf.appendSlice(self.allocator, val_serialized.?);
            self.allocator.free(val_serialized.?);
        }

        try buf.append(self.allocator, '}');

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Serialize a single value to JSON
    fn serializeValue(self: *HandlerAnalyzer, node: NodeIndex) std.mem.Allocator.Error!?[]const u8 {
        const tag = self.ir.getTag(node) orelse return null;

        switch (tag) {
            .lit_string => {
                const str_idx = self.ir.getStringIdx(node) orelse return null;
                const str = self.ir.getString(str_idx) orelse return null;

                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(self.allocator);

                try buf.append(self.allocator, '"');
                // Escape string
                for (str) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice(self.allocator, "\\\""),
                        '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                        '\n' => try buf.appendSlice(self.allocator, "\\n"),
                        '\r' => try buf.appendSlice(self.allocator, "\\r"),
                        '\t' => try buf.appendSlice(self.allocator, "\\t"),
                        else => try buf.append(self.allocator, c),
                    }
                }
                try buf.append(self.allocator, '"');

                return try buf.toOwnedSlice(self.allocator);
            },
            .lit_int => {
                const val = self.ir.getIntValue(node) orelse return null;
                var tmp_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp_buf, "{d}", .{val}) catch return null;
                return try self.allocator.dupe(u8, s);
            },
            .lit_bool => {
                const val = self.ir.getBoolValue(node) orelse return null;
                return try self.allocator.dupe(u8, if (val) "true" else "false");
            },
            .lit_null => {
                return try self.allocator.dupe(u8, "null");
            },
            .object_literal => {
                return try self.serializeObjectLiteral(node);
            },
            .array_literal => {
                return try self.serializeArrayLiteral(node);
            },
            else => return null,
        }
    }

    fn serializeArrayLiteral(self: *HandlerAnalyzer, node: NodeIndex) std.mem.Allocator.Error!?[]const u8 {
        const arr = self.ir.getArray(node) orelse return null;

        var buf: std.ArrayList(u8) = .empty;
        // `defer` (not `errdefer`): the `return null` below bails when an element
        // isn't statically serializable, which errdefer would skip and leak. On
        // success `toOwnedSlice` empties buf, so deinit is a no-op.
        defer buf.deinit(self.allocator);

        try buf.append(self.allocator, '[');

        var i: u16 = 0;
        while (i < arr.elements_count) : (i += 1) {
            if (i > 0) {
                try buf.append(self.allocator, ',');
            }
            const elem_idx = self.ir.getListIndex(arr.elements_start, i);
            const elem_serialized = try self.serializeValue(elem_idx);
            if (elem_serialized == null) return null;
            try buf.appendSlice(self.allocator, elem_serialized.?);
            self.allocator.free(elem_serialized.?);
        }

        try buf.append(self.allocator, ']');

        return try buf.toOwnedSlice(self.allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HandlerAnalyzer init and deinit" {
    const allocator = std.testing.allocator;

    var nodes = ir.IRStore.init(allocator);
    defer nodes.deinit();

    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();

    const ir_view = ir.IrView.fromIRStore(&nodes, &constants);

    var analyzer = HandlerAnalyzer.init(allocator, ir_view, null);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.route_binding_slot == null);
}

fn bindingSlotIfBindable(binding: anytype) ?u16 {
    return switch (binding.kind) {
        .local, .argument => binding.slot,
        else => null,
    };
}
