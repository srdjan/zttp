---
title: Keep automatic semicolon repair withdrawn until source positions are exact
date: 2026-10-10
category: tooling-decisions
module: packages/tools/src/canonicalize.zig
problem_type: tooling_decision
component: canonicalize
severity: high
applies_when:
  - "Considering automatic repair for statements that rely on semicolon insertion"
  - "Mapping parser positions through comptime or TSX source transformations"
tags:
  - canonicalize
  - repair
  - source-mapping
  - semicolon
---

# Keep automatic semicolon repair withdrawn until source positions are exact

## Context

The former `buildSemicolonRepairs` function read line numbers from stripped code.
The function then applied those line numbers to the original source.

A `comptime(...)` fold can change offsets during stripping.
The repair could therefore edit a different original line.

The repair trimmed the line and appended `;` to the result.
For a trailing `//` comment, this placed the semicolon inside the comment.
For a CRLF file, trimming also removed the carriage return.

The TSX frontend also changes source positions.
The repair did not compose its positions through the TSX frontend map.

## Decision

The canonicalizer does not offer this repair.
The active canonicalizer uses diagnostic-driven line repairs and span repairs.

The removed function had no caller.
The frozen corpus required no automatic semicolon repair when the function was withdrawn.

## Requirements for reintroduction

A future repair must translate parser positions through `sourcePosition`.
For TSX, the repair must also compose positions through the frontend map.

The repair must replace an exact source span.
The replacement must preserve comments and CRLF line endings.

The equivalence check must use the grammar that the compiler ships.
Tests must cover `comptime(...)`, trailing comments, CRLF files, and TSX input.
