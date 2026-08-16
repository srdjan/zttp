//! The decision kinds a client keys on, as data rather than as strings at their
//! emission sites.
//!
//! Spec 4.8 asks `meta.payload.decisions` for "the versioned registry of
//! next-action and semantic-decision kinds referenced by unsupported results and
//! explanation graphs, each with an identifier and a parameter schema". Spec 4.7
//! says a structured unsupported result names "allowed next actions" and never a
//! guessed replacement.
//!
//! What exists in this compiler to publish: the refusals returned by edit
//! simulation and canonicalization. Each already carried a stable wire string chosen
//! at its own emission site, which is the shape this registry replaces - the
//! `Id` enum below is the wire vocabulary, so a refusal that names a kind the
//! registry does not carry no longer compiles.
//!
//! Each row also carries the next action the client can take. That is not new
//! policy: it is what the refusal's own message has been telling a human reader
//! in prose, made machine-readable, so a loop can branch on it rather than
//! parse English.
//!
//! What does not exist and is therefore not published: the explanation graph of
//! spec 13.6, which no build report emits, and any semantic-decision kind, since
//! nothing in this compiler asks a client to choose a semantic. When either
//! lands, its kinds join this registry and the version below moves.

const std = @import("std");

/// The version a client pins when it caches the meaning of these identifiers.
/// It moves when a row's meaning changes or a row is removed - not when a row
/// is added, which a client that does not know the identifier already handles
/// by treating it as an unknown refusal.
pub const version: u32 = 1;

/// The wire vocabulary. `@tagName` is the string on the wire, so the enum and
/// the published identifiers cannot drift apart.
pub const Id = enum {
    no_repairs,
    malformed_repair,
    unknown_intent,
    stale_repair,
    overlapping_repairs,
    repair_out_of_range,
    ungraded_intent,
    not_law_shape,
    undecided_equivalence,
    veto,

    pub fn wire(self: Id) []const u8 {
        return @tagName(self);
    }
};

/// What a client does next. Every row names exactly one, and none of them is
/// "guess": spec 4.7 forbids a guessed replacement in an unsupported result.
pub const NextAction = enum {
    /// The request itself is malformed. Nothing about the file is in question.
    fix_the_request,
    /// The file moved under the request. Re-read it, recompute the digest, and
    /// resubmit the repair against what the file now says.
    reread_the_file,
    /// The repair set cannot be applied as one edit. Submit fewer repairs, or
    /// submit them in separate requests.
    narrow_the_repair_set,
    /// No validator discharges this intent, so no automatic application is
    /// possible. `simulate_edit` still previews it for a human decision.
    choose_a_graded_intent,
    /// A validator ran and refused, or formed no answer. The edit is not known
    /// to be an equivalence, and this compiler will not apply it on that basis.
    no_mechanical_repair,
};

pub const Decision = struct {
    id: Id,
    next_action: NextAction,
    description: []const u8,
    /// The response fields that carry this decision's parameters. A client
    /// reads the decision, then reads exactly these.
    parameters: []const []const u8,
};

/// Every refusal both repair operations can answer with. The two share a shape:
/// the payload's published key set stays intact and `refusal` carries the kind
/// and a message, so a client that reads `refusal` first never has to guess
/// which other fields are present.
const refusal_parameters: []const []const u8 = &.{ "file", "source_digest", "refusal.reason", "refusal.message" };

pub const decisions = [_]Decision{
    .{
        .id = .no_repairs,
        .next_action = .fix_the_request,
        .description = "the request carried an empty repair set, so there was nothing to apply",
        .parameters = refusal_parameters,
    },
    .{
        .id = .malformed_repair,
        .next_action = .fix_the_request,
        .description = "a repair entry is not an object, or is missing a field the repair shape requires",
        .parameters = refusal_parameters,
    },
    .{
        .id = .unknown_intent,
        .next_action = .choose_a_graded_intent,
        .description = "the named intent is not a member of the repair vocabulary; `meta.validators` carries the closed set",
        .parameters = refusal_parameters,
    },
    .{
        .id = .stale_repair,
        .next_action = .reread_the_file,
        .description = "a repair's `original` text does not match the file as it stands, so the edit was computed against bytes that are gone",
        .parameters = refusal_parameters,
    },
    .{
        .id = .overlapping_repairs,
        .next_action = .narrow_the_repair_set,
        .description = "two repairs in the set cover the same bytes, and the set is applied atomically or not at all",
        .parameters = refusal_parameters,
    },
    .{
        .id = .repair_out_of_range,
        .next_action = .reread_the_file,
        .description = "a repair names a line past the end of the file, or a byte span outside it",
        .parameters = refusal_parameters,
    },
    .{
        .id = .ungraded_intent,
        .next_action = .choose_a_graded_intent,
        .description = "no registered validator discharges this intent, so the edit cannot be graded as an equivalence and is not applied automatically",
        .parameters = refusal_parameters,
    },
    .{
        .id = .not_law_shape,
        .next_action = .no_mechanical_repair,
        .description = "the validator re-derived the edit from the original and got something else, so the submitted edit is not the law's",
        .parameters = refusal_parameters,
    },
    .{
        .id = .undecided_equivalence,
        .next_action = .no_mechanical_repair,
        .description = "the validator formed no answer - the construct is one it does not model - which is neither an acceptance nor a refusal of the edit",
        .parameters = refusal_parameters,
    },
    .{
        .id = .veto,
        .next_action = .narrow_the_repair_set,
        .description = "the repaired file carries diagnostics the original did not, so the set was refused as a whole and nothing was written",
        .parameters = refusal_parameters,
    },
};

pub fn get(id: Id) *const Decision {
    for (&decisions) |*row| {
        if (row.id == id) return row;
    }
    unreachable; // the comptime check below proves the table is total
}

comptime {
    // The enum is the wire vocabulary and the table is what `meta` publishes.
    // A member with no row would be emitted and unpublished; a row whose member
    // was deleted would be published and unemittable.
    for (@typeInfo(Id).@"enum".fields) |field| {
        const id: Id = @enumFromInt(field.value);
        var seen = 0;
        for (decisions) |row| {
            if (row.id == id) seen += 1;
        }
        if (seen != 1) @compileError("decision id must have exactly one row: " ++ field.name);
    }
}

const testing = std.testing;

test "the wire string of a decision is its identifier" {
    try testing.expectEqualStrings("stale_repair", Id.stale_repair.wire());
    try testing.expectEqualStrings("stale_repair", get(.stale_repair).id.wire());
}

test "every row names its parameters and a next action that is not a guess" {
    for (&decisions) |row| {
        try testing.expect(row.description.len > 0);
        try testing.expect(row.parameters.len > 0);
        // Reading the refusal must be enough to know where to look next.
        var names_refusal = false;
        for (row.parameters) |p| {
            if (std.mem.startsWith(u8, p, "refusal.")) names_refusal = true;
        }
        try testing.expect(names_refusal);
    }
}

test "a request-shape refusal never sends the client back to the file" {
    // The distinction the next actions exist to draw: a malformed request is
    // not evidence that the file moved, and re-reading it would be a wasted
    // round trip that changes nothing about the refusal.
    try testing.expectEqual(NextAction.fix_the_request, get(.no_repairs).next_action);
    try testing.expectEqual(NextAction.fix_the_request, get(.malformed_repair).next_action);
    try testing.expectEqual(NextAction.reread_the_file, get(.stale_repair).next_action);
    try testing.expectEqual(NextAction.reread_the_file, get(.repair_out_of_range).next_action);
}
