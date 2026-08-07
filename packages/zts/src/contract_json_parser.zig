//! Typed JSON deserializer for HandlerContract.
//!
//! std.json owns syntax parsing. ContractWire describes the accepted wire
//! shape, and the projection functions below build the independently owned
//! domain graph.

const std = @import("std");
const contract_types = @import("contract_types.zig");
const handler_contract = @import("handler_contract.zig");
const json_wire = @import("zts-base").json_wire;
// The capability vocabulary from the leaf file that defines it, not through
// `module_binding.zig`, which would pull the module bridge and the engine
// into a contract parser.
const module_binding = @import("zts-base").module_authorization;
const json_utils = @import("zts-base").json_utils;

const HandlerContract = handler_contract.HandlerContract;
const RouteInfo = handler_contract.RouteInfo;
const ServiceCallInfo = handler_contract.ServiceCallInfo;
const WorkflowCallInfo = contract_types.WorkflowCallInfo;
const ApiRouteInfo = handler_contract.ApiRouteInfo;
const ApiParamInfo = handler_contract.ApiParamInfo;
const ApiBodyInfo = handler_contract.ApiBodyInfo;
const ApiResponseInfo = handler_contract.ApiResponseInfo;
const SchemaSpec = handler_contract.SchemaSpec;
const SpecDiagnostic = contract_types.SpecDiagnostic;
const PathCondition = handler_contract.PathCondition;
const PathIoCall = handler_contract.PathIoCall;
const Bound = handler_contract.Bound;
const BoundProvenance = handler_contract.BoundProvenance;
const CostEnvelope = handler_contract.CostEnvelope;
const CapabilityMatrix = handler_contract.CapabilityMatrix;
const ModuleCapability = module_binding.ModuleCapability;
const capability_count = module_binding.capability_count;

const WireString = json_wire.String;
const RawJson = json_wire.RawValue;
const WireU16 = json_wire.Unsigned(u16);
const WireU32 = json_wire.Unsigned(u32);

const HandlerWire = struct {
    path: WireString = .{ .bytes = "" },
    line: WireU32 = .{ .value = null },
    column: WireU32 = .{ .value = null },
};

const RouteWire = struct {
    pattern: WireString = .{ .bytes = "" },
    type: WireString = .{ .bytes = "exact" },
    field: WireString = .{ .bytes = "path" },
    status: WireU16 = .{ .value = null },
    contentType: WireString = .{ .bytes = "application/json" },
    aot: bool = false,
};

const DynamicWire = struct {
    literal: []const WireString = &.{},
    dynamic: bool = false,
};

const EgressWire = struct {
    hosts: []const WireString = &.{},
    urls: []const WireString = &.{},
    dynamic: bool = false,
};

const ExtensionCategoryWire = struct {
    literals: []const WireString = &.{},
    dynamic: bool = false,
};

const ExtensionCategoryMap = json_wire.RawArrayHashMap(ExtensionCategoryWire);

const ExtensionWire = struct {
    egressHosts: []const WireString = &.{},
    egressDynamic: bool = false,
    categories: ExtensionCategoryMap = .{},
    contractSection: ?WireString = null,
};

const ExtensionMap = json_wire.RawArrayHashMap(ExtensionWire);

const ServiceCallWire = struct {
    service: WireString = .{ .bytes = "" },
    route: WireString = .{ .bytes = "" },
    dynamic: bool = false,
    pathParams: []const WireString = &.{},
    pathParamsDynamic: bool = false,
    queryKeys: []const WireString = &.{},
    queryDynamic: bool = false,
    headerKeys: []const WireString = &.{},
    headerDynamic: bool = false,
    hasBody: bool = false,
    bodyDynamic: bool = false,
};

const WorkflowCallWire = struct {
    target: WireString = .{ .bytes = "" },
    route: WireString = .{ .bytes = "" },
    dynamic: bool = false,
};

const AffordanceWire = struct {
    rel: WireString = .{ .bytes = "" },
    method: WireString = .{ .bytes = "GET" },
    href: WireString = .{ .bytes = "" },
    templated: bool = false,
    dynamic: bool = false,
};

const SqlQueryWire = struct {
    name: WireString = .{ .bytes = "" },
    statement: WireString = .{ .bytes = "" },
    operation: WireString = .{ .bytes = "" },
    tables: []const WireString = &.{},
};

const SqlWire = struct {
    backend: WireString = .{ .bytes = "sqlite" },
    queries: []const SqlQueryWire = &.{},
    dynamic: bool = false,
};

const DurableWorkflowPropertiesWire = struct {
    retrySafe: bool = false,
    idempotent: bool = false,
    faultCovered: bool = false,
    reasons: []const WireString = &.{},
};

const DurableWorkflowNodeWire = struct {
    id: WireString = .{ .bytes = "" },
    kind: WireString = .{ .bytes = "branch" },
    label: WireString = .{ .bytes = "" },
    detail: ?WireString = null,
    status: ?WireU16 = null,
};

const DurableWorkflowEdgeWire = struct {
    from: WireString = .{ .bytes = "" },
    to: WireString = .{ .bytes = "" },
    condition: ?WireString = null,
};

const DurableWorkflowWire = struct {
    workflowId: ?WireString = null,
    proofLevel: WireString = .{ .bytes = "none" },
    properties: DurableWorkflowPropertiesWire = .{},
    nodes: []const DurableWorkflowNodeWire = &.{},
    edges: []const DurableWorkflowEdgeWire = &.{},
};

const DurableWire = struct {
    used: bool = false,
    keys: DynamicWire = .{},
    steps: []const WireString = &.{},
    timers: bool = false,
    signals: DynamicWire = .{},
    producerKeys: DynamicWire = .{},
    workflow: json_wire.MergedOptional(DurableWorkflowWire) = .{},
};

const ScopeWire = struct {
    used: bool = false,
    names: []const WireString = &.{},
    dynamic: bool = false,
    maxDepth: WireU32 = .{ .value = null },
};

const ApiSchemaWire = struct {
    name: WireString = .{ .bytes = "" },
    schema: RawJson = .{ .bytes = "{}" },
};

const ApiRequestsWire = struct {
    schemaRefs: []const WireString = &.{},
    dynamic: bool = false,
};

const ApiAuthWire = struct {
    bearer: bool = false,
    jwt: bool = false,
};

const ApiParamWire = struct {
    name: WireString = .{ .bytes = "" },
    location: WireString = .{ .bytes = "path" },
    required: bool = false,
    schema: RawJson = .{ .bytes = "{\"type\":\"string\"}" },
};

const ApiBodyWire = struct {
    contentType: ?WireString = null,
    schemaRef: ?WireString = null,
    schema: ?RawJson = null,
    dynamic: bool = false,
};

const ApiResponseWire = struct {
    status: ?WireU16 = null,
    contentType: ?WireString = null,
    schemaRef: ?WireString = null,
    schema: ?RawJson = null,
    dynamic: bool = false,
};

const ApiRouteWire = struct {
    method: WireString = .{ .bytes = "" },
    path: WireString = .{ .bytes = "" },
    requestSchemaRefs: []const WireString = &.{},
    requestSchemaDynamic: bool = false,
    requiresBearer: bool = false,
    requiresJwt: bool = false,
    pathParams: []const ApiParamWire = &.{},
    queryParams: []const ApiParamWire = &.{},
    headerParams: []const ApiParamWire = &.{},
    queryParamsDynamic: bool = false,
    headerParamsDynamic: bool = false,
    requestBodies: []const ApiBodyWire = &.{},
    requestBodiesDynamic: bool = false,
    responses: []const ApiResponseWire = &.{},
    responsesDynamic: bool = false,
    responseStatus: ?WireU16 = null,
    responseContentType: ?WireString = null,
    responseSchemaRef: ?WireString = null,
    responseSchema: ?RawJson = null,
    responseSchemaDynamic: bool = false,
};

const ApiWire = struct {
    schemas: []const ApiSchemaWire = &.{},
    requests: ApiRequestsWire = .{},
    auth: ApiAuthWire = .{},
    routes: []const ApiRouteWire = &.{},
    schemasDynamic: bool = false,
    routesDynamic: bool = false,
};

const VerificationWire = struct {
    exhaustiveReturns: bool = false,
    resultsSafe: bool = false,
    unreachableCode: bool = false,
    bytecodeVerified: bool = false,
};

const WebSocketWire = struct {
    onOpen: bool = false,
    onMessage: bool = false,
    onClose: bool = false,
    onError: bool = false,
};

const FaultCoverageWire = struct {
    totalFailable: WireU32 = .{ .value = null },
    covered: WireU32 = .{ .value = null },
    warnings: WireU32 = .{ .value = null },
};

const RateLimitWire = struct {
    namespace: WireString = .{ .bytes = "" },
    dynamic: bool = true,
};

const PropertiesWire = struct {
    pure: bool = false,
    readOnly: bool = false,
    stateless: bool = false,
    retrySafe: bool = false,
    deterministic: bool = false,
    hasEgress: bool = false,
    noSecretLeakage: bool = false,
    noCredentialLeakage: bool = false,
    inputValidated: bool = false,
    piiContained: bool = false,
    idempotent: bool = false,
    maxIoDepth: ?WireU32 = null,
    injectionSafe: bool = false,
    stateIsolated: bool = false,
    faultCovered: bool = false,
    resultSafe: bool = false,
    optionalSafe: bool = false,
    postOnly: bool = false,
    canonical: bool = false,
    costBounded: bool = false,
};

const SpecDiagnosticWire = struct {
    kind: ?WireString = null,
    code: ?WireString = null,
    specName: ?WireString = null,
    incompatibleModule: ?WireString = null,
    suggestion: ?WireString = null,
    function: ?WireString = null,
};

const SandboxWire = struct {
    capabilities: json_wire.AppendedNonNull(WireString) = .{},
    capabilityHash: json_wire.OptionalNonNull(WireString) = .{},
    policyHash: json_wire.OptionalNonNull(WireString) = .{},
    wasmPolicyHash: json_wire.OptionalNonNull(WireString) = .{},
    artifactSha256: json_wire.OptionalNonNull(WireString) = .{},
};

fn combineSandboxWire(previous: *SandboxWire, next: SandboxWire) void {
    if (next.capabilities.value != null) {
        previous.capabilities = next.capabilities;
        previous.capabilityHash = next.capabilityHash;
    }
    if (next.policyHash.value != null) previous.policyHash = next.policyHash;
    if (next.wasmPolicyHash.value != null) previous.wasmPolicyHash = next.wasmPolicyHash;
    if (next.artifactSha256.value != null) previous.artifactSha256 = next.artifactSha256;
}

const BehaviorConditionWire = struct {
    kind: WireString = .{ .bytes = "io_ok" },
    module: ?WireString = null,
    func: ?WireString = null,
    value: ?WireString = null,
};

const BehaviorIoWire = struct {
    module: WireString = .{ .bytes = "" },
    func: WireString = .{ .bytes = "" },
    args: ?WireString = null,
};

const BehaviorWire = struct {
    method: WireString = .{ .bytes = "" },
    pattern: WireString = .{ .bytes = "" },
    status: WireU16 = .{ .value = null },
    ioDepth: WireU32 = .{ .value = null },
    failurePath: bool = false,
    conditions: []const BehaviorConditionWire = &.{},
    ioSequence: []const BehaviorIoWire = &.{},
};

const IntentHeaderWire = struct {
    name: WireString = .{ .bytes = "" },
    value: WireString = .{ .bytes = "" },
};

const IntentAssertionWire = struct {
    name: WireString = .{ .bytes = "" },
    method: WireString = .{ .bytes = "" },
    path: WireString = .{ .bytes = "" },
    requestBodyJson: ?WireString = null,
    expectedStatus: ?WireU16 = null,
    expectedBodyJson: ?WireString = null,
    expectedHeaders: []const IntentHeaderWire = &.{},
    sourceLine: WireU32 = .{ .value = null },
    sourceColumn: WireU32 = .{ .value = null },
};

const IntentWire = struct {
    dynamic: bool = false,
    assertions: []const IntentAssertionWire = &.{},
};

const SagaStepWire = struct {
    name: WireString = .{ .bytes = "" },
    hasCompensate: bool = false,
};

const SagaWire = struct {
    dynamic: bool = false,
    steps: []const SagaStepWire = &.{},
    sourceLine: WireU32 = .{ .value = null },
    sourceColumn: WireU32 = .{ .value = null },
};

const ProvenanceWire = struct {
    line: WireU32 = .{ .value = null },
    column: WireU32 = .{ .value = null },
    desc: WireString = .{ .bytes = "" },
};

const BoundWire = struct {
    class: ?WireString = null,
    value: WireU32 = .{ .value = null },
    coefficient: WireU32 = .{ .value = null },
    base: WireU32 = .{ .value = null },
    source: ?ProvenanceWire = null,
};

const CostEntryWire = struct {
    module: ?WireString = null,
    bound: ?BoundWire = null,
};

const CostEnvelopeWire = struct {
    exhaustive: bool = true,
    total: BoundWire = .{ .class = .{ .bytes = "constant" } },
    perModule: []const CostEntryWire = &.{},
};

const ContractWire = struct {
    version: WireU32 = .{ .value = null },
    handler: HandlerWire = .{},
    routes: []const RouteWire = &.{},
    modules: []const WireString = &.{},
    env: DynamicWire = .{},
    egress: EgressWire = .{},
    serviceCalls: []const ServiceCallWire = &.{},
    workflowCalls: []const WorkflowCallWire = &.{},
    affordances: []const AffordanceWire = &.{},
    affordancesDynamic: bool = false,
    cache: struct {
        namespaces: []const WireString = &.{},
        dynamic: bool = false,
    } = .{},
    sql: SqlWire = .{},
    durable: DurableWire = .{},
    scope: ScopeWire = .{},
    api: ApiWire = .{},
    verification: ?VerificationWire = null,
    websocket: ?WebSocketWire = null,
    faultCoverage: ?FaultCoverageWire = null,
    rateLimiting: ?RateLimitWire = null,
    properties: ?PropertiesWire = null,
    declaredSpecs: []const WireString = &.{},
    specDiagnostics: json_wire.AppendedOptional(SpecDiagnosticWire) = .{},
    sandbox: json_wire.FoldedOptional(SandboxWire, combineSandboxWire) = .{},
    intent: ?IntentWire = null,
    sagas: []const SagaWire = &.{},
    behaviors: json_wire.AppendedOptional(BehaviorWire) = .{},
    behaviorsExhaustive: bool = false,
    costEnvelope: ?CostEnvelopeWire = null,
    extensions: ExtensionMap = .{},
};

/// Parse a HandlerContract from JSON into an independently owned domain graph.
pub fn parseFromJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !HandlerContract {
    var parsed = try json_wire.parse(ContractWire, allocator, json_bytes);
    defer parsed.deinit();
    return projectContract(allocator, &parsed.value);
}

fn projectContract(
    allocator: std.mem.Allocator,
    wire: *const ContractWire,
) !HandlerContract {
    var contract = handler_contract.emptyContract(try dupeWireString(allocator, wire.handler.path));
    contract.handler.line = wire.handler.line.value orelse 0;
    contract.handler.column = wire.handler.column.value orelse 0;
    contract.version = wire.version.value orelse contract.version;
    errdefer contract.deinit(allocator);

    contract.routes = try projectRoutes(allocator, wire.routes);
    contract.modules = try projectStringList(allocator, wire.modules);
    contract.env.literal = try projectStringList(allocator, wire.env.literal);
    contract.env.dynamic = wire.env.dynamic;
    contract.egress.hosts = try projectStringList(allocator, wire.egress.hosts);
    contract.egress.urls = try projectStringList(allocator, wire.egress.urls);
    contract.egress.dynamic = wire.egress.dynamic;
    try projectServiceCalls(allocator, wire.serviceCalls, &contract);
    try projectWorkflowCalls(allocator, wire.workflowCalls, &contract);
    try projectAffordances(allocator, wire.affordances, &contract);
    contract.affordances_dynamic = wire.affordancesDynamic;
    contract.cache.namespaces = try projectStringList(allocator, wire.cache.namespaces);
    contract.cache.dynamic = wire.cache.dynamic;
    try projectSql(allocator, &wire.sql, &contract);
    try projectDurable(allocator, &wire.durable, &contract);
    try projectScope(allocator, &wire.scope, &contract);
    try projectApi(allocator, &wire.api, &contract);
    projectVerification(wire.verification, &contract);
    projectWebSocket(wire.websocket, &contract);
    projectFaultCoverage(wire.faultCoverage, &contract);
    projectProperties(wire.properties, &contract);
    contract.declared_specs = try projectStringList(allocator, wire.declaredSpecs);
    try projectSpecDiagnostics(allocator, wire.specDiagnostics.value, &contract);
    try projectSandbox(wire.sandbox.value, &contract);
    try projectIntent(allocator, wire.intent, &contract);
    try projectSagas(allocator, wire.sagas, &contract);
    try projectBehaviors(allocator, wire.behaviors.value, &contract);
    contract.behaviors_exhaustive = wire.behaviorsExhaustive;
    contract.cost_envelope = try projectCostEnvelope(allocator, wire.costEnvelope);
    try projectExtensions(allocator, &wire.extensions, &contract);
    try projectRateLimit(allocator, wire.rateLimiting, &contract);

    return contract;
}

fn dupeWireString(allocator: std.mem.Allocator, wire: WireString) ![]const u8 {
    return allocator.dupe(u8, wire.bytes);
}

fn dupeOptionalWireString(
    allocator: std.mem.Allocator,
    wire: ?WireString,
) !?[]const u8 {
    return handler_contract.dupeOptionalString(
        allocator,
        if (wire) |value| value.bytes else null,
    );
}

const OwnedStringPair = struct {
    first: []const u8,
    second: []const u8,
};

const OwnedStringTriple = struct {
    first: []const u8,
    second: []const u8,
    third: []const u8,
};

fn dupeWireStringPair(
    allocator: std.mem.Allocator,
    first: WireString,
    second: WireString,
) !OwnedStringPair {
    const owned_first = try dupeWireString(allocator, first);
    errdefer allocator.free(owned_first);
    return .{
        .first = owned_first,
        .second = try dupeWireString(allocator, second),
    };
}

fn dupeWireStringTriple(
    allocator: std.mem.Allocator,
    first: WireString,
    second: WireString,
    third: WireString,
) !OwnedStringTriple {
    const pair = try dupeWireStringPair(allocator, first, second);
    errdefer {
        allocator.free(pair.first);
        allocator.free(pair.second);
    }
    return .{
        .first = pair.first,
        .second = pair.second,
        .third = try dupeWireString(allocator, third),
    };
}

fn projectStringList(
    allocator: std.mem.Allocator,
    wire: []const WireString,
) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &result);
    try result.ensureTotalCapacity(allocator, wire.len);
    for (wire) |value| {
        const owned = try dupeWireString(allocator, value);
        errdefer allocator.free(owned);
        result.appendAssumeCapacity(owned);
    }
    return result;
}

fn deinitStringList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn projectRoutes(
    allocator: std.mem.Allocator,
    wire: []const RouteWire,
) !std.ArrayList(RouteInfo) {
    var result: std.ArrayList(RouteInfo) = .empty;
    errdefer {
        for (result.items) |route| allocator.free(route.pattern);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, wire.len);
    for (wire) |route| {
        const pattern = try dupeWireString(allocator, route.pattern);
        errdefer allocator.free(pattern);
        result.appendAssumeCapacity(.{
            .pattern = pattern,
            .route_type = toStaticRouteType(route.type.bytes),
            .field = toStaticField(route.field.bytes),
            .status = route.status.value orelse 200,
            .content_type = toStaticContentType(route.contentType.bytes),
            .aot = route.aot,
        });
    }
    return result;
}

fn projectServiceCalls(
    allocator: std.mem.Allocator,
    wires: []const ServiceCallWire,
    contract: *HandlerContract,
) !void {
    try contract.service_calls.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.service, wire.route);
        var call = ServiceCallInfo{
            .service = owned.first,
            .route_pattern = owned.second,
        };
        errdefer call.deinit(allocator);
        call.dynamic = wire.dynamic;
        call.path_params = try projectKnownList(allocator, wire.pathParams, wire.pathParamsDynamic);
        call.query_keys = try projectKnownList(allocator, wire.queryKeys, wire.queryDynamic);
        call.header_keys = try projectKnownList(allocator, wire.headerKeys, wire.headerDynamic);
        call.body = pickBodySpec(wire.hasBody, wire.bodyDynamic);
        contract.service_calls.appendAssumeCapacity(call);
    }
}

fn projectKnownList(
    allocator: std.mem.Allocator,
    wire: []const WireString,
    dynamic: bool,
) !ServiceCallInfo.KnownList {
    if (dynamic) return .dynamic;
    return .{ .complete = try projectStringList(allocator, wire) };
}

fn pickBodySpec(has_body: bool, body_dynamic: bool) ServiceCallInfo.BodySpec {
    if (body_dynamic) return .dynamic;
    if (has_body) return .present;
    return .none;
}

fn projectWorkflowCalls(
    allocator: std.mem.Allocator,
    wires: []const WorkflowCallWire,
    contract: *HandlerContract,
) !void {
    try contract.workflow_calls.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.target, wire.route);
        var call = WorkflowCallInfo{
            .target = owned.first,
            .route_pattern = owned.second,
            .dynamic = wire.dynamic,
        };
        errdefer call.deinit(allocator);
        contract.workflow_calls.appendAssumeCapacity(call);
    }
}

fn projectAffordances(
    allocator: std.mem.Allocator,
    wires: []const AffordanceWire,
    contract: *HandlerContract,
) !void {
    try contract.affordances.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringTriple(allocator, wire.rel, wire.method, wire.href);
        var affordance = contract_types.EmittedAffordance{
            .rel = owned.first,
            .method = owned.second,
            .href = owned.third,
            .templated = wire.templated,
            .dynamic = wire.dynamic,
        };
        errdefer affordance.deinit(allocator);
        contract.affordances.appendAssumeCapacity(affordance);
    }
}

fn projectSql(
    allocator: std.mem.Allocator,
    wire: *const SqlWire,
    contract: *HandlerContract,
) !void {
    contract.sql.dynamic = wire.dynamic;
    try contract.sql.queries.ensureTotalCapacity(allocator, wire.queries.len);
    for (wire.queries) |query_wire| {
        const owned = try dupeWireStringPair(allocator, query_wire.name, query_wire.statement);
        var query = contract_types.SqlQueryInfo{
            .name = owned.first,
            .statement = owned.second,
            .operation = parseOwnedStaticOperation(query_wire.operation.bytes),
            .tables = .empty,
        };
        errdefer query.deinit(allocator);
        query.tables = try projectStringList(allocator, query_wire.tables);
        contract.sql.queries.appendAssumeCapacity(query);
    }
}

fn projectDurable(
    allocator: std.mem.Allocator,
    wire: *const DurableWire,
    contract: *HandlerContract,
) !void {
    contract.durable.used = wire.used;
    contract.durable.keys.literal = try projectStringList(allocator, wire.keys.literal);
    contract.durable.keys.dynamic = wire.keys.dynamic;
    contract.durable.steps = try projectStringList(allocator, wire.steps);
    contract.durable.timers = wire.timers;
    contract.durable.signals.literal = try projectStringList(allocator, wire.signals.literal);
    contract.durable.signals.dynamic = wire.signals.dynamic;
    contract.durable.producer_keys.literal = try projectStringList(allocator, wire.producerKeys.literal);
    contract.durable.producer_keys.dynamic = wire.producerKeys.dynamic;
    if (wire.workflow.value) |workflow| {
        contract.durable.workflow.workflow_id = try dupeOptionalWireString(allocator, workflow.workflowId);
        contract.durable.workflow.proof_level = contract_types.DurableWorkflowProofLevel.fromString(workflow.proofLevel.bytes);
        contract.durable.workflow.properties.retry_safe = workflow.properties.retrySafe;
        contract.durable.workflow.properties.idempotent = workflow.properties.idempotent;
        contract.durable.workflow.properties.fault_covered = workflow.properties.faultCovered;
        contract.durable.workflow.properties.reasons = try projectStringList(allocator, workflow.properties.reasons);
        try projectDurableNodes(allocator, workflow.nodes, &contract.durable.workflow);
        try projectDurableEdges(allocator, workflow.edges, &contract.durable.workflow);
    }
}

fn projectDurableNodes(
    allocator: std.mem.Allocator,
    wires: []const DurableWorkflowNodeWire,
    workflow: *contract_types.DurableWorkflow,
) !void {
    try workflow.nodes.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.id, wire.label);
        var node = contract_types.DurableWorkflowNode{
            .id = owned.first,
            .kind = contract_types.DurableWorkflowNodeKind.fromString(wire.kind.bytes),
            .label = owned.second,
            .detail = null,
            .status = null,
        };
        errdefer node.deinit(allocator);
        node.detail = try dupeOptionalWireString(allocator, wire.detail);
        if (wire.status) |status| {
            node.status = status.value orelse return error.InvalidJson;
        }
        workflow.nodes.appendAssumeCapacity(node);
    }
}

fn projectDurableEdges(
    allocator: std.mem.Allocator,
    wires: []const DurableWorkflowEdgeWire,
    workflow: *contract_types.DurableWorkflow,
) !void {
    try workflow.edges.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.from, wire.to);
        var edge = contract_types.DurableWorkflowEdge{
            .from = owned.first,
            .to = owned.second,
            .condition = null,
        };
        errdefer edge.deinit(allocator);
        edge.condition = try dupeOptionalWireString(allocator, wire.condition);
        workflow.edges.appendAssumeCapacity(edge);
    }
}

fn projectScope(
    allocator: std.mem.Allocator,
    wire: *const ScopeWire,
    contract: *HandlerContract,
) !void {
    contract.scope.used = wire.used;
    contract.scope.names = try projectStringList(allocator, wire.names);
    contract.scope.dynamic = wire.dynamic;
    contract.scope.max_depth = wire.maxDepth.value orelse 0;
}

fn projectApi(
    allocator: std.mem.Allocator,
    wire: *const ApiWire,
    contract: *HandlerContract,
) !void {
    try contract.api.schemas.ensureTotalCapacity(allocator, wire.schemas.len);
    for (wire.schemas) |schema_wire| {
        const name = try dupeWireString(allocator, schema_wire.name);
        errdefer allocator.free(name);
        const schema = try allocator.dupe(u8, schema_wire.schema.bytes);
        errdefer allocator.free(schema);
        contract.api.schemas.appendAssumeCapacity(.{
            .name = name,
            .schema_json = schema,
        });
    }
    contract.api.requests.schema_refs = try projectStringList(allocator, wire.requests.schemaRefs);
    contract.api.requests.dynamic = wire.requests.dynamic;
    contract.api.auth = .{
        .bearer = wire.auth.bearer,
        .jwt = wire.auth.jwt,
    };
    contract.api.schemas_dynamic = wire.schemasDynamic;
    contract.api.routes_dynamic = wire.routesDynamic;
    try projectApiRoutes(allocator, wire.routes, &contract.api.routes);
}

fn projectApiRoutes(
    allocator: std.mem.Allocator,
    wires: []const ApiRouteWire,
    routes: *std.ArrayList(ApiRouteInfo),
) !void {
    try routes.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.method, wire.path);
        var route = ApiRouteInfo{
            .method = owned.first,
            .path = owned.second,
            .request_schema_refs = .empty,
            .request_schema_dynamic = wire.requestSchemaDynamic,
            .requires_bearer = wire.requiresBearer,
            .requires_jwt = wire.requiresJwt,
        };
        errdefer route.deinit(allocator);
        route.request_schema_refs = try projectStringList(allocator, wire.requestSchemaRefs);
        route.path_params = try projectApiParams(allocator, wire.pathParams);
        route.query_params = try projectApiParams(allocator, wire.queryParams);
        route.header_params = try projectApiParams(allocator, wire.headerParams);
        route.query_params_dynamic = wire.queryParamsDynamic;
        route.header_params_dynamic = wire.headerParamsDynamic;
        route.request_bodies = try projectApiBodies(allocator, wire.requestBodies);
        route.request_bodies_dynamic = wire.requestBodiesDynamic;
        route.responses = try projectApiResponses(allocator, wire.responses);
        route.responses_dynamic = wire.responsesDynamic;
        route.response_status = if (wire.responseStatus) |status| status.value else null;
        route.response_content_type = try dupeOptionalWireString(allocator, wire.responseContentType);
        route.response_schema_ref = try dupeOptionalWireString(allocator, wire.responseSchemaRef);
        route.response_schema_json = if (wire.responseSchema) |schema|
            try allocator.dupe(u8, schema.bytes)
        else
            null;
        route.response_schema_dynamic = wire.responseSchemaDynamic;
        try backfillApiRouteCollections(allocator, &route);
        routes.appendAssumeCapacity(route);
    }
}

fn projectApiParams(
    allocator: std.mem.Allocator,
    wires: []const ApiParamWire,
) !std.ArrayList(ApiParamInfo) {
    var result: std.ArrayList(ApiParamInfo) = .empty;
    errdefer {
        for (result.items) |*param| param.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        const name = try dupeWireString(allocator, wire.name);
        const schema_json = allocator.dupe(u8, wire.schema.bytes) catch |err| {
            allocator.free(name);
            return err;
        };
        var param = ApiParamInfo{
            .name = name,
            .location = toStaticParamLocation(wire.location.bytes),
            .required = wire.required,
            .schema_json = schema_json,
        };
        errdefer param.deinit(allocator);
        result.appendAssumeCapacity(param);
    }
    return result;
}

fn projectApiBodies(
    allocator: std.mem.Allocator,
    wires: []const ApiBodyWire,
) !std.ArrayList(ApiBodyInfo) {
    var result: std.ArrayList(ApiBodyInfo) = .empty;
    errdefer {
        for (result.items) |*body| body.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        var body = ApiBodyInfo{
            .content_type = try dupeOptionalWireString(allocator, wire.contentType),
            .schema = .none,
        };
        errdefer body.deinit(allocator);
        body.schema = try projectWireSchemaSpec(allocator, wire.schemaRef, wire.schema, wire.dynamic);
        result.appendAssumeCapacity(body);
    }
    return result;
}

fn projectApiResponses(
    allocator: std.mem.Allocator,
    wires: []const ApiResponseWire,
) !std.ArrayList(ApiResponseInfo) {
    var result: std.ArrayList(ApiResponseInfo) = .empty;
    errdefer {
        for (result.items) |*response| response.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        var response = ApiResponseInfo{
            .status = if (wire.status) |status| status.value else null,
            .content_type = try dupeOptionalWireString(allocator, wire.contentType),
            .schema = .none,
        };
        errdefer response.deinit(allocator);
        response.schema = try projectWireSchemaSpec(allocator, wire.schemaRef, wire.schema, wire.dynamic);
        result.appendAssumeCapacity(response);
    }
    return result;
}

/// The one place the schema precedence (dynamic > inline JSON > ref > none) is
/// encoded. Wire-typed callers unwrap through `projectWireSchemaSpec` so the two
/// entry points cannot drift apart: a route's `request_bodies` and its
/// backfilled `responses` have to agree for the same contract to round-trip.
fn projectSchemaSpec(
    allocator: std.mem.Allocator,
    schema_ref: ?[]const u8,
    schema_json: ?[]const u8,
    dynamic: bool,
) !SchemaSpec {
    if (dynamic) return .dynamic;
    if (schema_json) |schema| return .{ .inline_json = try allocator.dupe(u8, schema) };
    if (schema_ref) |reference| return .{ .ref = try allocator.dupe(u8, reference) };
    return .none;
}

fn projectWireSchemaSpec(
    allocator: std.mem.Allocator,
    schema_ref: ?WireString,
    schema_json: ?RawJson,
    dynamic: bool,
) !SchemaSpec {
    return projectSchemaSpec(
        allocator,
        if (schema_ref) |value| value.bytes else null,
        if (schema_json) |value| value.bytes else null,
        dynamic,
    );
}

fn backfillApiRouteCollections(
    allocator: std.mem.Allocator,
    route: *ApiRouteInfo,
) !void {
    if (route.request_bodies.items.len == 0) {
        route.request_bodies_dynamic = route.request_bodies_dynamic or route.request_schema_dynamic;
        for (route.request_schema_refs.items) |schema_ref| {
            if (containsRequestBodySchemaRef(route.request_bodies.items, schema_ref)) continue;
            var body = ApiBodyInfo{
                .content_type = try allocator.dupe(u8, "application/json"),
                .schema = .none,
            };
            errdefer body.deinit(allocator);
            body.schema = .{ .ref = try allocator.dupe(u8, schema_ref) };
            try route.request_bodies.append(allocator, body);
        }
    }
    if (route.responses.items.len == 0 and
        (route.response_status != null or
            route.response_content_type != null or
            route.response_schema_ref != null or
            route.response_schema_json != null or
            route.response_schema_dynamic))
    {
        var response = ApiResponseInfo{
            .status = route.response_status,
            .content_type = if (route.response_content_type) |value|
                try allocator.dupe(u8, value)
            else
                null,
            .schema = .none,
        };
        errdefer response.deinit(allocator);
        response.schema = try projectSchemaSpec(
            allocator,
            route.response_schema_ref,
            route.response_schema_json,
            route.response_schema_dynamic,
        );
        try route.responses.append(allocator, response);
        route.responses_dynamic = route.responses_dynamic or route.response_schema_dynamic;
    }
}

fn containsRequestBodySchemaRef(
    items: []const ApiBodyInfo,
    needle: []const u8,
) bool {
    for (items) |item| {
        const schema_ref = item.schema.schemaRef() orelse continue;
        if (std.mem.eql(u8, schema_ref, needle)) return true;
    }
    return false;
}

fn projectVerification(
    wire: ?VerificationWire,
    contract: *HandlerContract,
) void {
    contract.verification = if (wire) |value| .{
        .exhaustive_returns = value.exhaustiveReturns,
        .results_safe = value.resultsSafe,
        .unreachable_code = value.unreachableCode,
        .bytecode_verified = value.bytecodeVerified,
    } else null;
}

fn projectWebSocket(
    wire: ?WebSocketWire,
    contract: *HandlerContract,
) void {
    contract.websocket = if (wire) |value| .{
        .on_open = value.onOpen,
        .on_message = value.onMessage,
        .on_close = value.onClose,
        .on_error = value.onError,
    } else .{};
}

fn projectFaultCoverage(
    wire: ?FaultCoverageWire,
    contract: *HandlerContract,
) void {
    contract.fault_coverage = if (wire) |value| .{
        .total_failable = value.totalFailable.value orelse 0,
        .covered = value.covered.value orelse 0,
        .warnings = value.warnings.value orelse 0,
    } else null;
}

fn projectProperties(
    wire: ?PropertiesWire,
    contract: *HandlerContract,
) void {
    contract.properties = if (wire) |value| .{
        .pure = value.pure,
        .read_only = value.readOnly,
        .stateless = value.stateless,
        .retry_safe = value.retrySafe,
        .deterministic = value.deterministic,
        .has_egress = value.hasEgress,
        .no_secret_leakage = value.noSecretLeakage,
        .no_credential_leakage = value.noCredentialLeakage,
        .input_validated = value.inputValidated,
        .pii_contained = value.piiContained,
        .idempotent = value.idempotent,
        .max_io_depth = if (value.maxIoDepth) |depth| depth.value else null,
        .injection_safe = value.injectionSafe,
        .state_isolated = value.stateIsolated,
        .fault_covered = value.faultCovered,
        .result_safe = value.resultSafe,
        .optional_safe = value.optionalSafe,
        .post_only = value.postOnly,
        .canonical = value.canonical,
        .cost_bounded = value.costBounded,
    } else null;
}

fn projectSpecDiagnostics(
    allocator: std.mem.Allocator,
    wires: ?[]const SpecDiagnosticWire,
    contract: *HandlerContract,
) !void {
    const values = wires orelse return;
    try contract.spec_diagnostics.ensureTotalCapacity(allocator, values.len);
    for (values) |wire| {
        var kind: ?SpecDiagnostic.Kind = null;
        if (wire.kind) |raw| {
            kind = specDiagnosticKindFromString(raw.bytes) orelse return error.InvalidJson;
        }
        if (wire.code) |raw| {
            kind = specDiagnosticKindFromCode(raw.bytes) orelse kind;
        }
        const spec_name = wire.specName orelse return error.InvalidJson;
        var diagnostic = SpecDiagnostic{
            .kind = kind orelse return error.InvalidJson,
            .spec_name = try dupeWireString(allocator, spec_name),
            .incompatible_module = null,
            .suggestion = null,
            .function = null,
        };
        errdefer diagnostic.deinit(allocator);
        diagnostic.incompatible_module = try dupeOptionalWireString(allocator, wire.incompatibleModule);
        diagnostic.suggestion = try dupeOptionalWireString(allocator, wire.suggestion);
        diagnostic.function = try dupeOptionalWireString(allocator, wire.function);
        contract.spec_diagnostics.appendAssumeCapacity(diagnostic);
    }
}

fn projectSandbox(
    wire: ?SandboxWire,
    contract: *HandlerContract,
) !void {
    const sandbox = wire orelse return;
    if (sandbox.capabilities.value) |names| {
        var seen = [_]bool{false} ** capability_count;
        for (names) |name| {
            const capability = std.meta.stringToEnum(ModuleCapability, name.bytes) orelse continue;
            seen[@intFromEnum(capability)] = true;
        }
        var matrix: CapabilityMatrix = .{};
        for (std.enums.values(ModuleCapability)) |capability| {
            if (seen[@intFromEnum(capability)]) {
                matrix.items[matrix.len] = capability;
                matrix.len += 1;
            }
        }
        var have_hash = false;
        if (sandbox.capabilityHash.value) |hash| {
            have_hash = try parseOptionalHash(&matrix.hash, hash.bytes);
        }
        if (!have_hash or std.mem.allEqual(u8, &matrix.hash, 0)) {
            matrix.hash = module_binding.capabilityHash(matrix.slice());
        }
        contract.capabilities = matrix;
    }
    if (sandbox.policyHash.value) |hash| _ = try parseOptionalHash(&contract.policy_hash, hash.bytes);
    if (sandbox.wasmPolicyHash.value) |hash| _ = try parseOptionalHash(&contract.wasm_policy_hash, hash.bytes);
    if (sandbox.artifactSha256.value) |hash| _ = try parseOptionalHash(&contract.artifact_sha256, hash.bytes);
}

fn parseOptionalHash(target: *[32]u8, raw: []const u8) !bool {
    if (raw.len != 64) return false;
    _ = std.fmt.hexToBytes(target, raw) catch return error.InvalidJson;
    return true;
}

fn projectIntent(
    allocator: std.mem.Allocator,
    wire: ?IntentWire,
    contract: *HandlerContract,
) !void {
    const value = wire orelse return;
    var intent = contract_types.IntentInfo{ .dynamic = value.dynamic };
    errdefer intent.deinit(allocator);
    try intent.assertions.ensureTotalCapacity(allocator, value.assertions.len);
    for (value.assertions) |assertion_wire| {
        const owned = try dupeWireStringTriple(
            allocator,
            assertion_wire.name,
            assertion_wire.method,
            assertion_wire.path,
        );
        var assertion = contract_types.IntentAssertion{
            .name = owned.first,
            .method = owned.second,
            .path = owned.third,
        };
        errdefer assertion.deinit(allocator);
        if (assertion_wire.requestBodyJson) |body| {
            assertion.request_body_json = try json_utils.unescapeJson(allocator, body.bytes);
        }
        assertion.expected_status = if (assertion_wire.expectedStatus) |status| status.value else null;
        if (assertion_wire.expectedBodyJson) |body| {
            assertion.expected_body_json = try json_utils.unescapeJson(allocator, body.bytes);
        }
        try assertion.expected_headers.ensureTotalCapacity(allocator, assertion_wire.expectedHeaders.len);
        for (assertion_wire.expectedHeaders) |header_wire| {
            const header_owned = try dupeWireStringPair(allocator, header_wire.name, header_wire.value);
            var header = contract_types.IntentExpectedHeader{
                .name = header_owned.first,
                .value = header_owned.second,
            };
            errdefer header.deinit(allocator);
            assertion.expected_headers.appendAssumeCapacity(header);
        }
        assertion.source_line = assertion_wire.sourceLine.value orelse 0;
        assertion.source_column = assertion_wire.sourceColumn.value orelse 0;
        intent.assertions.appendAssumeCapacity(assertion);
    }
    contract.intent = intent;
}

fn projectSagas(
    allocator: std.mem.Allocator,
    wires: []const SagaWire,
    contract: *HandlerContract,
) !void {
    try contract.sagas.ensureTotalCapacity(allocator, wires.len);
    for (wires) |wire| {
        var saga = contract_types.SagaCallInfo{
            .dynamic = wire.dynamic,
            .source_line = wire.sourceLine.value orelse 0,
            .source_column = wire.sourceColumn.value orelse 0,
        };
        errdefer saga.deinit(allocator);
        try saga.steps.ensureTotalCapacity(allocator, wire.steps.len);
        for (wire.steps) |step_wire| {
            const name = try dupeWireString(allocator, step_wire.name);
            errdefer allocator.free(name);
            saga.steps.appendAssumeCapacity(.{
                .name = name,
                .has_compensate = step_wire.hasCompensate,
            });
        }
        contract.sagas.appendAssumeCapacity(saga);
    }
}

fn projectBehaviors(
    allocator: std.mem.Allocator,
    wires: ?[]const BehaviorWire,
    contract: *HandlerContract,
) !void {
    const values = wires orelse return;
    try contract.behaviors.ensureTotalCapacity(allocator, values.len);
    for (values) |wire| {
        const owned = try dupeWireStringPair(allocator, wire.method, wire.pattern);
        var behavior = contract_types.BehaviorPath{
            .route_method = owned.first,
            .route_pattern = owned.second,
            .conditions = .empty,
            .io_sequence = .empty,
            .response_status = wire.status.value orelse 0,
            .io_depth = wire.ioDepth.value orelse 0,
            .is_failure_path = wire.failurePath,
        };
        errdefer behavior.deinit(allocator);
        try behavior.conditions.ensureTotalCapacity(allocator, wire.conditions.len);
        for (wire.conditions) |condition_wire| {
            var condition = PathCondition{
                .kind = std.meta.stringToEnum(PathCondition.Kind, condition_wire.kind.bytes) orelse .io_ok,
            };
            errdefer condition.deinit(allocator);
            condition.module = try dupeOptionalWireString(allocator, condition_wire.module);
            condition.func = try dupeOptionalWireString(allocator, condition_wire.func);
            condition.value = try dupeOptionalWireString(allocator, condition_wire.value);
            behavior.conditions.appendAssumeCapacity(condition);
        }
        try behavior.io_sequence.ensureTotalCapacity(allocator, wire.ioSequence.len);
        for (wire.ioSequence) |io_wire| {
            const io_owned = try dupeWireStringPair(allocator, io_wire.module, io_wire.func);
            var io_call = PathIoCall{
                .module = io_owned.first,
                .func = io_owned.second,
                .arg_signature = null,
            };
            errdefer io_call.deinit(allocator);
            io_call.arg_signature = try dupeOptionalWireString(allocator, io_wire.args);
            behavior.io_sequence.appendAssumeCapacity(io_call);
        }
        contract.behaviors.appendAssumeCapacity(behavior);
    }
}

fn projectCostEnvelope(
    allocator: std.mem.Allocator,
    wire: ?CostEnvelopeWire,
) !?CostEnvelope {
    const value = wire orelse return null;
    var envelope = CostEnvelope{
        .total = try projectBound(allocator, &value.total),
        .exhaustive = value.exhaustive,
    };
    errdefer envelope.deinit(allocator);
    try envelope.entries.ensureTotalCapacity(allocator, value.perModule.len);
    for (value.perModule) |entry_wire| {
        const module = entry_wire.module orelse return error.InvalidJson;
        const owned_module = try dupeWireString(allocator, module);
        errdefer allocator.free(owned_module);
        const bound = if (entry_wire.bound) |bound_wire|
            try projectBound(allocator, &bound_wire)
        else
            Bound{ .constant = 0 };
        envelope.entries.appendAssumeCapacity(.{
            .module = owned_module,
            .bound = bound,
        });
    }
    return envelope;
}

fn projectBound(
    allocator: std.mem.Allocator,
    wire: *const BoundWire,
) !Bound {
    const class = wire.class orelse return error.InvalidJson;
    if (std.mem.eql(u8, class.bytes, "constant")) {
        return .{ .constant = wire.value.value orelse 0 };
    }
    if (std.mem.eql(u8, class.bytes, "linear")) {
        const source = wire.source orelse return error.InvalidJson;
        return .{ .linear = .{
            .coefficient = wire.coefficient.value orelse return error.InvalidJson,
            .base = wire.base.value orelse 0,
            .source = try projectProvenance(allocator, &source),
        } };
    }
    if (std.mem.eql(u8, class.bytes, "unbounded")) {
        const source = wire.source orelse return error.InvalidJson;
        return .{ .unbounded = try projectProvenance(allocator, &source) };
    }
    return error.InvalidJson;
}

fn projectProvenance(
    allocator: std.mem.Allocator,
    wire: *const ProvenanceWire,
) !BoundProvenance {
    return .{
        .line = wire.line.value orelse 0,
        .column = wire.column.value orelse 0,
        .desc = try dupeWireString(allocator, wire.desc),
    };
}

fn projectExtensions(
    allocator: std.mem.Allocator,
    wires: *const ExtensionMap,
    contract: *HandlerContract,
) !void {
    for (wires.entries) |entry| {
        const key = try dupeWireString(allocator, entry.key);
        errdefer allocator.free(key);
        var extension = contract_types.ExtensionContract{
            .egress_hosts = try projectStringList(allocator, entry.value.egressHosts),
            .egress_dynamic = entry.value.egressDynamic,
            .contract_section = null,
        };
        errdefer extension.deinit(allocator);
        extension.contract_section = if (entry.value.contractSection) |section|
            try allocator.dupe(u8, section.bytes)
        else
            null;
        for (entry.value.categories.entries) |category| {
            const category_key = try dupeWireString(allocator, category.key);
            errdefer allocator.free(category_key);
            var bucket = contract_types.ExtensionCategoryBucket{
                .literals = try projectStringList(allocator, category.value.literals),
                .dynamic = category.value.dynamic,
            };
            errdefer bucket.deinit(allocator);
            try extension.categories.put(allocator, category_key, bucket);
        }
        try contract.extensions.put(allocator, key, extension);
    }
}

fn projectRateLimit(
    allocator: std.mem.Allocator,
    wire: ?RateLimitWire,
    contract: *HandlerContract,
) !void {
    const value = wire orelse return;
    for (contract.cache.namespaces.items) |namespace| {
        if (std.mem.eql(u8, namespace, value.namespace.bytes)) {
            contract.rate_limiting = .{
                .namespace = namespace,
                .dynamic = value.dynamic,
            };
            return;
        }
    }
    const namespace = try dupeWireString(allocator, value.namespace);
    contract.owned_rate_limit_namespace = namespace;
    contract.rate_limiting = .{
        .namespace = namespace,
        .dynamic = value.dynamic,
    };
}

fn toStaticRouteType(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "exact")) return "exact";
    if (std.mem.eql(u8, value, "prefix")) return "prefix";
    return "unknown";
}

fn toStaticField(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "url")) return "url";
    return "path";
}

fn toStaticContentType(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "text/plain; charset=utf-8")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, value, "text/html; charset=utf-8")) return "text/html; charset=utf-8";
    return "application/json";
}

fn toStaticParamLocation(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "query")) return "query";
    if (std.mem.eql(u8, value, "header")) return "header";
    return "path";
}

fn parseOwnedStaticOperation(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "select")) return "select";
    if (std.mem.eql(u8, value, "insert")) return "insert";
    if (std.mem.eql(u8, value, "update")) return "update";
    if (std.mem.eql(u8, value, "delete")) return "delete";
    return "";
}

fn specDiagnosticKindFromString(value: []const u8) ?SpecDiagnostic.Kind {
    inline for (std.meta.fields(SpecDiagnostic.Kind)) |field| {
        if (std.mem.eql(u8, value, field.name)) {
            return @field(SpecDiagnostic.Kind, field.name);
        }
    }
    return null;
}

fn specDiagnosticKindFromCode(value: []const u8) ?SpecDiagnostic.Kind {
    inline for (std.meta.fields(SpecDiagnostic.Kind)) |field| {
        const kind = @field(SpecDiagnostic.Kind, field.name);
        if (std.mem.eql(u8, value, kind.code())) return kind;
    }
    return null;
}

test "parseFromJson surfaces InvalidJson on adversarial deep nesting" {
    const allocator = std.testing.allocator;
    const n = 4000;
    const buffer = try allocator.alloc(u8, n);
    defer allocator.free(buffer);
    @memset(buffer, '[');
    try std.testing.expectError(error.InvalidJson, parseFromJson(allocator, buffer));
}

test "parseFromJson compatibility matrix preserves unknown fields and enum fallbacks" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "futureRoot": {"nested": [1, {"enabled": true}]},
        \\  "version": 23,
        \\  "handler": {"future": [false], "path": "handler\n.ts", "line": 7, "column": 3},
        \\  "routes": [{
        \\    "future": {"deep": [null]},
        \\    "pattern": "/v1\titems",
        \\    "type": "future-match",
        \\    "field": "future-field",
        \\    "status": 201,
        \\    "contentType": "application/problem+json",
        \\    "aot": true
        \\  }],
        \\  "api": {"routes": [{
        \\    "future": {"nested": [1, 2]},
        \\    "method": "POST",
        \\    "path": "/v1/items",
        \\    "queryParams": [{
        \\      "future": {"value": true},
        \\      "name": "page",
        \\      "location": "cookie",
        \\      "required": true,
        \\      "schema": {"type": "integer"}
        \\    }]
        \\  }]}
        \\}
    ;
    var contract = try parseFromJson(allocator, json);
    defer contract.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 23), contract.version);
    try std.testing.expectEqualStrings("handler\\n.ts", contract.handler.path);
    try std.testing.expectEqual(@as(u32, 7), contract.handler.line);
    try std.testing.expectEqual(@as(usize, 1), contract.routes.items.len);
    try std.testing.expectEqualStrings("/v1\\titems", contract.routes.items[0].pattern);
    try std.testing.expectEqualStrings("unknown", contract.routes.items[0].route_type);
    try std.testing.expectEqualStrings("path", contract.routes.items[0].field);
    try std.testing.expectEqualStrings("application/json", contract.routes.items[0].content_type);
    try std.testing.expect(contract.routes.items[0].aot);
    try std.testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
    try std.testing.expectEqualStrings("POST", contract.api.routes.items[0].method);
    try std.testing.expectEqual(@as(usize, 1), contract.api.routes.items[0].query_params.items.len);
    try std.testing.expectEqualStrings("path", contract.api.routes.items[0].query_params.items[0].location);
    try std.testing.expectEqualStrings("{\"type\": \"integer\"}", contract.api.routes.items[0].query_params.items[0].schema_json);
}

test "parseFromJson compatibility matrix preserves legacy API response backfill" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "api": {"routes": [{
        \\    "method": "GET",
        \\    "path": "/legacy",
        \\    "responseStatus": 204,
        \\    "responseContentType": "text/plain",
        \\    "responseSchemaRef": "LegacyResponse"
        \\  }]}
        \\}
    ;
    var contract = try parseFromJson(allocator, json);
    defer contract.deinit(allocator);
    const route = contract.api.routes.items[0];
    try std.testing.expectEqual(@as(usize, 1), route.responses.items.len);
    try std.testing.expectEqual(@as(?u16, 204), route.responses.items[0].status);
    try std.testing.expectEqualStrings("text/plain", route.responses.items[0].content_type orelse unreachable);
    try std.testing.expectEqualStrings("LegacyResponse", route.responses.items[0].schema.schemaRef() orelse unreachable);
}

test "parseFromJson legacy request backfill deduplicates schema refs" {
    const json =
        \\{"api":{"routes":[{
        \\  "method":"POST",
        \\  "path":"/legacy",
        \\  "requestSchemaRefs":["LegacyBody","LegacyBody"]
        \\}]}}
    ;
    var contract = try parseFromJson(std.testing.allocator, json);
    defer contract.deinit(std.testing.allocator);
    const route = contract.api.routes.items[0];
    try std.testing.expectEqual(@as(usize, 1), route.request_bodies.items.len);
    try std.testing.expectEqualStrings("LegacyBody", route.request_bodies.items[0].schema.schemaRef() orelse unreachable);
}

test "parseFromJson preserves escaped extension map keys" {
    const json =
        \\{"extensions":{
        \\  "a":{"egressDynamic":true},
        \\  "\u0061":{"categories":{"\u0062":{"dynamic":true}}}
        \\}}
    ;
    var contract = try parseFromJson(std.testing.allocator, json);
    defer contract.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), contract.extensions.count());
    try std.testing.expect((contract.extensions.get("a") orelse unreachable).egress_dynamic);
    try std.testing.expect((contract.extensions.get("\\u0061") orelse unreachable).categories.contains("\\u0062"));
}

test "parseFromJson compatibility matrix preserves duplicate trailing and overflow behavior" {
    const cases = [_]struct {
        json: []const u8,
        version: u32,
    }{
        .{ .json = "{\"version\":1,\"version\":23} trailing", .version = 23 },
        .{ .json = "{\"version\":99999999999999999999}", .version = 17 },
    };
    for (cases) |case| {
        var contract = try parseFromJson(std.testing.allocator, case.json);
        defer contract.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.version, contract.version);
    }
}

test "parseFromJson keeps raw structural keys and appends repeated collections" {
    const json =
        \\{
        \\  "versi\u006fn": 99,
        \\  "modules": ["zttp:env"],
        \\  "modules": ["zttp:cache"],
        \\  "cache": {"dynamic": true},
        \\  "cache": {"namespaces": ["sessions"]},
        \\  "properties": {"noSecretLeakag\u0065": true}
        \\}
    ;
    var contract = try parseFromJson(std.testing.allocator, json);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 17), contract.version);
    try std.testing.expectEqual(@as(usize, 2), contract.modules.items.len);
    try std.testing.expectEqualStrings("zttp:env", contract.modules.items[0]);
    try std.testing.expectEqualStrings("zttp:cache", contract.modules.items[1]);
    try std.testing.expect(contract.cache.dynamic);
    try std.testing.expectEqualStrings("sessions", contract.cache.namespaces.items[0]);
    try std.testing.expect(!(contract.properties orelse unreachable).no_secret_leakage);
}

test "parseFromJson accumulates repeated optional contract sections" {
    const json =
        \\{
        \\  "sandbox": {"capabilities": ["clock"]},
        \\  "sandbox": null,
        \\  "sandbox": {"policyHash": "1111111111111111111111111111111111111111111111111111111111111111"},
        \\  "durable": {"workflow": {"workflowId": "workflow.ts:handler"}},
        \\  "durable": {"workflow": null},
        \\  "durable": {"workflow": {"proofLevel": "complete"}},
        \\  "behaviors": [{"method": "GET", "pattern": "/first"}],
        \\  "behaviors": null,
        \\  "behaviors": [{"method": "POST", "pattern": "/second"}]
        \\}
    ;
    var contract = try parseFromJson(std.testing.allocator, json);
    defer contract.deinit(std.testing.allocator);

    const capabilities = contract.capabilities orelse unreachable;
    try std.testing.expect(capabilities.has(.clock));
    try std.testing.expectEqual(@as(u8, 0x11), contract.policy_hash[0]);
    try std.testing.expectEqualStrings("workflow.ts:handler", contract.durable.workflow.workflow_id orelse unreachable);
    try std.testing.expectEqual(contract_types.DurableWorkflowProofLevel.complete, contract.durable.workflow.proof_level);
    try std.testing.expectEqual(@as(usize, 2), contract.behaviors.items.len);
    try std.testing.expectEqualStrings("/first", contract.behaviors.items[0].route_pattern);
    try std.testing.expectEqualStrings("/second", contract.behaviors.items[1].route_pattern);
}

test "parseFromJson keeps capability hashes scoped to one sandbox object" {
    const supplied_hash = "1111111111111111111111111111111111111111111111111111111111111111";
    const cases = [_][]const u8{
        "{\"sandbox\":{\"capabilities\":[\"clock\"]},\"sandbox\":{\"capabilityHash\":\"" ++ supplied_hash ++ "\"}}",
        "{\"sandbox\":{\"capabilityHash\":\"" ++ supplied_hash ++ "\"},\"sandbox\":{\"capabilities\":[\"clock\"]}}",
        "{\"sandbox\":{\"capabilities\":[\"clock\"],\"capabilityHash\":\"" ++ supplied_hash ++ "\"},\"sandbox\":{\"capabilities\":[\"clock\"]}}",
    };
    const expected_hash = module_binding.capabilityHash(&.{.clock});
    for (cases) |json| {
        var contract = try parseFromJson(std.testing.allocator, json);
        defer contract.deinit(std.testing.allocator);
        const capabilities = contract.capabilities orelse unreachable;
        try std.testing.expect(capabilities.has(.clock));
        try std.testing.expectEqualSlices(u8, &expected_hash, &capabilities.hash);
    }

    var same_object = try parseFromJson(
        std.testing.allocator,
        "{\"sandbox\":{\"capabilities\":[\"clock\"],\"capabilityHash\":\"" ++ supplied_hash ++ "\"}}",
    );
    defer same_object.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.allEqual(u8, &(same_object.capabilities orelse unreachable).hash, 0x11));

    var repeated_capabilities = try parseFromJson(
        std.testing.allocator,
        "{\"sandbox\":{\"capabilities\":[\"clock\"],\"capabilities\":[\"crypto\"]}}",
    );
    defer repeated_capabilities.deinit(std.testing.allocator);
    const matrix = repeated_capabilities.capabilities orelse unreachable;
    try std.testing.expect(matrix.has(.clock));
    try std.testing.expect(matrix.has(.crypto));
}

test "parseFromJson rejects explicit null sandbox proof fields" {
    const cases = [_][]const u8{
        "{\"sandbox\":{\"capabilities\":null}}",
        "{\"sandbox\":{\"capabilityHash\":null}}",
        "{\"sandbox\":{\"policyHash\":null}}",
        "{\"sandbox\":{\"wasmPolicyHash\":null}}",
        "{\"sandbox\":{\"artifactSha256\":null}}",
    };
    for (cases) |json| {
        try std.testing.expectError(error.InvalidJson, parseFromJson(std.testing.allocator, json));
    }
}

test "parseFromJson rate limit metadata does not grant cache access" {
    const json =
        \\{"rateLimiting":{"namespace":"login-attempts","dynamic":false}}
    ;
    var contract = try parseFromJson(std.testing.allocator, json);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), contract.cache.namespaces.items.len);
    const rate_limit = contract.rate_limiting orelse unreachable;
    try std.testing.expectEqualStrings("login-attempts", rate_limit.namespace);
    try std.testing.expect(!rate_limit.dynamic);
}

test "parseFromJson owns projected strings raw JSON and extension keys" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8,
        \\{
        \\  "handler": {"path": "owned.ts"},
        \\  "api": {"schemas": [{"name": "Thing", "schema": {"type":"string"}}]},
        \\  "extensions": {"owned-extension": {"contractSection": "proof"}}
        \\}
    );
    var contract = try parseFromJson(allocator, source);
    @memset(source, 'x');
    allocator.free(source);
    defer contract.deinit(allocator);

    try std.testing.expectEqualStrings("owned.ts", contract.handler.path);
    try std.testing.expectEqualStrings("{\"type\":\"string\"}", contract.api.schemas.items[0].schema_json);
    const extension = contract.extensions.get("owned-extension") orelse unreachable;
    try std.testing.expectEqualStrings("proof", extension.contract_section orelse unreachable);
}

test "parseFromJson malformed structure matrix fails closed" {
    const cases = [_][]const u8{
        "[]",
        "{\"modules\":[1]}",
        "{\"routes\":[1]}",
        "{\"api\":{\"routes\":[1]}}",
        "{\"handler\":{\"path\":\"unterminated",
    };
    for (cases) |json| {
        try std.testing.expectError(error.InvalidJson, parseFromJson(std.testing.allocator, json));
    }
}

fn parseAllocationFixture(
    allocator: std.mem.Allocator,
    json: []const u8,
) !void {
    var contract = try parseFromJson(allocator, json);
    defer contract.deinit(allocator);
}

test "parseFromJson cleans every allocation failure" {
    const json =
        \\{
        \\  "handler": {"path": "handler.ts"},
        \\  "modules": ["zttp:env"],
        \\  "env": {"literal": ["SECRET"], "dynamic": false},
        \\  "extensions": {"x\\u002dy": {"categories": {"audit": {"literals": ["read"]}}}},
        \\  "api": {"routes": [{
        \\    "method": "POST",
        \\    "path": "/items",
        \\    "queryParams": [{"name": "page", "schema": {"type": "integer"}}],
        \\    "requestSchemaRefs": ["ItemInput"],
        \\    "responseStatus": 201,
        \\    "responseContentType": "application/json",
        \\    "responseSchemaRef": "Item"
        \\  }]},
        \\  "rateLimiting": {"namespace": "login-attempts", "dynamic": false}
        \\}
    ;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAllocationFixture,
        .{json},
    );
}
