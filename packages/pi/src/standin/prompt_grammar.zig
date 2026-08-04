//! Combinatorial prompt grammars for the stand-in's routing and false-fire
//! gates.
//!
//! Those gates measured 12 paraphrases and 4 out-of-range prompts. At that size
//! "12/12 correct" and "0/4 false fires" read as evidence and are closer to
//! anecdote: a router could route most things to one kind and still score well.
//! The grammars here cross lead-ins, cores, and tails into a few hundred
//! prompts per run, so the counts mean something.
//!
//! Generated rather than model-written on purpose. Nothing here is captured
//! model output, so there is no provenance question, and a reviewer checks a
//! grammar of a dozen phrases rather than several hundred strings.
//!
//! The one rule that makes these measurements honest: a core must carry the
//! needle that routes its own kind and must carry no needle belonging to a kind
//! `expert_workflow.classify` checks earlier. That classifier is ordered, so a
//! prompt mixing "route" and "database" legitimately routes to sql_feature. A
//! grammar that produced such a prompt and expected route_add would be testing
//! this file's assumptions rather than the router. When a generated prompt
//! misroutes, the grammar is wrong - never the classifier.

const std = @import("std");
const expert_workflow = @import("../expert_workflow.zig");

pub const Grammar = struct {
    /// Range entry id, or the out-of-range kind name for negatives.
    id: []const u8,
    kind: expert_workflow.TaskKind,
    leads: []const []const u8,
    cores: []const []const u8,
    tails: []const []const u8,

    pub fn count(self: Grammar) usize {
        return self.leads.len * self.cores.len * self.tails.len;
    }
};

const common_leads = [_][]const u8{
    "",
    "Please ",
    "Can you ",
    "I need you to ",
};

const file_tails = [_][]const u8{
    "",
    " in handler.ts",
    " in api.ts",
    " for the current handler",
};

/// In-range grammars. Every generated prompt must classify to `kind`.
pub const in_range = [_]Grammar{
    .{
        .id = "explain",
        .kind = .review_explain,
        .leads = &common_leads,
        .cores = &.{
            "explain what this handler does",
            "explain how this file builds its reply",
            "what does this handler return",
            "how does this handler build its reply",
        },
        .tails = &file_tails,
    },
    .{
        .id = "review",
        .kind = .review_explain,
        .leads = &common_leads,
        .cores = &.{
            "review this handler",
            "review the code for compliance",
            "what does the guard clause cover",
            "how does the error path behave",
        },
        .tails = &file_tails,
    },
    .{
        .id = "add-route",
        .kind = .route_add,
        .leads = &common_leads,
        .cores = &.{
            "add a GET /health route",
            "add a new route for /status",
            "create route /ping",
            "add a route table",
        },
        .tails = &file_tails,
    },
    .{
        .id = "add-env",
        .kind = .env_feature,
        .leads = &common_leads,
        .cores = &.{
            "read the APP_NAME environment variable",
            "add an env var for the greeting",
            "load the API key from configuration",
            "use a secret for the upstream call",
        },
        .tails = &file_tails,
    },
    .{
        .id = "write-test",
        .kind = .test_generation,
        .leads = &common_leads,
        .cores = &.{
            "write test coverage",
            "add test cases",
            "write a jsonl test",
            "add a test case for the happy path",
        },
        .tails = &file_tails,
    },
    .{
        .id = "fix",
        .kind = .violation_fix,
        .leads = &common_leads,
        .cores = &.{
            "fix the ZTS violation",
            "repair the diagnostic",
            "resolve the compiler error",
            "clean up the ZTS042 violation",
        },
        .tails = &file_tails,
    },
    .{
        // Every core carries a needle that cannot appear inside `whole`, which
        // is the trap this kind has: a bare "hole" routes "rewrite the whole
        // file" here. `hole_fill` is checked after `violation_fix`, so no core
        // may pair a fix verb with a diagnostic word either.
        .id = "fill-hole",
        .kind = .hole_fill,
        .leads = &common_leads,
        .cores = &.{
            "fill the hole",
            // Not "fill the remaining hole": with the empty lead and the
            // handler.ts tail that renders the canonical prompt exactly, and the
            // routing number would then be partly a measurement of the frozen
            // corpus it is supposed to be independent of.
            "fill the remaining typed hole",
            "replace the hole() with an expression",
            "write the expression for the typed hole",
        },
        .tails = &file_tails,
    },
};

/// Out-of-range grammars. Every generated prompt classifies to a kind the
/// stand-in has no playbook for, so every one must produce `[standin-miss]`
/// and apply no edit.
///
/// In-domain on purpose. Gibberish classifies to `unknown` and misses
/// trivially, which proves nothing; these are asks a careless playbook would
/// actually fire on.
pub const out_of_range = [_]Grammar{
    .{
        .id = "auth_jwt",
        .kind = .auth_jwt,
        .leads = &common_leads,
        .cores = &.{
            "require a bearer token on every request",
            "verify the authorization token",
            "add jwt auth to the endpoint",
        },
        .tails = &file_tails,
    },
    .{
        .id = "sql_feature",
        .kind = .sql_feature,
        .leads = &common_leads,
        .cores = &.{
            "look the account up in the database",
            "select the rows from the database",
            "insert a record into the store",
        },
        .tails = &file_tails,
    },
    .{
        .id = "spec_goal",
        .kind = .spec_goal,
        .leads = &common_leads,
        .cores = &.{
            "prove the handler holds injection_safe",
            "make the handler deterministic",
            "add a proof capsule",
        },
        .tails = &file_tails,
    },
    .{
        .id = "workflow_authoring",
        .kind = .workflow_authoring,
        .leads = &common_leads,
        .cores = &.{
            "create a durable workflow handler using workflow.call",
            "add a saga with compensation",
            "dispatch a child through zttp:workflow",
        },
        .tails = &file_tails,
    },
    .{
        .id = "handler_scaffold",
        .kind = .handler_scaffold,
        .leads = &common_leads,
        .cores = &.{
            "scaffold a minimal handler",
            "create handler from scratch",
            "new handler for the service",
        },
        .tails = &file_tails,
    },
};

/// Materialize one prompt. `index` runs over `grammar.count()`.
pub fn generate(allocator: std.mem.Allocator, grammar: Grammar, index: usize) ![]u8 {
    const tail_n = grammar.tails.len;
    const core_n = grammar.cores.len;
    const tail = grammar.tails[index % tail_n];
    const core = grammar.cores[(index / tail_n) % core_n];
    const lead = grammar.leads[index / (tail_n * core_n)];
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ lead, core, tail });
}

pub fn totalIn(grammars: []const Grammar) usize {
    var n: usize = 0;
    for (grammars) |g| n += g.count();
    return n;
}
