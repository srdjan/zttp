//! Bytecode definitions with superinstructions
//!
//! Variable-size instruction encoding with versioned format.

const std = @import("std");
const compat = @import("zts-base").compat;
const statusTextFor = @import("zts-base").status_text.forCode;
const value = @import("value.zig");
const object = @import("object.zig");

/// Bytecode file magic number ("ZQJS")
pub const MAGIC: u32 = 0x5A514A53;

/// Current bytecode version
pub const VERSION_MAJOR: u8 = 1;
pub const VERSION_MINOR: u8 = 0;

/// Bytecode header
pub const BytecodeHeader = packed struct(u88) {
    magic: u32 = MAGIC,
    version_major: u8 = VERSION_MAJOR,
    version_minor: u8 = VERSION_MINOR,
    flags: BytecodeFlags = .{},
    checksum: u32 = 0,
};

/// Bytecode flags
/// `jit_hints` is residue of the tiered JIT, which was removed after
/// measurement, and nothing reads it. It stays for the same reason
/// `HandlerFlags.pure_dispatch` does: this is a serialized bit at a fixed
/// offset, and removing it changes what already-written bytecode decodes to.
pub const BytecodeFlags = packed struct(u8) {
    has_source_map: bool = false,
    optimized: bool = false,
    jit_hints: bool = false,
    strict_mode: bool = true,
    _reserved: u4 = 0,
};

/// Source location for a bytecode offset.
/// Offsets point at instruction starts and entries are sorted in ascending order.
pub const LineEntry = struct {
    offset: u32,
    line: u32,
    column: u32,
};

/// The engine-private global that match lowering calls to test the shape of a
/// value (spec 5.5). A record pattern asks whether the value is a record and
/// an empty array pattern whether it is an array; no opcode answers either, and
/// a new opcode would move the semantics hash. The name is not a valid
/// identifier, so no program can declare or shadow it.
pub const match_shape_global = "%matchShape";

/// The second argument of the `match_shape_global` call.
pub const MatchShape = enum(u8) {
    record = 0,
    array = 1,
};

/// Opcode definitions
pub const Opcode = enum(u8) {
    // Stack operations
    nop = 0x00,
    push_const = 0x01, // +u16 const_idx
    push_0 = 0x02,
    push_1 = 0x03,
    push_2 = 0x04,
    push_3 = 0x05,
    push_i8 = 0x06, // +i8 value
    push_i16 = 0x07, // +i16 value
    push_null = 0x08,
    push_undefined = 0x09,
    push_true = 0x0A,
    push_false = 0x0B,
    dup = 0x0C,
    drop = 0x0D,
    swap = 0x0E,
    rot3 = 0x0F,

    // Extended stack operations
    halt = 0x1A,
    loop = 0x1B, // +i16 offset (loop back)
    get_length = 0x1C, // Get length of array/string/range (fast path, no atom lookup)
    dup2 = 0x1D, // Duplicate top 2 stack values

    // Local variables
    get_loc = 0x10, // +u8 local_idx
    put_loc = 0x11, // +u8 local_idx
    get_loc_0 = 0x12,
    get_loc_1 = 0x13,
    get_loc_2 = 0x14,
    get_loc_3 = 0x15,
    put_loc_0 = 0x16,
    put_loc_1 = 0x17,
    put_loc_2 = 0x18,
    put_loc_3 = 0x19,

    // Arithmetic
    add = 0x20,
    sub = 0x21,
    mul = 0x22,
    div = 0x23,
    mod = 0x24,
    pow = 0x25,
    neg = 0x26,
    inc = 0x27,
    dec = 0x28,

    // Math builtins (compile-time specialized)
    math_floor = 0x2A, // pop 1, push floor(arg)
    math_ceil = 0x2B, // pop 1, push ceil(arg)
    math_round = 0x2C, // pop 1, push round(arg)
    math_abs = 0x2D, // pop 1, push abs(arg)
    math_min2 = 0x2E, // pop 2, push min(a, b)
    math_max2 = 0x2F, // pop 2, push max(a, b)

    // Bitwise
    bit_and = 0x30,
    bit_or = 0x31,
    bit_xor = 0x32,
    bit_not = 0x33,
    shl = 0x34,
    shr = 0x35,
    ushr = 0x36,

    // Comparison
    lt = 0x40,
    lte = 0x41,
    gt = 0x42,
    gte = 0x43,
    eq = 0x44,
    neq = 0x45,
    strict_eq = 0x46,
    strict_neq = 0x47,

    // Logical
    not = 0x48,

    // Control flow
    goto = 0x50, // +i16 offset
    if_true = 0x51, // +i16 offset
    if_false = 0x52, // +i16 offset
    ret = 0x53,
    ret_undefined = 0x54,

    // Function calls
    call = 0x60, // +u8 argc
    call_method = 0x61, // +u8 argc
    tail_call = 0x63, // +u8 argc

    // Property access
    get_field = 0x70, // +u16 atom_idx
    put_field = 0x71, // +u16 atom_idx
    get_elem = 0x72,
    put_elem = 0x73,
    put_elem_keep = 0x74, // set element and keep value on stack
    put_field_keep = 0x76, // +u16 atom_idx - set property and keep value on stack

    // Object operations
    new_object = 0x80,
    new_array = 0x81, // +u16 length
    new_object_literal = 0x82, // +u16 shape_idx +u8 prop_count (creates object with pre-compiled shape)
    get_global = 0x83, // +u16 atom_idx
    put_global = 0x84, // +u16 atom_idx
    define_global = 0x85, // +u16 atom_idx (declare global var)
    make_function = 0x86, // +u16 const_idx (creates function from bytecode in constant pool)
    array_spread = 0x87, // Spread source array into target array (pops source, target on stack)
    call_spread = 0x88, // Call function with spread args (special handling)
    object_spread = 0x89, // Copy enumerable properties from source object into target object

    // Type checks
    typeof = 0x90,

    // Async operations (kept for future implementation)

    // Module operations
    import_module = 0x9A, // +u16 module_name_idx (load module, push namespace)
    import_name = 0x9B, // +u16 name_idx (get named export from module namespace)
    import_default = 0x9C, // Get default export from module namespace
    export_name = 0x9D, // +u16 name_idx (export a binding)
    export_default = 0x9E, // Export default value

    // Superinstructions (fused hot paths)
    get_loc_add = 0xA0, // get_loc + add
    get_loc_get_loc_add = 0xA1, // get_loc + get_loc + add
    push_const_call = 0xA2, // push_const + call
    get_field_call = 0xA3, // get_field + call
    if_false_goto = 0xA4, // if_false + goto

    // Fused arithmetic-modulo (for patterns like (a + b) % c)
    // Uses i64 intermediate to avoid overflow, result guaranteed to fit in i32
    add_mod = 0xA5, // +u16 divisor_const_idx: pop a,b; push (a+b) % divisor
    sub_mod = 0xA6, // +u16 divisor_const_idx: pop a,b; push (a-b) % divisor
    mul_mod = 0xA7, // +u16 divisor_const_idx: pop a,b; push (a*b) % divisor

    // Loop optimization superinstructions
    for_of_next = 0xA8, // +i16 end_offset: check bounds, push element, increment index
    for_of_next_put_loc = 0xAC, // +u8 local_idx +i16 end_offset: for_of_next + store to local

    // Specialized constant opcodes
    shr_1 = 0xA9, // Shift right by 1 (common pattern x >> 1)
    mul_2 = 0xAA, // Multiply by 2 (common pattern x * 2)
    mod_const = 0xAB, // +u16 divisor_const_idx: pop a; push a % divisor

    // Inline i8 constant opcodes (no constant pool lookup)
    mod_const_i8 = 0xAD, // +i8 divisor: pop a; push a % divisor
    add_const_i8 = 0xAE, // +i8 value: pop a; push a + value
    sub_const_i8 = 0xAF, // +i8 value: pop a; push a - value

    // Inline cache instructions
    get_field_ic = 0xB0, // +u16 atom_idx +u16 cache_idx
    put_field_ic = 0xB1, // +u16 atom_idx +u16 cache_idx
    call_ic = 0xB2, // +u8 argc +u16 cache_idx

    // More inline i8 constant opcodes
    mul_const_i8 = 0xB3, // +i8 value: pop a; push a * value
    lt_const_i8 = 0xB4, // +i8 value: pop a; push a < value
    le_const_i8 = 0xB5, // +i8 value: pop a; push a <= value

    // Closure operations
    get_upvalue = 0xC0, // +u8 upvalue_idx
    put_upvalue = 0xC1, // +u8 upvalue_idx
    close_upvalue = 0xC2, // +u8 local_idx (close when leaving scope)
    make_closure = 0xC3, // +u16 func_idx +u8 upvalue_count

    // Object literal optimization
    set_slot = 0xC4, // +u8 slot_idx (direct slot write for pre-compiled object literals)

    // Type-specialized arithmetic (emitted when types are statically proven)
    add_num = 0xC5, // pop 2 numbers, push sum (no string dispatch)
    sub_num = 0xC6, // pop 2 numbers, push difference
    mul_num = 0xC7, // pop 2 numbers, push product
    div_num = 0xC8, // pop 2 numbers, push quotient
    lt_num = 0xC9, // pop 2 numbers, push boolean (less-than)
    gt_num = 0xCA, // pop 2 numbers, push boolean (greater-than)
    lte_num = 0xCB, // pop 2 numbers, push boolean (less-or-equal)
    gte_num = 0xCC, // pop 2 numbers, push boolean (greater-or-equal)
    drop_goto = 0xCE, // +i16 offset (fused drop + goto)

    // Reserved for future
    _,
};

/// Instruction format metadata
pub const OpcodeInfo = struct {
    size: u8, // Total instruction size in bytes
    n_pop: u8, // Stack values consumed
    n_push: u8, // Stack values produced
    name: []const u8,
};

/// Get opcode metadata for debugging, disassembly, and validation
pub fn getOpcodeInfo(op: Opcode) OpcodeInfo {
    return switch (op) {
        // Stack operations
        .nop => .{ .size = 1, .n_pop = 0, .n_push = 0, .name = "nop" },
        .push_const => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "push_const" },
        .push_0 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_0" },
        .push_1 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_1" },
        .push_2 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_2" },
        .push_3 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_3" },
        .push_i8 => .{ .size = 2, .n_pop = 0, .n_push = 1, .name = "push_i8" },
        .push_i16 => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "push_i16" },
        .push_null => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_null" },
        .push_undefined => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_undefined" },
        .push_true => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_true" },
        .push_false => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "push_false" },
        .dup => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "dup" },
        .drop => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "drop" },
        .swap => .{ .size = 1, .n_pop = 2, .n_push = 2, .name = "swap" },
        .rot3 => .{ .size = 1, .n_pop = 3, .n_push = 3, .name = "rot3" },

        // Extended stack operations
        .halt => .{ .size = 1, .n_pop = 0, .n_push = 0, .name = "halt" },
        .loop => .{ .size = 3, .n_pop = 0, .n_push = 0, .name = "loop" },
        .get_length => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "get_length" },
        .dup2 => .{ .size = 1, .n_pop = 0, .n_push = 2, .name = "dup2" },

        // Local variables
        .get_loc => .{ .size = 2, .n_pop = 0, .n_push = 1, .name = "get_loc" },
        .put_loc => .{ .size = 2, .n_pop = 1, .n_push = 0, .name = "put_loc" },
        .get_loc_0 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "get_loc_0" },
        .get_loc_1 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "get_loc_1" },
        .get_loc_2 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "get_loc_2" },
        .get_loc_3 => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "get_loc_3" },
        .put_loc_0 => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "put_loc_0" },
        .put_loc_1 => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "put_loc_1" },
        .put_loc_2 => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "put_loc_2" },
        .put_loc_3 => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "put_loc_3" },

        // Arithmetic
        .add => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "add" },
        .sub => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "sub" },
        .mul => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "mul" },
        .div => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "div" },
        .mod => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "mod" },
        .pow => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "pow" },
        .neg => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "neg" },
        .inc => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "inc" },
        .dec => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "dec" },

        // Math builtins
        .math_floor => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "math_floor" },
        .math_ceil => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "math_ceil" },
        .math_round => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "math_round" },
        .math_abs => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "math_abs" },
        .math_min2 => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "math_min2" },
        .math_max2 => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "math_max2" },

        // Bitwise
        .bit_and => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "bit_and" },
        .bit_or => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "bit_or" },
        .bit_xor => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "bit_xor" },
        .bit_not => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "bit_not" },
        .shl => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "shl" },
        .shr => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "shr" },
        .ushr => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "ushr" },

        // Comparison
        .lt => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "lt" },
        .lte => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "lte" },
        .gt => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "gt" },
        .gte => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "gte" },
        .eq => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "eq" },
        .neq => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "neq" },
        .strict_eq => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "strict_eq" },
        .strict_neq => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "strict_neq" },

        // Logical
        .not => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "not" },

        // Control flow
        .goto => .{ .size = 3, .n_pop = 0, .n_push = 0, .name = "goto" },
        .if_true => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "if_true" },
        .if_false => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "if_false" },
        .ret => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "ret" },
        .ret_undefined => .{ .size = 1, .n_pop = 0, .n_push = 0, .name = "ret_undefined" },

        // Function calls (n_pop is dynamic based on argc)
        .call => .{ .size = 2, .n_pop = 0, .n_push = 1, .name = "call" },
        .call_method => .{ .size = 2, .n_pop = 0, .n_push = 1, .name = "call_method" },
        .tail_call => .{ .size = 2, .n_pop = 0, .n_push = 0, .name = "tail_call" },

        // Property access
        .get_field => .{ .size = 3, .n_pop = 1, .n_push = 1, .name = "get_field" },
        .put_field => .{ .size = 3, .n_pop = 2, .n_push = 0, .name = "put_field" },
        .get_elem => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "get_elem" },
        .put_elem => .{ .size = 1, .n_pop = 3, .n_push = 0, .name = "put_elem" },
        .put_elem_keep => .{ .size = 1, .n_pop = 3, .n_push = 1, .name = "put_elem_keep" },
        .put_field_keep => .{ .size = 3, .n_pop = 2, .n_push = 1, .name = "put_field_keep" },

        // Object operations
        .new_object => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "new_object" },
        .new_array => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "new_array" },
        .new_object_literal => .{ .size = 4, .n_pop = 0, .n_push = 1, .name = "new_object_literal" },
        .get_global => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "get_global" },
        .put_global => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "put_global" },
        .define_global => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "define_global" },
        .make_function => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "make_function" },
        .array_spread => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "array_spread" },
        .call_spread => .{ .size = 1, .n_pop = 0, .n_push = 1, .name = "call_spread" },
        .object_spread => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "object_spread" },

        // Type checks
        .typeof => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "typeof" },

        // Async operations

        // Module operations
        .import_module => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "import_module" },
        .import_name => .{ .size = 3, .n_pop = 1, .n_push = 1, .name = "import_name" },
        .import_default => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "import_default" },
        .export_name => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "export_name" },
        .export_default => .{ .size = 1, .n_pop = 1, .n_push = 0, .name = "export_default" },

        // Superinstructions
        .get_loc_add => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "get_loc_add" },
        .get_loc_get_loc_add => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "get_loc_get_loc_add" },
        .push_const_call => .{ .size = 4, .n_pop = 0, .n_push = 1, .name = "push_const_call" },
        .get_field_call => .{ .size = 4, .n_pop = 1, .n_push = 1, .name = "get_field_call" },
        .if_false_goto => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "if_false_goto" },

        // Fused arithmetic-modulo
        .add_mod => .{ .size = 3, .n_pop = 2, .n_push = 1, .name = "add_mod" },
        .sub_mod => .{ .size = 3, .n_pop = 2, .n_push = 1, .name = "sub_mod" },
        .mul_mod => .{ .size = 3, .n_pop = 2, .n_push = 1, .name = "mul_mod" },

        // Loop optimization superinstructions
        .for_of_next => .{ .size = 3, .n_pop = 0, .n_push = 1, .name = "for_of_next" },
        .for_of_next_put_loc => .{ .size = 4, .n_pop = 0, .n_push = 0, .name = "for_of_next_put_loc" },

        // Specialized constant opcodes
        .shr_1 => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "shr_1" },
        .mul_2 => .{ .size = 1, .n_pop = 1, .n_push = 1, .name = "mul_2" },
        .mod_const => .{ .size = 3, .n_pop = 1, .n_push = 1, .name = "mod_const" },

        // Inline i8 constant opcodes
        .mod_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "mod_const_i8" },
        .add_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "add_const_i8" },
        .sub_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "sub_const_i8" },

        // Inline cache instructions
        .get_field_ic => .{ .size = 5, .n_pop = 1, .n_push = 1, .name = "get_field_ic" },
        .put_field_ic => .{ .size = 5, .n_pop = 2, .n_push = 0, .name = "put_field_ic" },
        .call_ic => .{ .size = 4, .n_pop = 0, .n_push = 1, .name = "call_ic" },

        // More inline i8 constant opcodes
        .mul_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "mul_const_i8" },
        .lt_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "lt_const_i8" },
        .le_const_i8 => .{ .size = 2, .n_pop = 1, .n_push = 1, .name = "le_const_i8" },

        // Closure operations
        .get_upvalue => .{ .size = 2, .n_pop = 0, .n_push = 1, .name = "get_upvalue" },
        .put_upvalue => .{ .size = 2, .n_pop = 1, .n_push = 0, .name = "put_upvalue" },
        .close_upvalue => .{ .size = 2, .n_pop = 0, .n_push = 0, .name = "close_upvalue" },
        .make_closure => .{ .size = 4, .n_pop = 0, .n_push = 1, .name = "make_closure" },

        // Object literal optimization
        .set_slot => .{ .size = 2, .n_pop = 2, .n_push = 0, .name = "set_slot" },

        // Type-specialized arithmetic
        .add_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "add_num" },
        .sub_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "sub_num" },
        .mul_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "mul_num" },
        .div_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "div_num" },
        .lt_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "lt_num" },
        .gt_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "gt_num" },
        .lte_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "lte_num" },
        .gte_num => .{ .size = 1, .n_pop = 2, .n_push = 1, .name = "gte_num" },
        .drop_goto => .{ .size = 3, .n_pop = 1, .n_push = 0, .name = "drop_goto" },

        // Unknown/reserved opcodes
        _ => .{ .size = 1, .n_pop = 0, .n_push = 0, .name = "unknown" },
    };
}

/// Upvalue info for closures
pub const UpvalueInfo = struct {
    is_local: bool, // true: from parent's locals, false: from parent's upvalues
    index: u8, // Index in parent's locals or upvalues array
};

/// Function bytecode structure
pub const FunctionBytecode = struct {
    header: BytecodeHeader,
    name_atom: u32,
    arg_count: u16,
    local_count: u16,
    stack_size: u16,
    flags: FunctionFlags,
    upvalue_count: u8 = 0, // Number of upvalues this function captures
    upvalue_info: []const UpvalueInfo = &.{}, // Info for each upvalue
    code: []const u8,
    constants: []const value.JSValue,
    source_map: ?[]const u8,
    line_table: ?[]const LineEntry = null,

    // HTTP handler fast path (native dispatch)
    pattern_dispatch: ?*PatternDispatchTable = null,
    handler_flags: HandlerFlags = .{},
};

pub const FunctionFlags = packed struct(u8) {
    is_strict: bool = true,
    is_generator: bool = false,
    is_async: bool = false,
    has_arguments: bool = false,
    has_rest: bool = false,
    _reserved: u3 = 0,
};

// ============================================================================
// HTTP Handler Fast Path Structures
// ============================================================================

/// Handler flags for fast path optimization.
///
/// `pure_dispatch` has no reader and is kept anyway. This is a packed struct in
/// a serialized format: the field is one bit at a fixed offset, and deleting it
/// would either shift `_reserved` - changing what previously written bytes
/// decode to - or leave a hole that reads as a rename. A dead bit in a wire
/// layout is not the same thing as a dead function, and the cost of removing it
/// is paid by every artifact already on disk.
pub const HandlerFlags = packed struct(u8) {
    is_http_handler: bool = false,
    has_static_routes: bool = false,
    pure_dispatch: bool = false, // All routes are static (no dynamic fallback needed)
    _reserved: u5 = 0,
};

/// Pattern type for URL matching
pub const PatternType = enum(u2) {
    exact, // url === '/api/health'
    prefix, // url.indexOf('/api/greet/') === 0
    dynamic, // Dynamic routing (not optimizable)
};

/// Source of response body material for fast path patterns.
pub const ResponseBodySource = enum(u2) {
    static, // body is pre-serialized at compile time
    request_json_parse, // body is built from JSON.parse(request.body)
};

/// Pre-analyzed URL pattern with static response
pub const HandlerPattern = struct {
    pattern_type: PatternType,
    url_atom: object.Atom, // For exact match
    url_bytes: []const u8, // URL string bytes for comparison
    static_body: []const u8, // Pre-serialized JSON body
    body_source: ResponseBodySource = .static,
    status: u16,
    content_type_idx: u8, // 0=json, 1=text, 2=html
    /// Pre-built complete HTTP response (status line + headers + body)
    /// When set, can be written directly without any header construction
    prebuilt_response: ?[]const u8 = null,

    pub fn deinit(self: *HandlerPattern, allocator: std.mem.Allocator) void {
        if (self.url_bytes.len > 0) {
            allocator.free(self.url_bytes);
        }
        if (self.static_body.len > 0) {
            allocator.free(self.static_body);
        }
        if (self.prebuilt_response) |prebuilt| {
            allocator.free(prebuilt);
        }
    }

    /// Build the pre-serialized HTTP response for static patterns.
    /// Should be called after pattern analysis to enable zero-copy fast path.
    pub fn buildPrebuiltResponse(self: *HandlerPattern, allocator: std.mem.Allocator) !void {
        if (self.pattern_type != .exact) return; // Only for exact matches
        if (self.body_source != .static) return; // Dynamic body patterns cannot be prebuilt

        const content_type = switch (self.content_type_idx) {
            0 => "application/json",
            1 => "text/plain; charset=utf-8",
            else => "text/html; charset=utf-8",
        };
        const status_text = statusTextFor(self.status);

        // Calculate total size needed
        // "HTTP/1.1 XXX STATUS\r\nContent-Type: ...\r\nContent-Length: NNN\r\nConnection: keep-alive\r\n\r\nBODY"
        var size: usize = 0;
        size += 9; // "HTTP/1.1 "
        size += 3; // status code
        size += 1; // space
        size += status_text.len;
        size += 2; // \r\n
        size += 14 + content_type.len + 2; // "Content-Type: " + value + \r\n
        size += 16 + 10 + 2; // "Content-Length: " + max 10 digits + \r\n
        size += 24; // "Connection: keep-alive\r\n"
        size += 2; // \r\n (end of headers)
        size += self.static_body.len;

        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        // Build the response
        var pos: usize = 0;
        const response = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{
            self.status,
            status_text,
            content_type,
            self.static_body.len,
        }) catch unreachable;
        pos = response.len;

        // Append body
        @memcpy(buf[pos..][0..self.static_body.len], self.static_body);
        pos += self.static_body.len;

        // Trim to actual size
        self.prebuilt_response = try allocator.realloc(buf, pos);
    }
};

test "prebuilt response uses canonical status text" {
    const cases = [_]struct {
        status: u16,
        status_line: []const u8,
    }{
        .{ .status = 413, .status_line = "HTTP/1.1 413 Payload Too Large\r\n" },
        .{ .status = 202, .status_line = "HTTP/1.1 202 Accepted\r\n" },
        .{ .status = 599, .status_line = "HTTP/1.1 599 Network Connect Timeout Error\r\n" },
    };

    for (cases) |case| {
        var pattern = HandlerPattern{
            .pattern_type = .exact,
            .url_atom = .null,
            .url_bytes = try std.testing.allocator.dupe(u8, "/"),
            .static_body = try std.testing.allocator.dupe(u8, "body"),
            .status = case.status,
            .content_type_idx = 1,
        };
        defer pattern.deinit(std.testing.allocator);

        try pattern.buildPrebuiltResponse(std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, pattern.prebuilt_response.?, case.status_line));
    }
}

/// Fast dispatch table for handler
pub const PatternDispatchTable = struct {
    patterns: []HandlerPattern,
    exact_match_map: std.AutoHashMapUnmanaged(u64, u16), // hash -> pattern idx
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PatternDispatchTable {
        return .{
            .patterns = &.{},
            .exact_match_map = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PatternDispatchTable) void {
        for (self.patterns) |*pattern| {
            var p = pattern;
            p.deinit(self.allocator);
        }
        if (self.patterns.len > 0) {
            self.allocator.free(self.patterns);
        }
        self.exact_match_map.deinit(self.allocator);
    }
};

test "Opcode encoding" {
    try std.testing.expectEqual(@as(u8, 0x20), @backingInt(Opcode.add));
    try std.testing.expectEqual(@as(u8, 0x50), @backingInt(Opcode.goto));
}

test "OpcodeInfo lookup" {
    const add_info = getOpcodeInfo(.add);
    try std.testing.expectEqual(@as(u8, 1), add_info.size);
    try std.testing.expectEqual(@as(u8, 2), add_info.n_pop);
    try std.testing.expectEqual(@as(u8, 1), add_info.n_push);
}

test "BytecodeHeader" {
    const header = BytecodeHeader{};
    try std.testing.expectEqual(MAGIC, header.magic);
    try std.testing.expectEqual(VERSION_MAJOR, header.version_major);
}
