//! Cold-path arithmetic helpers. The hot integer
//! fast paths and `allocFloat` wrapper live in interpreter.zig so dispatch
//! keeps inlining them; everything here is `@branchHint(.cold)`.

const std = @import("std");
const value = @import("../value.zig");
const interpreter = @import("../interpreter.zig");
const trace = @import("trace.zig");
const Interpreter = interpreter.Interpreter;

pub fn addValuesSlow(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    @branchHint(.cold);
    // Numeric slow path. String addition is refused by the frontend and fails
    // closed here if malformed or stale bytecode reaches the interpreter.
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "add(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "add(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(an + bn);
}

/// Slow path for the `add_num` opcode: skips the string-concat dispatch.
pub fn addNumericOnly(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    @branchHint(.cold);
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "add_num(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "add_num(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(an + bn);
}

pub fn subValuesSlow(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    @branchHint(.cold);
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "sub(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "sub(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(an - bn);
}

pub fn mulValuesSlow(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    @branchHint(.cold);
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "mul(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "mul(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(an * bn);
}

pub inline fn divValues(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "div(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "div(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(an / bn);
}

pub inline fn powValues(interp: *Interpreter, a: value.JSValue, b: value.JSValue) !value.JSValue {
    const an = a.toNumber() orelse {
        trace.traceTypeError(interp, "pow(a)", a, b);
        return error.TypeError;
    };
    const bn = b.toNumber() orelse {
        trace.traceTypeError(interp, "pow(b)", a, b);
        return error.TypeError;
    };
    return try interp.allocFloat(std.math.pow(f64, an, bn));
}

pub inline fn negValue(interp: *Interpreter, a: value.JSValue) !value.JSValue {
    if (a.isInt()) {
        const v = a.getInt();
        if (v == std.math.minInt(i32)) {
            // -minInt overflows i32; promote to float.
            return try interp.allocFloat(-@as(f64, @floatFromInt(v)));
        }
        return value.JSValue.fromInt(-v);
    }
    if (a.isFloat64()) {
        return try interp.allocFloat(-a.getFloat64());
    }
    return error.TypeError;
}
