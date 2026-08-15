# API Reference: Zig Embedding & Advanced Configuration

This document covers advanced server configuration and extending zttp with native Zig functions. For handler JavaScript API, CLI options, and virtual modules, see [User Guide](../user-guide.md).

## Advanced Server Configuration (Zig API)

If you embed `Server` directly in Zig code, these `ServerConfig` fields tune performance features:

```zig
const std = @import("std");
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const ServerConfig = server_mod.ServerConfig;

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    const config = ServerConfig{
        // Handler source. Required: the field has no default.
        .handler = .{ .file_path = "handler.ts" },

        // Pool configuration
        .pool_size = 16,                        // Handler pool size (0 = auto)
        .pool_wait_timeout_ms = 5000,           // Max wait for available handler (ms)

        // Static file cache configuration
        .static_cache_max_bytes = 1024 * 1024,         // Max total cache size (default: 1MB)
        .static_cache_max_file_size = 64 * 1024,       // Max individual file size (default: 64KB)

        // Network configuration
        .port = 8080,
        .host = "127.0.0.1",
        .max_body_size = 1024 * 1024,           // Decoded request body cap

        // Logging
        .log_requests = true,                   // Enable request logging

        // Features
        .static_dir = null,                     // Static file directory
    };
    // For CORS, import `cors` from the `zttp:http` virtual module in the handler.

    var server = try Server.init(allocator, config);
    defer server.deinit();

    try server.run();
}
```

`HandlerSource` is a union: `.inline_code`, `.file_path`, `.embedded_bytecode`
(from `-Dhandler=`), and `.appended_payload` (from a self-extracting binary).

### Configuration Fields

#### Pool Configuration

**`pool_size`** (default: auto = 2 * cpu_count, min 8) - Number of pre-allocated handler contexts. Memory scales linearly with pool size.

**`pool_wait_timeout_ms`** (default: 5000) - Maximum time to wait for available handler (milliseconds). Returns 503 if timeout exceeded.


#### Static File Cache

**`static_cache_max_bytes`** (default: 1MB) - Maximum total cache size. LRU eviction when exceeded.

**`static_cache_max_file_size`** (default: 64KB) - Files larger than this are served directly from disk.

## Extending with Native Functions

Add custom native functions callable from JavaScript by implementing the `NativeFn` signature:

### Native Function Signature

```zig
pub const NativeFn = *const fn (ctx: *anyopaque, this: JSValue, args: []const JSValue) anyerror!JSValue;
```

The first parameter is erased to `*anyopaque` so `object.zig` does not have to
import `Context`. Cast it back with `@ptrCast(@alignCast(ctx))` when you need
the context.

### Example: Custom Math Function

```zig
const zts = @import("zts");

fn mySquare(_: *anyopaque, _: zts.JSValue, args: []const zts.JSValue) anyerror!zts.JSValue {
    if (args.len < 1 or !args[0].isInt()) return zts.JSValue.undefined_val;
    const n = args[0].getInt();
    return zts.JSValue.fromInt(n * n);
}

pub fn registerCustomFunctions(ctx: *zts.Context) !void {
    const name = try ctx.atoms.intern("square");
    try ctx.registerGlobalFunction(name, mySquare, 1);
}
```

`registerGlobalFunction` takes an `Atom`, not a string. Predefined names are
enum members (`.abs`, `.max`); anything else is interned first. `Atom` is
non-exhaustive and dynamic atoms start at `Atom.FIRST_DYNAMIC`.

Usage in JavaScript:

```javascript
function handler(request) {
    const x = square(5);  // Returns 25
    return Response.json({ result: x });
}
```

### Value Conversion

`JSValue` is NaN-boxed. Reads are tag checks followed by an unchecked getter,
not coercions: there is no `toNumber` or `toString` that converts across types
the way the JavaScript abstract operations do.

```zig
// Inspect
if (v.isInt()) { const n: i32 = v.getInt(); }
if (v.isFloat64()) { const f: f64 = v.getFloat64(); }
if (v.isBool()) { const b: bool = v.getBool(); }
if (v.isNullish()) { ... }              // null or undefined
if (v.isString()) { ... }

// Construct
const num = zts.JSValue.fromInt(42);
const float = zts.JSValue.fromFloat(3.14);
const true_val = zts.JSValue.fromBool(true);
const nul = zts.JSValue.null_val;       // constant, not a call
const undef = zts.JSValue.undefined_val;
const str = try ctx.createString("hello");

const obj = try ctx.createObject(null); // takes an optional prototype
```

`toConditionBool()` is the one conversion the engine exposes, and it is the
sound-mode truthiness rule rather than JavaScript's: it returns `null` for a
value with no falsy state instead of coercing it. See
[Sound Mode](../sound-mode.md).

### Error Handling

A native function reports failure through the Zig error union. To surface a JS
exception instead, set it on the context and return the exception sentinel:

```zig
fn mayFail(ctx_ptr: *anyopaque, _: zts.JSValue, args: []const zts.JSValue) anyerror!zts.JSValue {
    const ctx: *zts.Context = @ptrCast(@alignCast(ctx_ptr));
    if (args.len < 1 or !args[0].isInt()) {
        ctx.throwException(try ctx.createString("expected one integer"));
        return zts.JSValue.exception_val;
    }
    return zts.JSValue.fromInt(args[0].getInt());
}
```

### Best Practices

1. **Always use errdefer**: Clean up resources on error paths
2. **Validate arguments**: Check argument count and tags before reading a value
3. **Use appropriate allocators**: Request-scoped allocations should use the context's arena allocator (no manual free needed)
4. **Handle null and undefined**: Check `isNullish()` before reading

### Build-Time Handler Precompilation

Compile handlers at build time for fastest cold starts:

```bash
zig build -Doptimize=ReleaseFast -Dhandler=examples/handler/handler.ts
```

This embeds bytecode directly in the binary, eliminating all runtime parsing.
