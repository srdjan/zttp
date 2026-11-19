---
title: An optional accessor read a string node as a function body
date: 2026-11-19
category: runtime-errors
module: zts IR accessors (IrView)
problem_type: runtime_error
component: compiler
symptoms:
  - "`zts check` crashed with exit 134 and a segmentation fault on an admitted top-level initializer, `const a: string = \"a,b\".split(\",\").join(\"-\");`."
  - "`const n: number = Math.floor(1.5);` at top level got a false ZTS630."
  - The pre-plan binary checked the same sources with exit 0.
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [zts, ir, irview, accessor, node-tag, zts630, strict-checker, crash]
---

# An optional accessor read a string node as a function body

## Problem

The ZTS630 walk of a top-level initializer
(`packages/zts/src/strict_checker.zig#StrictChecker.callbackEffect`)
passed every call argument to `IrView.getFunction` to find a callback body.
`getFunction` refused only a `function_decl` node. For any other node, it
decoded the node's data words as a function payload and returned it. A
string argument such as `","` became a function whose body index pointed at
an unrelated node. The walk then descended into that "body", recursed
without end, and crashed the check. A number argument decoded a body that
reached a module name, which gave a false ZTS630.

## Root cause

`IrView` accessors return an optional (`?Node.FunctionExpr`,
`?Node.MemberExpr`, `?Node.VarDecl`, and others), but most of them return
null only for an index past the end of the store. They do not check the
node tag. The optional reads as "null when this is not that kind of node",
and that reading is wrong. A caller that has not tested the tag gets a
struct decoded from another node's data. `getMember` (packages/zts/src/parser/ir.zig)
decodes any tag that is not `computed_access` as a member access, and
`getVarDecl` decodes any node's extra data as a declaration.

## Solution

Commit 62ee593f made `getFunction` return null for every node that is not
a `function_expr` or an `arrow_function`, which also guards its other
callers. The pipeline test "a top-level initializer with a builtin call
that takes a non-function argument is admitted" crashed before the fix
and passes after it.

## Prevention

Test the node tag before calling an `IrView` accessor, unless the call
sits in a switch arm on that tag. Do not treat the optional return as a
tag check: of the node accessors, only `getFunction`,
`getFunctionOfDecl`, and `getMatchTypeTest` check the tag today, and
`getCall` and `getMember` do not. The U4d-5 implementer met the same trap in `getMember`, and
`TypeChecker.builtinCallee` tests for `.member_access` before calling it.

Two stronger forms are open for the owner of `packages/zts/src/parser/ir.zig`,
because each changes product code: make every accessor return null for a
foreign tag, as `getFunction` now does, and add a census test that calls
each accessor on a node of another tag and expects null.
