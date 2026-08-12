//! JSON serializer for `HandlerContract`. Wire-format owner — any change here
//! must round-trip through `parseFromJson` (handler_contract.zig). Extracted
//! from handler_contract.zig as the first step of splitting that 7k-line file
//! along its natural seams.

const std = @import("std");
const json_utils = @import("zts-base").json_utils;
const handler_contract = @import("handler_contract.zig");
const contract_types = @import("contract_types.zig");

const HandlerContract = handler_contract.HandlerContract;
const ApiParamInfo = handler_contract.ApiParamInfo;
const ApiBodyInfo = handler_contract.ApiBodyInfo;
const ApiResponseInfo = handler_contract.ApiResponseInfo;
const ServiceCallInfo = handler_contract.ServiceCallInfo;
const CapabilityMatrix = contract_types.CapabilityMatrix;

const writeJsonString = json_utils.writeJsonString;

const JsonVersion = enum { v1, v2 };

/// Write the contract as JSON to a writer.
pub fn writeContractJson(contract: *const HandlerContract, writer: anytype) !void {
    return writeContractJsonVersion(.v1, contract, writer);
}

/// Version 2: the same contract, snake_case keys, for the version-2 agent wire.
pub fn writeContractJsonV2(contract: *const HandlerContract, writer: anytype) !void {
    return writeContractJsonVersion(.v2, contract, writer);
}

fn writeContractJsonVersion(
    comptime json_version: JsonVersion,
    contract: *const HandlerContract,
    writer: anytype,
) !void {
    @setEvalBranchQuota(10_000);
    try writer.writeAll("{\n");

    // version
    try writer.print("  \"version\": {d},\n", .{if (json_version == .v1) contract.version else 2});

    // handler
    try writer.writeAll("  \"handler\": {\n");
    try writer.writeAll("    \"path\": ");
    try writeJsonString(writer, contract.handler.path);
    try writer.writeAll(",\n");
    try writer.print("    \"line\": {d},\n", .{contract.handler.line});
    try writer.print("    \"column\": {d}\n", .{contract.handler.column});
    try writer.writeAll("  },\n");

    // routes
    try writer.writeAll("  \"routes\": [");
    for (contract.routes.items, 0..) |route, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"pattern\": ");
        try writeJsonString(writer, route.pattern);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"type\": ");
        try writeJsonString(writer, route.route_type);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"field\": ");
        try writeJsonString(writer, route.field);
        try writer.writeAll(",\n");
        try writer.print("      \"status\": {d},\n", .{route.status});
        try writer.writeAll("      \"" ++ comptime contractKey(json_version, "contentType") ++ "\": ");
        try writeJsonString(writer, route.content_type);
        try writer.writeAll(",\n");
        try writer.print("      \"aot\": {s}\n", .{if (route.aot) "true" else "false"});
        try writer.writeAll("    }");
    }
    if (contract.routes.items.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("],\n");

    // modules
    try writer.writeAll("  \"modules\": [");
    for (contract.modules.items, 0..) |mod, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, mod);
    }
    try writer.writeAll("],\n");

    try writer.writeAll("  \"sandbox\": {\n");
    // Every producer sets `capabilities` before writing, so the null case here
    // only arises for a contract parsed from a pre-sandbox document and then
    // re-serialized. Write an empty matrix for it rather than omitting the
    // keys: the sandbox block's other fields must still be written, and a
    // sandbox block without a `capabilities` key is a shape no reader has ever
    // had to handle.
    const caps = contract.capabilities orelse CapabilityMatrix.empty;
    try writer.writeAll("    \"capabilities\": [");
    for (caps.slice(), 0..) |cap, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, @tagName(cap));
    }
    try writer.writeAll("],\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "capabilityHash") ++ "\": ");
    try json_utils.writeJsonHex(writer, caps.hash);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "declaredBudget") ++ "\": [");
    for (contract.capability_budget.slice(), 0..) |cap, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, @tagName(cap));
    }
    try writer.writeAll("],\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "policyHash") ++ "\": ");
    try json_utils.writeJsonHex(writer, contract.policy_hash);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "wasmPolicyHash") ++ "\": ");
    try json_utils.writeJsonHex(writer, contract.wasm_policy_hash);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "artifactSha256") ++ "\": ");
    try json_utils.writeJsonHex(writer, contract.artifact_sha256);
    try writer.writeAll("\n");
    try writer.writeAll("  },\n");

    // functions
    try writer.writeAll("  \"functions\": {");
    for (contract.functions.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, entry.module);
        try writer.writeAll(": [");
        for (entry.names.items, 0..) |name, j| {
            if (j > 0) try writer.writeAll(", ");
            try writeJsonString(writer, name);
        }
        try writer.writeAll("]");
    }
    if (contract.functions.items.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("},\n");

    // env
    try writer.writeAll("  \"env\": {\n");
    try writer.writeAll("    \"literal\": [");
    for (contract.env.literal.items, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, name);
    }
    try writer.writeAll("],\n");
    try writer.print("    \"dynamic\": {s}\n", .{if (contract.env.dynamic) "true" else "false"});
    try writer.writeAll("  },\n");

    // egress
    try writer.writeAll("  \"egress\": {\n");
    try writer.writeAll("    \"hosts\": [");
    for (contract.egress.hosts.items, 0..) |host, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, host);
    }
    try writer.writeAll("],\n");
    if (contract.egress.urls.items.len > 0) {
        try writer.writeAll("    \"urls\": [");
        for (contract.egress.urls.items, 0..) |url, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeJsonString(writer, url);
        }
        try writer.writeAll("],\n");
    }
    try writer.print("    \"dynamic\": {s}\n", .{if (contract.egress.dynamic) "true" else "false"});
    try writer.writeAll("  },\n");

    // serviceCalls
    try writer.writeAll("  \"" ++ comptime contractKey(json_version, "serviceCalls") ++ "\": [");
    for (contract.service_calls.items, 0..) |service_call, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"service\": ");
        try writeJsonString(writer, service_call.service);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"route\": ");
        try writeJsonString(writer, service_call.route_pattern);
        try writer.writeAll(",\n");
        try writer.print("      \"dynamic\": {s},\n", .{if (service_call.dynamic) "true" else "false"});
        try writeKnownListJson(json_version, writer, "pathParams", "pathParamsDynamic", service_call.path_params);
        try writeKnownListJson(json_version, writer, "queryKeys", "queryDynamic", service_call.query_keys);
        try writeKnownListJson(json_version, writer, "headerKeys", "headerDynamic", service_call.header_keys);
        try writer.print("      \"" ++ comptime contractKey(json_version, "hasBody") ++ "\": {s},\n", .{if (service_call.body.isPresent()) "true" else "false"});
        try writer.print("      \"" ++ comptime contractKey(json_version, "bodyDynamic") ++ "\": {s}\n", .{if (service_call.body.isDynamic()) "true" else "false"});
        try writer.writeAll("    }");
    }
    if (contract.service_calls.items.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("],\n");

    // workflowCalls (zttp:workflow call/saga/fanout targets resolved by the system linker)
    try writer.writeAll("  \"" ++ comptime contractKey(json_version, "workflowCalls") ++ "\": [");
    for (contract.workflow_calls.items, 0..) |wc, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"target\": ");
        try writeJsonString(writer, wc.target);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"route\": ");
        try writeJsonString(writer, wc.route_pattern);
        try writer.writeAll(",\n");
        try writer.print("      \"dynamic\": {s}\n", .{if (wc.dynamic) "true" else "false"});
        try writer.writeAll("    }");
    }
    if (contract.workflow_calls.items.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("],\n");

    // affordances (hypermedia resource() links resolved by the system linker)
    try writer.writeAll("  \"affordances\": [");
    for (contract.affordances.items, 0..) |aff, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"rel\": ");
        try writeJsonString(writer, aff.rel);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"method\": ");
        try writeJsonString(writer, aff.method);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"href\": ");
        try writeJsonString(writer, aff.href);
        try writer.writeAll(",\n");
        try writer.print("      \"templated\": {s},\n", .{if (aff.templated) "true" else "false"});
        try writer.print("      \"dynamic\": {s}\n", .{if (aff.dynamic) "true" else "false"});
        try writer.writeAll("    }");
    }
    if (contract.affordances.items.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("],\n");
    try writer.print("  \"" ++ comptime contractKey(json_version, "affordancesDynamic") ++ "\": {s},\n", .{if (contract.affordances_dynamic) "true" else "false"});

    // cache
    try writer.writeAll("  \"cache\": {\n");
    try writer.writeAll("    \"namespaces\": [");
    for (contract.cache.namespaces.items, 0..) |ns, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, ns);
    }
    try writer.writeAll("],\n");
    try writer.print("    \"dynamic\": {s}\n", .{if (contract.cache.dynamic) "true" else "false"});
    try writer.writeAll("  },\n");

    // sql
    try writer.writeAll("  \"sql\": {\n");
    try writer.writeAll("    \"backend\": \"sqlite\",\n");
    try writer.writeAll("    \"queries\": [");
    for (contract.sql.queries.items, 0..) |query, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"name\": ");
        try writeJsonString(writer, query.name);
        try writer.writeAll(",\n");
        // Persist the statement text: it is the identity discriminator that lets
        // `prove` classify a same-name query whose body changed as breaking.
        try writer.writeAll("        \"statement\": ");
        try writeJsonString(writer, query.statement);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"operation\": ");
        try writeJsonString(writer, query.operation);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"tables\": [");
        for (query.tables.items, 0..) |table, j| {
            if (j > 0) try writer.writeAll(", ");
            try writeJsonString(writer, table);
        }
        try writer.writeAll("]\n");
        try writer.writeAll("      }");
    }
    if (contract.sql.queries.items.len > 0) {
        try writer.writeAll("\n    ");
    }
    try writer.writeAll("],\n");
    try writer.print("    \"dynamic\": {s}\n", .{if (contract.sql.dynamic) "true" else "false"});
    try writer.writeAll("  },\n");

    // durable
    try writer.writeAll("  \"durable\": {\n");
    try writer.print("    \"used\": {s},\n", .{if (contract.durable.used) "true" else "false"});
    try writer.writeAll("    \"keys\": {\n");
    try writer.writeAll("      \"literal\": [");
    for (contract.durable.keys.literal.items, 0..) |key, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, key);
    }
    try writer.writeAll("],\n");
    try writer.print("      \"dynamic\": {s}\n", .{if (contract.durable.keys.dynamic) "true" else "false"});
    try writer.writeAll("    },\n");
    try writer.writeAll("    \"steps\": [");
    for (contract.durable.steps.items, 0..) |step, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, step);
    }
    try writer.writeAll("],\n");
    try writer.print("    \"timers\": {s},\n", .{if (contract.durable.timers) "true" else "false"});
    try writer.writeAll("    \"signals\": {\n");
    try writer.writeAll("      \"literal\": [");
    for (contract.durable.signals.literal.items, 0..) |signal, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, signal);
    }
    try writer.writeAll("],\n");
    try writer.print("      \"dynamic\": {s}\n", .{if (contract.durable.signals.dynamic) "true" else "false"});
    try writer.writeAll("    },\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "producerKeys") ++ "\": {\n");
    try writer.writeAll("      \"literal\": [");
    for (contract.durable.producer_keys.literal.items, 0..) |key, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, key);
    }
    try writer.writeAll("],\n");
    try writer.print("      \"dynamic\": {s}\n", .{if (contract.durable.producer_keys.dynamic) "true" else "false"});
    try writer.writeAll("    },\n");
    try writer.writeAll("    \"workflow\": {\n");
    try writer.writeAll("      \"" ++ comptime contractKey(json_version, "workflowId") ++ "\": ");
    if (contract.durable.workflow.workflow_id) |workflow_id| {
        try writeJsonString(writer, workflow_id);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("      \"" ++ comptime contractKey(json_version, "proofLevel") ++ "\": ");
    try writeJsonString(writer, contract.durable.workflow.proof_level.toString());
    try writer.writeAll(",\n");
    try writer.writeAll("      \"properties\": {\n");
    try writer.print("        \"" ++ comptime contractKey(json_version, "retrySafe") ++ "\": {s},\n", .{if (contract.durable.workflow.properties.retry_safe) "true" else "false"});
    try writer.print("        \"idempotent\": {s},\n", .{if (contract.durable.workflow.properties.idempotent) "true" else "false"});
    try writer.print("        \"" ++ comptime contractKey(json_version, "faultCovered") ++ "\": {s},\n", .{if (contract.durable.workflow.properties.fault_covered) "true" else "false"});
    try writer.writeAll("        \"reasons\": [");
    for (contract.durable.workflow.properties.reasons.items, 0..) |reason, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, reason);
    }
    try writer.writeAll("]\n");
    try writer.writeAll("      },\n");
    try writer.writeAll("      \"nodes\": [");
    for (contract.durable.workflow.nodes.items, 0..) |node, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n        {\n");
        try writer.writeAll("          \"id\": ");
        try writeJsonString(writer, node.id);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"kind\": ");
        try writeJsonString(writer, node.kind.toString());
        try writer.writeAll(",\n");
        try writer.writeAll("          \"label\": ");
        try writeJsonString(writer, node.label);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"detail\": ");
        if (node.detail) |detail| {
            try writeJsonString(writer, detail);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");
        try writer.writeAll("          \"status\": ");
        if (node.status) |status| {
            try writer.print("{d}", .{status});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("\n        }");
    }
    if (contract.durable.workflow.nodes.items.len > 0) {
        try writer.writeAll("\n      ");
    }
    try writer.writeAll("],\n");
    try writer.writeAll("      \"edges\": [");
    for (contract.durable.workflow.edges.items, 0..) |edge, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n        {\n");
        try writer.writeAll("          \"from\": ");
        try writeJsonString(writer, edge.from);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"to\": ");
        try writeJsonString(writer, edge.to);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"condition\": ");
        if (edge.condition) |condition| {
            try writeJsonString(writer, condition);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("\n        }");
    }
    if (contract.durable.workflow.edges.items.len > 0) {
        try writer.writeAll("\n      ");
    }
    try writer.writeAll("]\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  },\n");

    // scope
    try writer.writeAll("  \"scope\": {\n");
    try writer.print("    \"used\": {s},\n", .{if (contract.scope.used) "true" else "false"});
    try writer.writeAll("    \"names\": [");
    for (contract.scope.names.items, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, name);
    }
    try writer.writeAll("],\n");
    try writer.print("    \"dynamic\": {s},\n", .{if (contract.scope.dynamic) "true" else "false"});
    try writer.print("    \"" ++ comptime contractKey(json_version, "maxDepth") ++ "\": {d}\n", .{contract.scope.max_depth});
    try writer.writeAll("  },\n");

    // api
    try writer.writeAll("  \"api\": {\n");

    try writer.writeAll("    \"schemas\": [");
    for (contract.api.schemas.items, 0..) |schema, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"name\": ");
        try writeJsonString(writer, schema.name);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"schema\": ");
        try writer.writeAll(schema.schema_json);
        try writer.writeAll("\n      }");
    }
    if (contract.api.schemas.items.len > 0) {
        try writer.writeAll("\n    ");
    }
    try writer.writeAll("],\n");

    try writer.writeAll("    \"requests\": {\n");
    try writer.writeAll("      \"" ++ comptime contractKey(json_version, "schemaRefs") ++ "\": [");
    for (contract.api.requests.schema_refs.items, 0..) |schema_ref, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, schema_ref);
    }
    try writer.writeAll("],\n");
    try writer.print("      \"dynamic\": {s}\n", .{if (contract.api.requests.dynamic) "true" else "false"});
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"auth\": {\n");
    try writer.print("      \"bearer\": {s},\n", .{if (contract.api.auth.bearer) "true" else "false"});
    try writer.print("      \"jwt\": {s}\n", .{if (contract.api.auth.jwt) "true" else "false"});
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"routes\": [");
    for (contract.api.routes.items, 0..) |route, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"method\": ");
        try writeJsonString(writer, route.method);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"path\": ");
        try writeJsonString(writer, route.path);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "requestSchemaRefs") ++ "\": [");
        for (route.request_schema_refs.items, 0..) |schema_ref, j| {
            if (j > 0) try writer.writeAll(", ");
            try writeJsonString(writer, schema_ref);
        }
        try writer.writeAll("],\n");
        try writer.print("        \"" ++ comptime contractKey(json_version, "requestSchemaDynamic") ++ "\": {s},\n", .{if (route.request_schema_dynamic) "true" else "false"});
        try writer.print("        \"" ++ comptime contractKey(json_version, "requiresBearer") ++ "\": {s},\n", .{if (route.requires_bearer) "true" else "false"});
        try writer.print("        \"" ++ comptime contractKey(json_version, "requiresJwt") ++ "\": {s},\n", .{if (route.requires_jwt) "true" else "false"});
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "pathParams") ++ "\": [");
        for (route.path_params.items, 0..) |param, j| {
            if (j > 0) try writer.writeAll(",");
            try writeApiParamJson(writer, &param);
        }
        if (route.path_params.items.len > 0) {
            try writer.writeAll("\n        ");
        }
        try writer.writeAll("],\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "queryParams") ++ "\": [");
        for (route.query_params.items, 0..) |param, j| {
            if (j > 0) try writer.writeAll(",");
            try writeApiParamJson(writer, &param);
        }
        if (route.query_params.items.len > 0) {
            try writer.writeAll("\n        ");
        }
        try writer.writeAll("],\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "headerParams") ++ "\": [");
        for (route.header_params.items, 0..) |param, j| {
            if (j > 0) try writer.writeAll(",");
            try writeApiParamJson(writer, &param);
        }
        if (route.header_params.items.len > 0) {
            try writer.writeAll("\n        ");
        }
        try writer.writeAll("],\n");
        try writer.print("        \"" ++ comptime contractKey(json_version, "queryParamsDynamic") ++ "\": {s},\n", .{if (route.query_params_dynamic) "true" else "false"});
        try writer.print("        \"" ++ comptime contractKey(json_version, "headerParamsDynamic") ++ "\": {s},\n", .{if (route.header_params_dynamic) "true" else "false"});
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "requestBodies") ++ "\": [");
        for (route.request_bodies.items, 0..) |body, j| {
            if (j > 0) try writer.writeAll(",");
            try writeApiBodyJson(json_version, writer, &body);
        }
        if (route.request_bodies.items.len > 0) {
            try writer.writeAll("\n        ");
        }
        try writer.writeAll("],\n");
        try writer.print("        \"" ++ comptime contractKey(json_version, "requestBodiesDynamic") ++ "\": {s},\n", .{if (route.request_bodies_dynamic) "true" else "false"});
        try writer.writeAll("        \"responses\": [");
        for (route.responses.items, 0..) |response, j| {
            if (j > 0) try writer.writeAll(",");
            try writeApiResponseJson(json_version, writer, &response);
        }
        if (route.responses.items.len > 0) {
            try writer.writeAll("\n        ");
        }
        try writer.writeAll("],\n");
        try writer.print("        \"" ++ comptime contractKey(json_version, "responsesDynamic") ++ "\": {s},\n", .{if (route.responses_dynamic) "true" else "false"});
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "responseStatus") ++ "\": ");
        if (route.response_status) |status| {
            try writer.print("{d}", .{status});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "responseContentType") ++ "\": ");
        if (route.response_content_type) |content_type| {
            try writeJsonString(writer, content_type);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "responseSchemaRef") ++ "\": ");
        if (route.response_schema_ref) |schema_ref| {
            try writeJsonString(writer, schema_ref);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");
        try writer.writeAll("        \"" ++ comptime contractKey(json_version, "responseSchema") ++ "\": ");
        if (route.response_schema_json) |schema_json| {
            try writer.writeAll(schema_json);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");
        try writer.print("        \"" ++ comptime contractKey(json_version, "responseSchemaDynamic") ++ "\": {s}\n", .{if (route.response_schema_dynamic) "true" else "false"});
        try writer.writeAll("      }");
    }
    if (contract.api.routes.items.len > 0) {
        try writer.writeAll("\n    ");
    }
    try writer.writeAll("],\n");
    try writer.print("    \"" ++ comptime contractKey(json_version, "schemasDynamic") ++ "\": {s},\n", .{if (contract.api.schemas_dynamic) "true" else "false"});
    try writer.print("    \"" ++ comptime contractKey(json_version, "routesDynamic") ++ "\": {s}\n", .{if (contract.api.routes_dynamic) "true" else "false"});
    try writer.writeAll("  },\n");

    // verification (optional)
    if (contract.verification) |v| {
        try writer.writeAll("  \"verification\": {\n");
        try writer.print("    \"" ++ comptime contractKey(json_version, "exhaustiveReturns") ++ "\": {s},\n", .{if (v.exhaustive_returns) "true" else "false"});
        try writer.print("    \"" ++ comptime contractKey(json_version, "resultsSafe") ++ "\": {s},\n", .{if (v.results_safe) "true" else "false"});
        try writer.print("    \"" ++ comptime contractKey(json_version, "unreachableCode") ++ "\": {s},\n", .{if (v.unreachable_code) "true" else "false"});
        try writer.print("    \"" ++ comptime contractKey(json_version, "bytecodeVerified") ++ "\": {s}\n", .{if (v.bytecode_verified) "true" else "false"});
        try writer.writeAll("  },\n");
    } else {
        try writer.writeAll("  \"verification\": null,\n");
    }

    // aot (optional)
    if (contract.aot) |a| {
        try writer.writeAll("  \"aot\": {\n");
        try writer.print("    \"" ++ comptime contractKey(json_version, "patternCount") ++ "\": {d},\n", .{a.pattern_count});
        try writer.print("    \"" ++ comptime contractKey(json_version, "hasDefault") ++ "\": {s}\n", .{if (a.has_default) "true" else "false"});
        try writer.writeAll("  },\n");
    } else {
        try writer.writeAll("  \"aot\": null,\n");
    }

    // faultCoverage (optional)
    if (contract.fault_coverage) |fc| {
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "faultCoverage") ++ "\": {\n");
        try writer.print("    \"" ++ comptime contractKey(json_version, "totalFailable") ++ "\": {d},\n", .{fc.total_failable});
        try writer.print("    \"covered\": {d},\n", .{fc.covered});
        try writer.print("    \"warnings\": {d},\n", .{fc.warnings});
        try writer.print("    \"" ++ comptime contractKey(json_version, "isCovered") ++ "\": {s}\n", .{if (fc.isCovered()) "true" else "false"});
        try writer.writeAll("  },\n");
    } else {
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "faultCoverage") ++ "\": null,\n");
    }

    // rateLimiting (optional)
    if (contract.rate_limiting) |rl| {
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "rateLimiting") ++ "\": {\n");
        try writer.writeAll("    \"namespace\": ");
        try writeJsonString(writer, rl.namespace);
        try writer.print(",\n    \"dynamic\": {s}\n", .{if (rl.dynamic) "true" else "false"});
        try writer.writeAll("  },\n");
    } else {
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "rateLimiting") ++ "\": null,\n");
    }

    // properties (optional)
    if (contract.properties) |p| {
        try writer.writeAll("  \"properties\": {\n");
        try writeBooleanProperties(json_version, p, writer);
        if (p.max_io_depth) |depth| {
            try writer.print("    \"" ++ comptime contractKey(json_version, "maxIoDepth") ++ "\": {d}\n", .{depth});
        } else {
            try writer.writeAll("    \"" ++ comptime contractKey(json_version, "maxIoDepth") ++ "\": null\n");
        }
        try writer.writeAll("  },\n");

        // proven_specs: canonical, ordered list of property names the
        // compiler currently proves true. This is the field cross-build
        // ratchet checks diff against; the unsorted properties object above
        // stays for backwards-compat consumers.
        var spec_buf: [contract_types.HandlerProperties.max_proven_specs]?[]const u8 = undefined;
        const proven_count = p.provenSpecNames(&spec_buf);
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "provenSpecs") ++ "\": [");
        for (spec_buf[0..proven_count], 0..) |name_opt, i| {
            if (name_opt) |nm| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{nm});
            }
        }
        try writer.writeAll("],\n");
    } else {
        try writer.writeAll("  \"properties\": null,\n");
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "provenSpecs") ++ "\": [],\n");
    }

    // intent (optional) - author-declared assertions outside the proof boundary
    if (contract.intent) |intent| {
        try writer.writeAll("  \"intent\": {\n");
        try writer.print("    \"dynamic\": {s},\n", .{if (intent.dynamic) "true" else "false"});
        try writer.writeAll("    \"assertions\": [");
        for (intent.assertions.items, 0..) |assertion, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("\n      {");
            try writer.writeAll("\n        \"name\": ");
            try writeJsonString(writer, assertion.name);
            try writer.writeAll(",\n        \"method\": ");
            try writeJsonString(writer, assertion.method);
            try writer.writeAll(",\n        \"path\": ");
            try writeJsonString(writer, assertion.path);
            try writer.writeAll(",\n        \"" ++ comptime contractKey(json_version, "requestBodyJson") ++ "\": ");
            if (assertion.request_body_json) |b| {
                try writeJsonString(writer, b);
            } else try writer.writeAll("null");
            try writer.writeAll(",\n        \"" ++ comptime contractKey(json_version, "expectedStatus") ++ "\": ");
            if (assertion.expected_status) |s| {
                try writer.print("{d}", .{s});
            } else try writer.writeAll("null");
            try writer.writeAll(",\n        \"" ++ comptime contractKey(json_version, "expectedBodyJson") ++ "\": ");
            if (assertion.expected_body_json) |b| {
                try writeJsonString(writer, b);
            } else try writer.writeAll("null");
            try writer.writeAll(",\n        \"" ++ comptime contractKey(json_version, "expectedHeaders") ++ "\": [");
            for (assertion.expected_headers.items, 0..) |h, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.writeAll("{\"name\": ");
                try writeJsonString(writer, h.name);
                try writer.writeAll(", \"value\": ");
                try writeJsonString(writer, h.value);
                try writer.writeByte('}');
            }
            try writer.writeAll("],");
            try writer.print("\n        \"" ++ comptime contractKey(json_version, "sourceLine") ++ "\": {d},", .{assertion.source_line});
            try writer.print("\n        \"" ++ comptime contractKey(json_version, "sourceColumn") ++ "\": {d}", .{assertion.source_column});
            try writer.writeAll("\n      }");
        }
        if (intent.assertions.items.len > 0) try writer.writeByte('\n');
        try writer.writeAll("    ]\n");
        try writer.writeAll("  },\n");
    } else {
        try writer.writeAll("  \"intent\": null,\n");
    }

    // sagas - every saga([...]) call site found, with its compensation-
    // coverage proof verdict (ZTS510). Empty array when the handler never
    // imports zttp:workflow's saga.
    try writer.writeAll("  \"sagas\": [");
    for (contract.sagas.items, 0..) |saga, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll("\n    {\n");
        try writer.print("      \"dynamic\": {s},\n", .{if (saga.dynamic) "true" else "false"});
        try writer.print("      \"" ++ comptime contractKey(json_version, "compensationProven") ++ "\": {s},\n", .{if (saga.compensationProven()) "true" else "false"});
        try writer.writeAll("      \"steps\": [");
        for (saga.steps.items, 0..) |step, j| {
            if (j > 0) try writer.writeAll(", ");
            try writer.writeAll("{\"name\": ");
            try writeJsonString(writer, step.name);
            try writer.print(", \"" ++ comptime contractKey(json_version, "hasCompensate") ++ "\": {s}}}", .{if (step.has_compensate) "true" else "false"});
        }
        try writer.writeAll("],\n");
        try writer.print("      \"" ++ comptime contractKey(json_version, "sourceLine") ++ "\": {d},\n", .{saga.source_line});
        try writer.print("      \"" ++ comptime contractKey(json_version, "sourceColumn") ++ "\": {d}\n", .{saga.source_column});
        try writer.writeAll("    }");
    }
    if (contract.sagas.items.len > 0) try writer.writeByte('\n');
    try writer.writeAll("  ],\n");

    // behaviors (optional)
    if (contract.behaviors.items.len > 0) {
        try writer.writeAll("  \"behaviors\": [\n");
        for (contract.behaviors.items, 0..) |path, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"method\": ");
            try writeJsonString(writer, path.route_method);
            try writer.writeAll(",\n");
            try writer.writeAll("      \"pattern\": ");
            try writeJsonString(writer, path.route_pattern);
            try writer.writeAll(",\n");
            try writer.print("      \"status\": {d},\n", .{path.response_status});
            try writer.print("      \"" ++ comptime contractKey(json_version, "ioDepth") ++ "\": {d},\n", .{path.io_depth});
            try writer.print("      \"" ++ comptime contractKey(json_version, "failurePath") ++ "\": {s},\n", .{if (path.is_failure_path) "true" else "false"});

            // conditions
            try writer.writeAll("      \"conditions\": [");
            for (path.conditions.items, 0..) |cond, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.writeAll("{\"kind\": ");
                try writeJsonString(writer, @tagName(cond.kind));
                if (cond.module) |m| {
                    try writer.writeAll(", \"module\": ");
                    try writeJsonString(writer, m);
                }
                if (cond.func) |f| {
                    try writer.writeAll(", \"func\": ");
                    try writeJsonString(writer, f);
                }
                if (cond.value) |v| {
                    try writer.writeAll(", \"value\": ");
                    try writeJsonString(writer, v);
                }
                try writer.writeByte('}');
            }
            try writer.writeAll("],\n");

            // io_sequence
            try writer.writeAll("      \"" ++ comptime contractKey(json_version, "ioSequence") ++ "\": [");
            for (path.io_sequence.items, 0..) |io, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.writeAll("{\"module\": ");
                try writeJsonString(writer, io.module);
                try writer.writeAll(", \"func\": ");
                try writeJsonString(writer, io.func);
                if (io.arg_signature) |sig| {
                    try writer.writeAll(", \"args\": ");
                    try writeJsonString(writer, sig);
                }
                try writer.writeByte('}');
            }
            try writer.writeAll("]\n");
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ],\n");
        try writer.print("  \"" ++ comptime contractKey(json_version, "behaviorsExhaustive") ++ "\": {s},\n", .{if (contract.behaviors_exhaustive) "true" else "false"});
    } else {
        try writer.writeAll("  \"behaviors\": [],\n");
        try writer.print("  \"" ++ comptime contractKey(json_version, "behaviorsExhaustive") ++ "\": {s},\n", .{if (contract.behaviors_exhaustive) "true" else "false"});
    }

    // declaredSpecs: effective active spec names. Source `Spec<...>`
    // narrows this set; without one it contains every supported v1 spec.
    try writer.writeAll("  \"" ++ comptime contractKey(json_version, "declaredSpecs") ++ "\": [");
    for (contract.declared_specs.items, 0..) |s, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, s);
    }
    try writer.writeAll("],\n");

    // specDiagnostics: per-spec discharge results emitted by the
    // verifier (ZTS500/501/502). Empty when every declared spec is
    // satisfied.
    try writer.writeAll("  \"" ++ comptime contractKey(json_version, "specDiagnostics") ++ "\": [");
    for (contract.spec_diagnostics.items, 0..) |d, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll("\n    {");
        try writer.writeAll("\n      \"kind\": ");
        try writeJsonString(writer, @tagName(d.kind));
        try writer.writeAll(",\n      \"code\": ");
        try writeJsonString(writer, d.kind.code());
        try writer.writeAll(",\n      \"" ++ comptime contractKey(json_version, "specName") ++ "\": ");
        try writeJsonString(writer, d.spec_name);
        if (d.function) |func| {
            try writer.writeAll(",\n      \"function\": ");
            try writeJsonString(writer, func);
        }
        if (d.incompatible_module) |module_name| {
            try writer.writeAll(",\n      \"" ++ comptime contractKey(json_version, "incompatibleModule") ++ "\": ");
            try writeJsonString(writer, module_name);
        }
        if (d.suggestion) |suggestion| {
            try writer.writeAll(",\n      \"suggestion\": ");
            try writeJsonString(writer, suggestion);
        }
        try writer.writeAll("\n    }");
    }
    if (contract.spec_diagnostics.items.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n");

    // costEnvelope (optional)
    if (contract.cost_envelope) |*envelope| {
        try writeCostEnvelopeJson(json_version, writer, envelope);
    } else {
        try writer.writeAll("  \"" ++ comptime contractKey(json_version, "costEnvelope") ++ "\": null,\n");
    }

    try writeExtensionsJson(json_version, writer, contract);
    try writePartnerContractSections(json_version, writer, contract);

    try writer.writeAll("\n}\n");
}

fn writeCostEnvelopeJson(
    comptime json_version: JsonVersion,
    writer: anytype,
    envelope: *const contract_types.CostEnvelope,
) !void {
    try writer.writeAll("  \"" ++ comptime contractKey(json_version, "costEnvelope") ++ "\": {\n");
    try writer.print("    \"exhaustive\": {s},\n", .{if (envelope.exhaustive) "true" else "false"});
    try writer.writeAll("    \"total\": ");
    try writeBoundJson(writer, envelope.total);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"" ++ comptime contractKey(json_version, "perModule") ++ "\": [");
    for (envelope.entries.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll("\n      { \"module\": ");
        try writeJsonString(writer, entry.module);
        try writer.writeAll(", \"bound\": ");
        try writeBoundJson(writer, entry.bound);
        try writer.writeAll(" }");
    }
    if (envelope.entries.items.len > 0) try writer.writeAll("\n    ");
    try writer.writeAll("]\n");
    try writer.writeAll("  },\n");
}

pub fn writeBoundJson(writer: anytype, bound: contract_types.Bound) !void {
    switch (bound) {
        .constant => |value| {
            try writer.print("{{ \"class\": \"constant\", \"value\": {d} }}", .{value});
        },
        .linear => |linear| {
            try writer.print("{{ \"class\": \"linear\", \"coefficient\": {d}, \"base\": {d}, \"source\": ", .{ linear.coefficient, linear.base });
            try writeProvenanceJson(writer, linear.source);
            try writer.writeAll(" }");
        },
        .unbounded => |source| {
            try writer.writeAll("{ \"class\": \"unbounded\", \"source\": ");
            try writeProvenanceJson(writer, source);
            try writer.writeAll(" }");
        },
    }
}

fn writeProvenanceJson(writer: anytype, provenance: contract_types.BoundProvenance) !void {
    try writer.print("{{ \"line\": {d}, \"column\": {d}, \"desc\": ", .{ provenance.line, provenance.column });
    try writeJsonString(writer, provenance.desc);
    try writer.writeAll(" }");
}

/// Emit the `extensions` section: per-specifier facts produced by partner
/// virtual-module manifests. Keys are stable (sorted) so contract diff stays
/// deterministic. Always emitted, even when empty, so downstream readers
/// don't need a presence check.
fn writeExtensionsJson(
    comptime json_version: JsonVersion,
    writer: anytype,
    contract: *const HandlerContract,
) !void {
    try writer.writeAll("  \"extensions\": {");
    if (contract.extensions.count() == 0) {
        try writer.writeAll("}");
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spec_keys = try sortedHashMapKeys(a, &contract.extensions);
    for (spec_keys, 0..) |spec, i| {
        const ext = contract.extensions.getPtr(spec).?;
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, spec);
        try writer.writeAll(": {\n      \"" ++ comptime contractKey(json_version, "egressHosts") ++ "\": [");
        for (ext.egress_hosts.items, 0..) |host, j| {
            if (j > 0) try writer.writeAll(", ");
            try writeJsonString(writer, host);
        }
        try writer.writeAll("],\n");
        try writer.print("      \"" ++ comptime contractKey(json_version, "egressDynamic") ++ "\": {s},\n", .{if (ext.egress_dynamic) "true" else "false"});
        try writer.writeAll("      \"categories\": {");

        const tag_keys = try sortedHashMapKeys(a, &ext.categories);
        for (tag_keys, 0..) |tag, j| {
            const bucket = ext.categories.getPtr(tag).?;
            if (j > 0) try writer.writeAll(",");
            try writer.writeAll("\n        ");
            try writeJsonString(writer, tag);
            try writer.writeAll(": { \"literals\": [");
            for (bucket.literals.items, 0..) |lit, k| {
                if (k > 0) try writer.writeAll(", ");
                try writeJsonString(writer, lit);
            }
            try writer.print("], \"dynamic\": {s} }}", .{if (bucket.dynamic) "true" else "false"});
        }

        if (tag_keys.len > 0) try writer.writeAll("\n      ");
        try writer.writeAll("}");

        if (ext.contract_section) |section| {
            try writer.writeAll(",\n      \"" ++ comptime contractKey(json_version, "contractSection") ++ "\": ");
            try writeJsonString(writer, section);
        }

        try writer.writeAll("\n    }");
    }
    try writer.writeAll("\n  }");
}

/// Emit each partner-declared top-level section (one per extension with a
/// non-null `contract_section`). Each section is keyed by the partner's
/// chosen name and mirrors the source extension's category buckets, giving
/// partner audit tools parity with built-in sections like `cache` and
/// `durable` without forcing them to crawl the `extensions` namespace.
fn writePartnerContractSections(
    comptime json_version: JsonVersion,
    writer: anytype,
    contract: *const HandlerContract,
) !void {
    if (contract.extensions.count() == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spec_keys = try sortedHashMapKeys(a, &contract.extensions);
    for (spec_keys) |spec| {
        const ext = contract.extensions.getPtr(spec).?;
        const section = ext.contract_section orelse continue;

        try writer.writeAll(",\n  ");
        try writeJsonString(writer, section);
        try writer.writeAll(": {\n    \"" ++ comptime contractKey(json_version, "sourceSpecifier") ++ "\": ");
        try writeJsonString(writer, spec);
        try writer.writeAll(",\n    \"categories\": {");

        const tag_keys = try sortedHashMapKeys(a, &ext.categories);
        for (tag_keys, 0..) |tag, j| {
            const bucket = ext.categories.getPtr(tag).?;
            if (j > 0) try writer.writeAll(",");
            try writer.writeAll("\n      ");
            try writeJsonString(writer, tag);
            try writer.writeAll(": { \"literals\": [");
            for (bucket.literals.items, 0..) |lit, k| {
                if (k > 0) try writer.writeAll(", ");
                try writeJsonString(writer, lit);
            }
            try writer.print("], \"dynamic\": {s} }}", .{if (bucket.dynamic) "true" else "false"});
        }

        if (tag_keys.len > 0) try writer.writeAll("\n    ");
        try writer.writeAll("}\n  }");
    }
}

/// Snapshot the keys of a string-keyed StringHashMapUnmanaged into a sorted
/// slice. The slice borrows the map's key strings; callers must not mutate
/// the map while iterating.
fn sortedHashMapKeys(
    allocator: std.mem.Allocator,
    map: anytype,
) ![]const []const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        keys[i] = entry.key_ptr.*;
    }
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return keys;
}

fn writeApiParamJson(writer: anytype, param: *const ApiParamInfo) !void {
    try writer.writeAll("\n          {\n");
    try writer.writeAll("            \"name\": ");
    try writeJsonString(writer, param.name);
    try writer.writeAll(",\n");
    try writer.writeAll("            \"location\": ");
    try writeJsonString(writer, param.location);
    try writer.writeAll(",\n");
    try writer.print("            \"required\": {s},\n", .{if (param.required) "true" else "false"});
    try writer.writeAll("            \"schema\": ");
    try writer.writeAll(param.schema_json);
    try writer.writeAll("\n          }");
}

/// Emit a KnownList as the legacy array plus dynamic boolean, preserving
/// wire-format compatibility with older contract.json readers. `.dynamic`
/// writes an empty array and dynamic=true.
fn writeKnownListJson(
    comptime json_version: JsonVersion,
    writer: anytype,
    comptime field: []const u8,
    comptime dynamic_field: []const u8,
    list: ServiceCallInfo.KnownList,
) !void {
    try writer.writeAll("      \"" ++ comptime contractKey(json_version, field) ++ "\": [");
    switch (list) {
        .complete => |entries| for (entries.items, 0..) |name, j| {
            if (j > 0) try writer.writeAll(", ");
            try writeJsonString(writer, name);
        },
        .dynamic => {},
    }
    try writer.writeAll("],\n");
    try writer.print("      \"" ++ comptime contractKey(json_version, dynamic_field) ++ "\": {s},\n", .{if (list.isDynamic()) "true" else "false"});
}

fn writeApiBodyJson(comptime json_version: JsonVersion, writer: anytype, body: *const ApiBodyInfo) !void {
    try writer.writeAll("\n          {\n");
    try writer.writeAll("            \"" ++ comptime contractKey(json_version, "contentType") ++ "\": ");
    if (body.content_type) |content_type| {
        try writeJsonString(writer, content_type);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("            \"" ++ comptime contractKey(json_version, "schemaRef") ++ "\": ");
    if (body.schema.schemaRef()) |schema_ref| {
        try writeJsonString(writer, schema_ref);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("            \"schema\": ");
    if (body.schema.schemaJson()) |schema_json| {
        try writer.writeAll(schema_json);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.print("            \"dynamic\": {s}\n", .{if (body.schema.isDynamic()) "true" else "false"});
    try writer.writeAll("          }");
}

fn writeApiResponseJson(comptime json_version: JsonVersion, writer: anytype, response: *const ApiResponseInfo) !void {
    try writer.writeAll("\n          {\n");
    try writer.writeAll("            \"status\": ");
    if (response.status) |status| {
        try writer.print("{d}", .{status});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("            \"" ++ comptime contractKey(json_version, "contentType") ++ "\": ");
    if (response.content_type) |content_type| {
        try writeJsonString(writer, content_type);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("            \"" ++ comptime contractKey(json_version, "schemaRef") ++ "\": ");
    if (response.schema.schemaRef()) |schema_ref| {
        try writeJsonString(writer, schema_ref);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.writeAll("            \"schema\": ");
    if (response.schema.schemaJson()) |schema_json| {
        try writer.writeAll(schema_json);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writer.print("            \"dynamic\": {s}\n", .{if (response.schema.isDynamic()) "true" else "false"});
    try writer.writeAll("          }");
}

/// Emit every boolean field of `HandlerProperties` using the selected wire
/// spelling. Version 1 uses `HandlerProperties.camelKeyFor`; version 2 uses
/// the struct's snake_case field name. `max_io_depth` is emitted separately.
fn writeBooleanProperties(
    comptime json_version: JsonVersion,
    p: contract_types.HandlerProperties,
    writer: anytype,
) !void {
    inline for (@typeInfo(contract_types.HandlerProperties).@"struct".fields) |field| {
        if (field.type == bool) {
            const key = comptime switch (json_version) {
                .v1 => contract_types.HandlerProperties.camelKeyFor(field.name) orelse
                    @compileError("missing HandlerProperties camel-case key: " ++ field.name),
                .v2 => field.name,
            };
            const value = @field(p, field.name);
            try writer.print("    \"{s}\": {s},\n", .{ key, if (value) "true" else "false" });
        }
    }
}

fn contractKey(comptime json_version: JsonVersion, comptime legacy_key: []const u8) []const u8 {
    comptime {
        if (json_version == .v1) return legacy_key;
        return camelToSnake(legacy_key);
    }
}

fn camelToSnake(comptime camel: []const u8) []const u8 {
    comptime {
        var uppercase_count: usize = 0;
        for (camel) |byte| {
            if (std.ascii.isUpper(byte)) uppercase_count += 1;
        }

        var buffer: [camel.len + uppercase_count]u8 = undefined;
        var len: usize = 0;
        for (camel) |byte| {
            if (std.ascii.isUpper(byte)) {
                buffer[len] = '_';
                len += 1;
                buffer[len] = std.ascii.toLower(byte);
            } else {
                buffer[len] = byte;
            }
            len += 1;
        }
        const result = buffer[0..len].*;
        return &result;
    }
}

fn expectSnakeCaseKeys(value: *const std.json.Value, visited: *usize) !void {
    switch (value.*) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                visited.* += 1;
                for (entry.key_ptr.*) |byte| {
                    try std.testing.expect(
                        std.ascii.isLower(byte) or
                            std.ascii.isDigit(byte) or
                            byte == '_',
                    );
                }
                try expectSnakeCaseKeys(entry.value_ptr, visited);
            }
        },
        .array => |array| for (array.items) |*item| {
            try expectSnakeCaseKeys(item, visited);
        },
        else => {},
    }
}

fn writeTestContractJson(
    allocator: std.mem.Allocator,
    contract: *const HandlerContract,
    comptime json_version: JsonVersion,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    switch (json_version) {
        .v1 => try writeContractJson(contract, &output.writer),
        .v2 => try writeContractJsonV2(contract, &output.writer),
    }
    return output.toOwnedSlice();
}

fn appendTestString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn appendTestFunction(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
) !void {
    const module = try allocator.dupe(u8, "workflow");
    errdefer allocator.free(module);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    try appendTestString(allocator, &names, "call");
    try contract.functions.append(allocator, .{ .module = module, .names = names });
}

fn appendTestWorkflowCall(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
) !void {
    const target = try allocator.dupe(u8, "billing");
    errdefer allocator.free(target);
    const route = try allocator.dupe(u8, "POST /charge");
    errdefer allocator.free(route);
    try contract.workflow_calls.append(allocator, .{
        .target = target,
        .route_pattern = route,
        .dynamic = false,
    });
}

fn populateVersionTwoTestContract(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
) !void {
    contract.version = 2;
    contract.handler.line = 7;
    contract.handler.column = 3;

    {
        const route_pattern = try allocator.dupe(u8, "/orders/:id");
        errdefer allocator.free(route_pattern);
        try contract.routes.append(allocator, .{
            .pattern = route_pattern,
            .route_type = "exact",
            .field = "path",
            .status = 202,
            .content_type = "application/json",
            .aot = true,
        });
    }
    try appendTestString(allocator, &contract.modules, "zttp:workflow");
    try appendTestFunction(allocator, contract);
    try appendTestString(allocator, &contract.env.literal, "ORDERS_TOKEN");
    contract.env.dynamic = true;
    try appendTestString(allocator, &contract.egress.hosts, "api.example.com");
    try appendTestString(allocator, &contract.egress.urls, "https://api.example.com/orders");
    contract.egress.dynamic = true;
    try appendTestWorkflowCall(allocator, contract);
    contract.durable.used = true;
    try appendTestString(allocator, &contract.durable.keys.literal, "order:42");
    try appendTestString(allocator, &contract.durable.steps, "charge");
    try appendTestString(allocator, &contract.durable.signals.literal, "approved");
    try appendTestString(allocator, &contract.durable.producer_keys.literal, "approval:42");
    contract.durable.workflow.workflow_id = try allocator.dupe(u8, "workflow.ts:handler:7:3");
    contract.durable.workflow.proof_level = .complete;
    contract.durable.workflow.properties.retry_safe = true;
    contract.durable.workflow.properties.idempotent = true;
    contract.durable.workflow.properties.fault_covered = true;
    try appendTestString(
        allocator,
        &contract.durable.workflow.properties.reasons,
        "stable workflow keys",
    );
    contract.aot = .{ .pattern_count = 1, .has_default = true };
    contract.properties = .{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = true,
        .idempotent = true,
        .max_io_depth = 2,
        .fault_covered = true,
        .result_safe = true,
        .optional_safe = true,
        .canonical = true,
        .cost_bounded = true,
    };
    try appendTestString(allocator, &contract.declared_specs, "retry_safe");
    try appendTestString(allocator, &contract.declared_specs, "idempotent");

    var capabilities = CapabilityMatrix.empty;
    capabilities.items[0] = .clock;
    capabilities.len = 1;
    capabilities.hash[0] = 1;
    contract.capabilities = capabilities;
    var capability_budget = CapabilityMatrix.empty;
    capability_budget.items[0] = .network;
    capability_budget.len = 1;
    contract.capability_budget = capability_budget;
}

test "version 2 writes only snake_case keys" {
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    try populateVersionTwoTestContract(allocator, &contract);

    const output = try writeTestContractJson(allocator, &contract, .v2);
    defer allocator.free(output);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const version = root.get("version") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 2), version.integer);

    var visited: usize = 0;
    try expectSnakeCaseKeys(&parsed.value, &visited);
    try std.testing.expect(visited >= 50);
}

test "version 1 keeps its version and camelCase keys" {
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    contract.version = 1;

    const output = try writeTestContractJson(allocator, &contract, .v1);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"serviceCalls\": []") != null);
}

/// Collect every object key in `value`, in document order, including nested
/// objects and objects inside arrays.
fn collectJsonKeys(
    allocator: std.mem.Allocator,
    value: *const std.json.Value,
    out: *std.ArrayList([]const u8),
) !void {
    switch (value.*) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try out.append(allocator, entry.key_ptr.*);
                try collectJsonKeys(allocator, entry.value_ptr, out);
            }
        },
        .array => |array| for (array.items) |*item| {
            try collectJsonKeys(allocator, item, out);
        },
        // exhaustive: a scalar carries no keys, so there is nothing here to
        // collect and nothing this walk owes it.
        else => {},
    }
}

fn keysOf(
    allocator: std.mem.Allocator,
    contract: *const HandlerContract,
    comptime json_version: JsonVersion,
    parsed_out: *std.json.Parsed(std.json.Value),
    keys_out: *std.ArrayList([]const u8),
) !void {
    const output = try writeTestContractJson(allocator, contract, json_version);
    defer allocator.free(output);
    parsed_out.* = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    try collectJsonKeys(allocator, &parsed_out.value, keys_out);
}

test "version 1 never emits a snake_case key" {
    // Version 1 and version 2 are one traversal parameterized by a comptime
    // key mapping, not two writers, so the promise that version 1 is frozen
    // rests on tests rather than on the two never sharing a line. The goldens
    // pin the bytes of four fixture handlers; this pins the CONVENTION over a
    // contract populated across every section, which is what an accidental
    // `contractKey(.v1, ...)` typo would break first.
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    try populateVersionTwoTestContract(allocator, &contract);
    contract.version = 1;

    var parsed: std.json.Parsed(std.json.Value) = undefined;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    try keysOf(allocator, &contract, .v1, &parsed, &keys);
    defer parsed.deinit();

    for (keys.items) |key| {
        if (std.mem.indexOfScalar(u8, key, '_') != null) {
            std.debug.print("version 1 emitted a snake_case key: {s}\n", .{key});
            return error.VersionOneKeyWentSnakeCase;
        }
    }
    // The floor: a walk that visited nothing would satisfy the loop above.
    try std.testing.expect(keys.items.len >= 50);
}

test "version 2's key set is exactly the snake_case image of version 1's" {
    // The other half of the same guard. A key added to one version and not the
    // other, or mapped to a name the reverse mapping does not produce, fails
    // here rather than reaching a client as a field it cannot find.
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    try populateVersionTwoTestContract(allocator, &contract);

    var v1_parsed: std.json.Parsed(std.json.Value) = undefined;
    var v1_keys: std.ArrayList([]const u8) = .empty;
    defer v1_keys.deinit(allocator);
    try keysOf(allocator, &contract, .v1, &v1_parsed, &v1_keys);
    defer v1_parsed.deinit();

    var v2_parsed: std.json.Parsed(std.json.Value) = undefined;
    var v2_keys: std.ArrayList([]const u8) = .empty;
    defer v2_keys.deinit(allocator);
    try keysOf(allocator, &contract, .v2, &v2_parsed, &v2_keys);
    defer v2_parsed.deinit();

    try std.testing.expectEqual(v1_keys.items.len, v2_keys.items.len);
    try std.testing.expect(v1_keys.items.len >= 50);

    // Document order is the same traversal on both sides, so the images line
    // up index for index and a mismatch names the key that moved.
    for (v1_keys.items, v2_keys.items) |v1_key, v2_key| {
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(allocator);
        for (v1_key) |byte| {
            if (std.ascii.isUpper(byte)) {
                try expected.append(allocator, '_');
                try expected.append(allocator, std.ascii.toLower(byte));
            } else {
                try expected.append(allocator, byte);
            }
        }
        if (!std.mem.eql(u8, expected.items, v2_key)) {
            std.debug.print(
                "key mismatch: version 1 `{s}` maps to `{s}`, version 2 emitted `{s}`\n",
                .{ v1_key, expected.items, v2_key },
            );
            return error.VersionKeySetsDisagree;
        }
    }
}

test "version 2 round-trips a populated contract field for field" {
    const allocator = std.testing.allocator;
    var original = handler_contract.emptyContract(try allocator.dupe(u8, "workflow.ts"));
    defer original.deinit(allocator);
    try populateVersionTwoTestContract(allocator, &original);

    const version_one_before = try writeTestContractJson(allocator, &original, .v1);
    defer allocator.free(version_one_before);
    const version_two = try writeTestContractJson(allocator, &original, .v2);
    defer allocator.free(version_two);

    var parsed = try handler_contract.parseFromJson(allocator, version_two);
    defer parsed.deinit(allocator);
    const version_one_after = try writeTestContractJson(allocator, &parsed, .v1);
    defer allocator.free(version_one_after);

    try std.testing.expectEqualStrings(version_one_before, version_one_after);
}
