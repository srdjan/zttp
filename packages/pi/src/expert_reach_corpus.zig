//! Frozen reference-backed tasks for the bounded provable-set reach measure.

const std = @import("std");
const codegen = @import("expert_codegen_eval.zig");
const codegen_types = @import("expert_codegen_types.zig");

pub const Task = struct {
    id: []const u8,
    family: []const u8,
    mode: codegen_types.InputMode,
    prompt: []const u8,
    seed_files: []const codegen_types.SeedFile = &.{},
    reference_files: []const codegen_types.SeedFile,
    intent: codegen.IntentCheck,
    required_properties: []const []const u8,
};

const required_properties = [_][]const u8{
    "deterministic",
    "read_only",
    "retry_safe",
    "idempotent",
    "state_isolated",
    "result_safe",
    "optional_safe",
    "canonical",
    "cost_bounded",
};

const proof_capsule =
    "Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | " ++
    "\"idempotent\" | \"state_isolated\" | \"result_safe\" | \"optional_safe\" | " ++
    "\"canonical\" | \"cost_bounded\">";

const handler_signature = "function handler(req: Request): " ++ proof_capsule ++ " {\n";

const header_reference = handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const format = req.headers.get("x-format") ?? "";
    \\  let kind = "other";
    \\  if (format === "json") {
    \\    kind = "json";
    \\  } else if (format === "text") {
    \\    kind = "text";
    \\  }
    \\  return Response.json({ kind: kind });
    \\}
    \\
;

const header_hole = handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const format = req.headers.get("x-format") ?? "";
    \\  let kind = "other";
    \\  if (format === "json") {
    \\    kind = "json";
    \\  } else if (format === "text") {
    \\    kind = "text";
    \\  }
    \\  return hole();
    \\}
    \\
;

const header_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = header_reference },
};

const header_hole_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = header_hole },
};

const header_intent: codegen.IntentCheck = .{
    .tests_jsonl =
    \\{"type":"test","name":"the json format is classified"}
    \\{"type":"request","method":"POST","url":"/classify","headers":{"x-format":"json"},"body":""}
    \\{"type":"expect","status":200,"body":"{\"kind\":\"json\"}"}
    \\{"type":"test","name":"the text format is classified"}
    \\{"type":"request","method":"POST","url":"/classify","headers":{"x-format":"text"},"body":""}
    \\{"type":"expect","status":200,"body":"{\"kind\":\"text\"}"}
    \\{"type":"test","name":"an absent format is other"}
    \\{"type":"request","method":"POST","url":"/classify","headers":{},"body":""}
    \\{"type":"expect","status":200,"body":"{\"kind\":\"other\"}"}
    \\{"type":"test","name":"an unknown format is other"}
    \\{"type":"request","method":"POST","url":"/classify","headers":{"x-format":"xml"},"body":""}
    \\{"type":"expect","status":200,"body":"{\"kind\":\"other\"}"}
    \\{"type":"test","name":"a wrong method is rejected"}
    \\{"type":"request","method":"GET","url":"/classify","headers":{},"body":""}
    \\{"type":"expect","status":405,"body":"{\"error\":\"method_not_allowed\"}"}
    \\
    ,
};

const greeting_reference = handler_signature ++
    \\  if (req.method !== "GET") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const name = req.query.name;
    \\  if (name === undefined) {
    \\    return Response.json({ error: "name_required" }, { status: 400 });
    \\  }
    \\  const prefix = req.query.prefix;
    \\  let greeting = name;
    \\  if (prefix !== undefined) {
    \\    greeting = [prefix, name].join(" ");
    \\  }
    \\  return Response.json({ greeting: greeting });
    \\}
    \\
;

const greeting_hole = handler_signature ++
    \\  if (req.method !== "GET") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const name = req.query.name;
    \\  if (name === undefined) {
    \\    return Response.json({ error: "name_required" }, { status: 400 });
    \\  }
    \\  const prefix = req.query.prefix;
    \\  let greeting = name;
    \\  if (prefix !== undefined) {
    \\    greeting = [prefix, name].join(" ");
    \\  }
    \\  return hole();
    \\}
    \\
;

const greeting_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = greeting_reference },
};

const greeting_hole_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = greeting_hole },
};

const greeting_intent: codegen.IntentCheck = .{
    .tests_jsonl =
    \\{"type":"test","name":"name and prefix are combined"}
    \\{"type":"request","method":"GET","url":"/greet?name=Ada&prefix=Dr.","headers":{},"body":""}
    \\{"type":"expect","status":200,"body":"{\"greeting\":\"Dr. Ada\"}"}
    \\{"type":"test","name":"name works without a prefix"}
    \\{"type":"request","method":"GET","url":"/greet?name=Ada","headers":{},"body":""}
    \\{"type":"expect","status":200,"body":"{\"greeting\":\"Ada\"}"}
    \\{"type":"test","name":"an empty query is rejected"}
    \\{"type":"request","method":"GET","url":"/greet","headers":{},"body":""}
    \\{"type":"expect","status":400,"body":"{\"error\":\"name_required\"}"}
    \\{"type":"test","name":"a prefix without a name is rejected"}
    \\{"type":"request","method":"GET","url":"/greet?prefix=Dr.","headers":{},"body":""}
    \\{"type":"expect","status":400,"body":"{\"error\":\"name_required\"}"}
    \\{"type":"test","name":"a wrong method is rejected"}
    \\{"type":"request","method":"POST","url":"/greet?name=Ada","headers":{},"body":""}
    \\{"type":"expect","status":405,"body":"{\"error\":\"method_not_allowed\"}"}
    \\
    ,
};

const preview_reference = handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const body = req.body ?? "";
    \\  if (body === "") {
    \\    return Response.json({ error: "body_required" }, { status: 400 });
    \\  }
    \\  const preview = body.slice(0, 8).toUpperCase();
    \\  return Response.json({ preview: preview });
    \\}
    \\
;

const preview_hole = handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const body = req.body ?? "";
    \\  if (body === "") {
    \\    return Response.json({ error: "body_required" }, { status: 400 });
    \\  }
    \\  const preview = body.slice(0, 8).toUpperCase();
    \\  return hole();
    \\}
    \\
;

const preview_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = preview_reference },
};

const preview_hole_files = [_]codegen_types.SeedFile{
    .{ .path = "handler.ts", .bytes = preview_hole },
};

const preview_intent: codegen.IntentCheck = .{
    .tests_jsonl =
    \\{"type":"test","name":"short content is uppercased"}
    \\{"type":"request","method":"POST","url":"/preview","headers":{},"body":"Red"}
    \\{"type":"expect","status":200,"body":"{\"preview\":\"RED\"}"}
    \\{"type":"test","name":"long content is bounded before uppercasing"}
    \\{"type":"request","method":"POST","url":"/preview","headers":{},"body":"abcdefghijk"}
    \\{"type":"expect","status":200,"body":"{\"preview\":\"ABCDEFGH\"}"}
    \\{"type":"test","name":"an empty body is rejected"}
    \\{"type":"request","method":"POST","url":"/preview","headers":{},"body":""}
    \\{"type":"expect","status":400,"body":"{\"error\":\"body_required\"}"}
    \\{"type":"test","name":"a wrong method is rejected"}
    \\{"type":"request","method":"GET","url":"/preview","headers":{},"body":""}
    \\{"type":"expect","status":405,"body":"{\"error\":\"method_not_allowed\"}"}
    \\
    ,
};

const label_helper =
    \\export structural LabelText = string;
    \\export structural NormalizedLabel = string;
    \\
    \\export function normalizeLabel(text: LabelText): NormalizedLabel {
    \\  return text.trim().toLowerCase();
    \\}
    \\
;

const label_reference =
    \\import { normalizeLabel } from "./lib/label.ts";
    \\
++ handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const body = req.body ?? "";
    \\  if (body === "") {
    \\    return Response.json({ error: "body_required" }, { status: 400 });
    \\  }
    \\  return Response.json({ label: normalizeLabel(body) });
    \\}
    \\
;

const label_hole =
    \\import { normalizeLabel } from "./lib/label.ts";
    \\
++ handler_signature ++
    \\  if (req.method !== "POST") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  const body = req.body ?? "";
    \\  if (body === "") {
    \\    return Response.json({ error: "body_required" }, { status: 400 });
    \\  }
    \\  return hole();
    \\}
    \\
;

const label_files = [_]codegen_types.SeedFile{
    .{ .path = "lib/label.ts", .bytes = label_helper },
    .{ .path = "handler.ts", .bytes = label_reference },
};

const label_whole_seed_files = [_]codegen_types.SeedFile{
    .{ .path = "lib/label.ts", .bytes = label_helper },
};

const label_hole_seed_files = [_]codegen_types.SeedFile{
    .{ .path = "lib/label.ts", .bytes = label_helper },
    .{ .path = "handler.ts", .bytes = label_hole },
};

const label_intent: codegen.IntentCheck = .{
    .tests_jsonl =
    \\{"type":"test","name":"a padded label is normalized"}
    \\{"type":"request","method":"POST","url":"/label","headers":{},"body":" Team "}
    \\{"type":"expect","status":200,"body":"{\"label\":\"team\"}"}
    \\{"type":"test","name":"a mixed-case label is normalized"}
    \\{"type":"request","method":"POST","url":"/label","headers":{},"body":"MIXED_case"}
    \\{"type":"expect","status":200,"body":"{\"label\":\"mixed_case\"}"}
    \\{"type":"test","name":"an empty body is rejected"}
    \\{"type":"request","method":"POST","url":"/label","headers":{},"body":""}
    \\{"type":"expect","status":400,"body":"{\"error\":\"body_required\"}"}
    \\{"type":"test","name":"a wrong method is rejected"}
    \\{"type":"request","method":"GET","url":"/label","headers":{},"body":""}
    \\{"type":"expect","status":405,"body":"{\"error\":\"method_not_allowed\"}"}
    \\
    ,
};

pub const tasks = [_]Task{
    .{
        .id = "request-header-classification-whole-file",
        .family = "request-header-classification",
        .mode = .whole_file,
        .prompt = "Create handler.ts to classify POST requests by the x-format request header. Reject every other method with status 405 and exact JSON {\"error\":\"method_not_allowed\"}. Use req.headers.get directly. Return exact JSON {\"kind\":\"json\"} only when x-format is exactly json, {\"kind\":\"text\"} only when it is exactly text, and {\"kind\":\"other\"} when it is absent or has any other value. The request body, including an empty body, does not change classification. Use this exact handler return type: " ++ proof_capsule ++ ".",
        .reference_files = &header_files,
        .intent = header_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "request-header-classification-holes",
        .family = "request-header-classification",
        .mode = .holes,
        .prompt = "handler.ts classifies POST requests by the x-format request header and has one hole() for its success response. Fill it with exact JSON containing the computed kind. The existing branches use req.headers.get and classify exactly json as json, exactly text as text, and an absent or different value as other. Preserve the exact 405 method error and all declared proof properties. Use zts_expert_query operation holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &header_hole_files,
        .reference_files = &header_files,
        .intent = header_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "optional-query-greeting-whole-file",
        .family = "optional-query-greeting",
        .mode = .whole_file,
        .prompt = "Create handler.ts to greet GET requests. Reject every other method with status 405 and exact JSON {\"error\":\"method_not_allowed\"}. Require the name query value. If it is absent, return status 400 and exact JSON {\"error\":\"name_required\"}. Return {\"greeting\":name} when prefix is absent. When prefix exists, join prefix, one space, and name. Use this exact handler return type: " ++ proof_capsule ++ ".",
        .reference_files = &greeting_files,
        .intent = greeting_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "optional-query-greeting-holes",
        .family = "optional-query-greeting",
        .mode = .holes,
        .prompt = "handler.ts implements GET /greet and has one hole() for its success response. Fill it with exact JSON containing the computed greeting. The existing code requires name, optionally prefixes it with prefix and one space, returns the exact 400 name_required error for a missing name, and returns the exact 405 method error for other methods. Preserve all declared proof properties. Use zts_expert_query operation holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &greeting_hole_files,
        .reference_files = &greeting_files,
        .intent = greeting_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "bounded-text-preview-whole-file",
        .family = "bounded-text-preview",
        .mode = .whole_file,
        .prompt = "Create handler.ts to preview POST request bodies. Reject every other method with status 405 and exact JSON {\"error\":\"method_not_allowed\"}. Reject an empty body with status 400 and exact JSON {\"error\":\"body_required\"}. Return exact JSON with preview set to body.slice(0, 8).toUpperCase(). Use this exact handler return type: " ++ proof_capsule ++ ".",
        .reference_files = &preview_files,
        .intent = preview_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "bounded-text-preview-holes",
        .family = "bounded-text-preview",
        .mode = .holes,
        .prompt = "handler.ts previews POST request bodies and has one hole() for its success response. Fill it with exact JSON containing the computed preview. The existing code rejects other methods with the exact 405 error, rejects an empty body with the exact 400 body_required error, takes the first 8 characters, and converts them to uppercase. Preserve all declared proof properties. Use zts_expert_query operation holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &preview_hole_files,
        .reference_files = &preview_files,
        .intent = preview_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "seeded-label-helper-whole-file",
        .family = "seeded-label-helper",
        .mode = .whole_file,
        .prompt = "lib/label.ts is a frozen helper. Its normalizeLabel function trims a string and converts it to lowercase. Create only handler.ts to handle POST request bodies and import that helper. Reject every other method with status 405 and exact JSON {\"error\":\"method_not_allowed\"}. Reject an empty body with status 400 and exact JSON {\"error\":\"body_required\"}. For a non-empty body, return exact JSON {\"label\":normalizeLabel(body)}. Use this exact handler return type: " ++ proof_capsule ++ ".",
        .seed_files = &label_whole_seed_files,
        .reference_files = &label_files,
        .intent = label_intent,
        .required_properties = &required_properties,
    },
    .{
        .id = "seeded-label-helper-holes",
        .family = "seeded-label-helper",
        .mode = .holes,
        .prompt = "lib/label.ts is a frozen helper. Its normalizeLabel function trims a string and converts it to lowercase. handler.ts imports it and has one hole() for its success response. Fill the hole with exact JSON {\"label\":normalizeLabel(body)}. Preserve the exact 405 method error, the exact 400 body_required error, the helper file, and all declared proof properties. Use zts_expert_query operation holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &label_hole_seed_files,
        .reference_files = &label_files,
        .intent = label_intent,
        .required_properties = &required_properties,
    },
};

pub const ValidationError = error{
    EmptyTasks,
    EmptyTaskId,
    EmptyFamily,
    EmptyPrompt,
    EmptyIntent,
    MissingReferenceFiles,
    MissingReferenceHandler,
    EmptyReferenceFile,
    DuplicateReferencePath,
    ReferenceContainsHole,
    ReferenceOmitsRequiredProperty,
    EmptySeedFile,
    DuplicateSeedPath,
    SeedContainsAcceptanceFile,
    MissingHoleSeed,
    UnexpectedWholeFileHandler,
    WrongHoleCount,
    HoleSeedOmitsRequiredProperty,
    MissingRequiredProperties,
    EmptyRequiredProperty,
    DuplicateRequiredProperty,
    DuplicateTaskId,
    DuplicateFamilyMode,
    MissingPairedMode,
    PairedReferenceMismatch,
    PairedIntentMismatch,
    PairedPropertiesMismatch,
};

pub fn validate() !void {
    try validateTasks(&tasks);
}

pub fn validateTasks(items: []const Task) ValidationError!void {
    if (items.len == 0) return error.EmptyTasks;

    for (items, 0..) |task, task_index| {
        if (isBlank(task.id)) return error.EmptyTaskId;
        if (isBlank(task.family)) return error.EmptyFamily;
        if (isBlank(task.prompt)) return error.EmptyPrompt;
        if (isBlank(task.intent.tests_jsonl)) return error.EmptyIntent;
        if (task.reference_files.len == 0) return error.MissingReferenceFiles;
        if (task.required_properties.len == 0) return error.MissingRequiredProperties;

        for (items[0..task_index]) |earlier| {
            if (std.mem.eql(u8, task.id, earlier.id)) return error.DuplicateTaskId;
            if (task.mode == earlier.mode and std.mem.eql(u8, task.family, earlier.family)) {
                return error.DuplicateFamilyMode;
            }
        }

        var has_reference_handler = false;
        for (task.reference_files, 0..) |file, file_index| {
            if (isBlank(file.path) or isBlank(file.bytes)) return error.EmptyReferenceFile;
            if (std.mem.eql(u8, file.path, task.intent.handler_path)) {
                has_reference_handler = true;
                for (task.required_properties) |property| {
                    if (std.mem.indexOf(u8, file.bytes, property) == null) {
                        return error.ReferenceOmitsRequiredProperty;
                    }
                }
            }
            if (std.mem.count(u8, file.bytes, "hole()") != 0) return error.ReferenceContainsHole;
            for (task.reference_files[0..file_index]) |earlier| {
                if (std.mem.eql(u8, file.path, earlier.path)) return error.DuplicateReferencePath;
            }
        }
        if (!has_reference_handler) return error.MissingReferenceHandler;

        var hole_count: usize = 0;
        var has_seed_handler = false;
        for (task.seed_files, 0..) |file, file_index| {
            if (isBlank(file.path) or isBlank(file.bytes)) return error.EmptySeedFile;
            if (std.mem.endsWith(u8, file.path, ".test.jsonl")) return error.SeedContainsAcceptanceFile;
            if (std.mem.eql(u8, file.path, task.intent.handler_path)) {
                has_seed_handler = true;
                if (task.mode == .holes) {
                    for (task.required_properties) |property| {
                        if (std.mem.indexOf(u8, file.bytes, property) == null) {
                            return error.HoleSeedOmitsRequiredProperty;
                        }
                    }
                }
            }
            hole_count += std.mem.count(u8, file.bytes, "hole()");
            for (task.seed_files[0..file_index]) |earlier| {
                if (std.mem.eql(u8, file.path, earlier.path)) return error.DuplicateSeedPath;
            }
        }
        switch (task.mode) {
            .whole_file => if (has_seed_handler) return error.UnexpectedWholeFileHandler,
            .holes => {
                if (!has_seed_handler) return error.MissingHoleSeed;
                if (hole_count != 1) return error.WrongHoleCount;
            },
        }

        for (task.required_properties, 0..) |property, property_index| {
            if (isBlank(property)) return error.EmptyRequiredProperty;
            for (task.required_properties[0..property_index]) |earlier| {
                if (std.mem.eql(u8, property, earlier)) return error.DuplicateRequiredProperty;
            }
        }

        const paired = findPairedTask(items, task) orelse return error.MissingPairedMode;
        if (!filesEqual(task.reference_files, paired.reference_files)) {
            return error.PairedReferenceMismatch;
        }
        if (!intentEqual(task.intent, paired.intent)) return error.PairedIntentMismatch;
        if (!stringsEqual(task.required_properties, paired.required_properties)) {
            return error.PairedPropertiesMismatch;
        }
    }
}

fn findPairedTask(items: []const Task, task: Task) ?Task {
    for (items) |candidate| {
        if (candidate.mode != task.mode and std.mem.eql(u8, candidate.family, task.family)) {
            return candidate;
        }
    }
    return null;
}

fn filesEqual(left: []const codegen_types.SeedFile, right: []const codegen_types.SeedFile) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_file, right_file| {
        if (!std.mem.eql(u8, left_file.path, right_file.path)) return false;
        if (!std.mem.eql(u8, left_file.bytes, right_file.bytes)) return false;
    }
    return true;
}

fn intentEqual(left: codegen.IntentCheck, right: codegen.IntentCheck) bool {
    return std.mem.eql(u8, left.tests_jsonl, right.tests_jsonl) and
        std.mem.eql(u8, left.handler_path, right.handler_path) and
        optionalStringEqual(left.zttp_json, right.zttp_json) and
        filesEqual(left.runtime_files, right.runtime_files);
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn stringsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn isBlank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

test "reach corpus is structurally valid" {
    try validate();
    try std.testing.expectEqual(@as(usize, 8), tasks.len);

    const families = [_][]const u8{
        "request-header-classification",
        "optional-query-greeting",
        "bounded-text-preview",
        "seeded-label-helper",
    };
    for (families) |family| {
        var whole_count: usize = 0;
        var hole_count: usize = 0;
        for (tasks) |task| {
            if (!std.mem.eql(u8, task.family, family)) continue;
            switch (task.mode) {
                .whole_file => whole_count += 1,
                .holes => hole_count += 1,
            }
        }
        try std.testing.expectEqual(@as(usize, 1), whole_count);
        try std.testing.expectEqual(@as(usize, 1), hole_count);
    }
}

test "validation rejects an empty acceptance spec" {
    var invalid = tasks;
    invalid[0].intent.tests_jsonl = "";
    try std.testing.expectError(error.EmptyIntent, validateTasks(&invalid));
}

test "validation rejects an empty suite" {
    try std.testing.expectError(error.EmptyTasks, validateTasks(&.{}));
}

test "validation rejects duplicate task ids" {
    var invalid = tasks;
    invalid[1].id = invalid[0].id;
    try std.testing.expectError(error.DuplicateTaskId, validateTasks(&invalid));
}

test "validation rejects a missing input mode" {
    try std.testing.expectError(error.MissingPairedMode, validateTasks(tasks[0 .. tasks.len - 1]));
}

test "validation rejects missing reference data" {
    var invalid = tasks;
    invalid[0].reference_files = &.{};
    try std.testing.expectError(error.MissingReferenceFiles, validateTasks(&invalid));
}

test "validation rejects reference drift between input modes" {
    var invalid = tasks;
    invalid[1].reference_files = invalid[2].reference_files;
    try std.testing.expectError(error.PairedReferenceMismatch, validateTasks(&invalid));
}

test "validation rejects acceptance drift between input modes" {
    var invalid = tasks;
    invalid[1].intent = invalid[2].intent;
    try std.testing.expectError(error.PairedIntentMismatch, validateTasks(&invalid));
}

test "validation rejects property drift between input modes" {
    var invalid = tasks;
    invalid[1].required_properties = invalid[1].required_properties[0 .. required_properties.len - 1];
    try std.testing.expectError(error.PairedPropertiesMismatch, validateTasks(&invalid));
}
