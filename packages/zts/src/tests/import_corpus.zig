//! Shared handler sources for the import-index differential tests.
//!
//! Item 4 C1 replaces six independent `scanImports` implementations with reads
//! over `ModuleFacts.imports`. Each migration proves equivalence over THIS
//! corpus rather than inventing its own, so the six tests cover the same edge
//! cases and a gap gets closed once.
//!
//! Data only, no tests: nothing needs to anchor this file into a test root.

/// Every entry is a complete handler source. `label` is what a failing
/// differential test prints, so it must say what the case is for.
pub const Case = struct {
    label: []const u8,
    source: []const u8,
};

pub const cases = [_]Case{
    .{
        .label = "no imports at all",
        .source = "function handler(req) { return Response.json({ok: true}); }\n",
    },
    .{
        .label = "one builtin import",
        .source = "import { env } from \"zttp:env\";\n",
    },
    .{
        .label = "several names from one module",
        .source = "import { sha256, hmacSha256, base64Encode } from \"zttp:crypto\";\n",
    },
    .{
        .label = "the same module imported twice",
        .source =
        \\import { sha256 } from "zttp:crypto";
        \\import { base64Encode } from "zttp:crypto";
        ,
    },
    .{
        .label = "the same name imported twice",
        .source =
        \\import { sha256 } from "zttp:crypto";
        \\import { sha256 } from "zttp:crypto";
        ,
    },
    .{
        // Separates `imported_atom` from `local_binding.slot`: the record must
        // carry the imported name, not the local alias.
        .label = "an aliased import",
        .source = "import { env as e } from \"zttp:env\";\n",
    },
    .{
        // The case that distinguishes `imports` from `generic_bindings`:
        // sha256 carries no contract extractions and no contract flags, so it
        // has no generic_bindings entry, but four analyzers still need its slot.
        .label = "a builtin function with no extractions and no flags",
        .source = "import { sha256 } from \"zttp:crypto\";\n",
    },
    .{
        // strict_checker and effect_inference record this; the other four do
        // not. Every differential test must assert its own analyzer's answer
        // here, or a migration could silently unify the six filters.
        .label = "a module that is neither builtin nor registered",
        .source = "import { thing } from \"zttp-ext:unknown\";\n",
    },
    .{
        .label = "a builtin and an unresolved module together",
        .source =
        \\import { env } from "zttp:env";
        \\import { thing } from "zttp-ext:unknown";
        ,
    },
    .{
        .label = "several modules in first-appearance order",
        .source =
        \\import { sha256 } from "zttp:crypto";
        \\import { env } from "zttp:env";
        \\import { uuid } from "zttp:id";
        ,
    },
};
