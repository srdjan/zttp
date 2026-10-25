//! Leaf helper: locate the `handler` function in a parsed program.

const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;

const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const null_node = ir.null_node;

/// Find the handler function in a parsed program.
/// Looks for `function handler(...)` or `const handler = ...` at top level.
pub fn findHandlerFunction(ir_view: IrView, root: NodeIndex) ?NodeIndex {
    const tag = ir_view.getTag(root) orelse return null;
    if (tag != .program and tag != .block) return null;
    const block = ir_view.getBlock(root) orelse return null;

    var i: u16 = 0;
    while (i < block.stmts_count) : (i += 1) {
        const stmt_idx = ir_view.getListIndex(block.stmts_start, i);
        const stmt_tag = ir_view.getTag(stmt_idx) orelse continue;

        // Unwrap `export function handler(...)` -> the inner function_decl/var_decl
        const effective_stmt: NodeIndex = blk: {
            if (stmt_tag == .export_decl) {
                const export_decl = ir_view.getExportDecl(stmt_idx) orelse continue;
                if (export_decl.declaration == null_node) continue;
                break :blk export_decl.declaration;
            }
            break :blk stmt_idx;
        };
        const effective_tag = ir_view.getTag(effective_stmt) orelse continue;

        if (effective_tag == .function_decl or effective_tag == .var_decl) {
            const decl = ir_view.getVarDecl(effective_stmt) orelse continue;
            if (decl.binding.kind != .global) continue;
            if (decl.binding.name_atom != @backingInt(object.Atom.handler)) continue;

            const init_tag = ir_view.getTag(decl.init) orelse continue;
            if (init_tag == .function_expr or init_tag == .arrow_function) {
                return decl.init;
            }
        }
    }

    return null;
}
