# Virtual Modules Reference

All imports use the `zttp:` prefix. Native Zig implementations with zero JS interpretation overhead.

## zttp:env (effect: read)

```typescript
import { env } from "zttp:env";

env(name: string): string | undefined

const dbUrl = env("DATABASE_URL") ?? "postgres://localhost";
```

## zttp:crypto (effect: read)

```typescript
import { sha256, hmacSha256, base64Encode, base64Decode } from "zttp:crypto";

sha256(data: string): string                    // hex-encoded
hmacSha256(key: string, data: string): string   // hex-encoded
base64Encode(data: string): string
base64Decode(data: string): string
```

## zttp:auth (effect: read)

```typescript
import { parseBearer, jwtVerify, jwtSign, verifyWebhookSignature, timingSafeEqual } from "zttp:auth";

parseBearer(header: string): string | undefined
jwtVerify(token: string, secret: string, alg?: "HS256"):
    { ok: true, value: object } | { ok: false, error: string }
jwtSign(claims: string, secret: string): string
verifyWebhookSignature(payload: string, secret: string, signature: string): boolean
timingSafeEqual(a: string, b: string): boolean
```

Always check `.ok` before accessing `.value` - the verifier enforces this. `jwtSign` takes JSON-stringified claims and always returns a string (not optional). `jwtVerify` accepts an optional third argument for the signing algorithm; only `"HS256"` is supported.

## zttp:validate (effect: read)

```typescript
import { schemaCompile, validateJson, validateObject, coerceJson, schemaDrop } from "zttp:validate";

schemaCompile(name: string, schema_json: string): boolean
validateJson(name: string, json: string): { ok: true, value: object } | { ok: false, errors: string[] }
validateObject(name: string, obj: object): { ok: true, value: object } | { ok: false, errors: string[] }
coerceJson(name: string, json: string): { ok: true, value: object } | { ok: false, errors: string[] }
schemaDrop(name: string): boolean
```

Schema supports: `type`, `required`, `properties`, `minLength`/`maxLength`, `minimum`/`maximum`, `enum`, `items`, `format`. Supported format values: `email`, `uuid`, `iso-date`, `iso-datetime`. `coerceJson` converts string numbers before validation.

## zttp:fetch (effect: write)

```typescript
import { fetch } from "zttp:fetch";

fetch(url: string, init?: {
    method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS",
    headers?: object,
    body?: string | Bytes,
    query?: object,
    maxResponseBytes?: number,
    durable?: object
}): {
    ok: boolean,
    status: number,
    statusText: string,
    body: string,
    headers: object,
    json: () => unknown,
    text: () => string
}
```

The URL argument must be a compiler-visible string literal so the contract can
prove the egress host. Never concatenate or interpolate user input into that
URL. Put dynamic values in `init.query`; the runtime percent-encodes them at
the boundary. Validate user input before placing it in the query object, and
check `upstream.ok` before reading the response:

```typescript
const upstream = fetch("https://api.example.com/v1/weather", {
    query: { city: checked.value["city"] },
    maxResponseBytes: 65536
});
```

<!-- compiler-probe: fetch-literal-query:start -->
```typescript
import { fetch } from "zttp:fetch";
import { schemaCompile, validateObject } from "zttp:validate";

schemaCompile("cityQuery", JSON.stringify({
    type: "object",
    required: ["city"],
    properties: {
        city: { type: "string", minLength: 1, maxLength: 64 }
    }
}));

export function handler(req: Request): Proof<Response,
    | "deterministic"
    | "state_isolated"
    | "fault_covered"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
> {
    const checked = validateObject("cityQuery", { city: req.query["city"] });
    if (!checked.ok) {
        return Response.json({ error: "missing or invalid city query parameter" }, { status: 400 });
    }
    const upstream = fetch("https://api.open-meteo.com/v1/forecast", {
        query: { city: checked.value["city"] },
        maxResponseBytes: 65536
    });
    if (!upstream.ok) {
        return Response.json({ error: "weather service unavailable" }, { status: 502 });
    }
    return Response.json(upstream.json());
}
```
<!-- compiler-probe: fetch-literal-query:end -->

## zttp:decode (effect: read)

Typed request ingress helpers. All require a prior `schemaCompile` call for the named schema. Return values carry the `validated` label for data flow analysis.

```typescript
import { decodeJson, decodeForm, decodeQuery } from "zttp:decode";

decodeJson(name: string, body: string): { ok: true, value: object } | { ok: false, errors: string[] }
decodeForm(name: string, body: string): { ok: true, value: object } | { ok: false, errors: string[] }
decodeQuery(name: string, query: object): { ok: true, value: object } | { ok: false, errors: string[] }
```

`decodeJson` parses JSON then validates. `decodeForm` parses URL-encoded form data (`key=val&key2=val2`, handles `+` and `%XX` encoding) then validates. `decodeQuery` validates a query object directly (typically `req.query`).

```typescript
schemaCompile("createUser", JSON.stringify({
    type: "object",
    required: ["name", "email"],
    properties: {
        name: { type: "string", minLength: 1 },
        email: { type: "string", format: "email" }
    }
}));

function handler(req: Request): Response {
    const result = decodeJson("createUser", req.body ?? "");
    if (!result.ok) return Response.json({ errors: result.errors }, { status: 400 });
    return Response.json({ created: result.value }, { status: 201 });
}
```

## zttp:cache (effect: write)

```typescript
import { cacheGet, cacheSet, cacheDelete, cacheIncr, cacheStats } from "zttp:cache";

cacheGet(namespace: string, key: string): string | undefined
cacheSet(namespace: string, key: string, value: string, ttl?: number): boolean
cacheDelete(namespace: string, key: string): boolean
cacheIncr(namespace: string, key: string, delta?: number, ttl?: number): number
cacheStats(namespace?: string): { hits: number, misses: number, entries: number, bytes: number }
```

All values are strings (`JSON.stringify` objects). TTL in seconds. Cache persists across requests in the same pool slot. Namespace isolation with global LRU eviction.

```typescript
const cached = cacheGet("sessions", token);
if (cached !== undefined) return Response.json(JSON.parse(cached));
// Compute and cache
const data = JSON.stringify(computeResult());
cacheSet("sessions", token, data, 300);
return Response.json(JSON.parse(data));
```

## zttp:router (effect: none)

```typescript
import { routerMatch } from "zttp:router";

routerMatch(routes: object, req: Request): { handler: function, params: object } | undefined
```

Route keys: `"METHOD /path/:param"`. Returns `undefined` on no match.

```typescript
const routes = {
    "GET /":           home,
    "GET /health":     health,
    "GET /users/:id":  getUser,
    "POST /users":     createUser,
};

function handler(req: Request): Response {
    const found = routerMatch(routes, req);
    if (found !== undefined) {
        req.params = found.params;
        return found.handler(req);
    }
    return Response.json({ error: "Not Found" }, { status: 404 });
}
```

## zttp:io (effect: write)

```typescript
import { parallel, race } from "zttp:io";
import { fetch } from "zttp:fetch";

parallel(thunks: Array<() => Response>): Array<Response>
race(thunks: Array<() => Response>): Response
```

Concurrent outbound fetch execution. Max 8 parallel thunks. Results remain in declaration order for `parallel`.

```typescript
const [user, orders] = parallel([
    () => fetch(["https://users.internal/", id].join("")),
    () => fetch(["https://orders.internal?user=", id].join(""))
]);

return Response.json({
    user: user.ok ? user.json() : undefined,
    orders: orders.ok ? orders.json() : []
});
```

## Guard flow (no module)

Guards are ordinary functions. Each answers a `Response` to refuse the request
or `undefined` to let it through, and the handler runs them in order.

```typescript
function cors(req: Request): Response | undefined {
    if (req.method === "OPTIONS") {
        return Response.text("", { status: 204, headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST"
        }});
    }
}

function requireAuth(req: Request): Response | undefined {
    const token = parseBearer(req.headers["authorization"]);
    if (token === undefined) return Response.json({ error: "unauthorized" }, { status: 401 });
    const secret = env("JWT_SECRET");
    if (secret === undefined) return Response.json({ error: "server misconfigured" }, { status: 500 });
    const result = jwtVerify(token, secret);
    if (!result.ok) return Response.json({ error: result.error }, { status: 403 });
}

function handler(req: Request): Response {
    const preflighted = cors(req);
    if (preflighted !== undefined) {
        return preflighted;
    }
    const refused = requireAuth(req);
    if (refused !== undefined) {
        return refused;
    }
    return routeHandler(req);
}
```

A guard that runs after the handler takes the response the same way: call the
handler, bind its result, run the guard on it, and return the guard's answer
when it gives one.

## zttp:durable (effect: write)

```typescript
import { run, step, stepWithTimeout, sleep, sleepUntil,
         waitSignal, signal, signalAt } from "zttp:durable";
import { fetch } from "zttp:fetch";

run(key: string, fn: () => Response): Response
step(name: string, fn: () => unknown): unknown
stepWithTimeout(name: string, timeoutMs: number, fn: () => unknown):
    { ok: true, value: unknown } | { ok: false, error: "timeout" }
sleep(ms: number): undefined
sleepUntil(unixMs: number): undefined
waitSignal(name: string): unknown
signal(key: string, name: string, payload?: unknown): boolean
signalAt(key: string, name: string, unixMs: number, payload?: unknown): boolean
```

Crash recovery for long-running workflows. Requires `--durable <dir>`. Pending waits return 202 Accepted. Completed steps replay from recorded results on recovery.

`stepWithTimeout` wraps a step with a deadline - returns a Result so you can handle timeout without crashing the workflow.

Handler proofs and helper proof capsules use different property vocabularies.
A handler `Proof<Response, P>` may declare any handler property published by
the live compiler. A non-handler helper `Proof<T, P>` may declare only
`total`, `pure`, `read_only`, or `deterministic`. Do not copy handler
properties such as `state_isolated` or `no_secret_leakage` onto helpers.
Module-internal helpers should normally return their plain value type.

```typescript
structural DurableProof<T> = Proof<T, "state_isolated" | "no_secret_leakage">;

function handler(req: Request): DurableProof<Response> {
    const key = req.headers.get("idempotency-key") ?? "order";
    return run(key, () => {
        const body = req.body ?? "{}";
        const reservation = step("reserve", () =>
            fetch("https://inventory.internal/reserve", { method: "POST", body: body })
        );
        sleep(5000);
        const charge = stepWithTimeout("charge", 10000, () =>
            fetch("https://payments.internal/charge", { method: "POST", body: body })
        );
        if (!charge.ok) return Response.json({ error: "payment timeout" }, { status: 504 });
        return Response.json({ reserved: reservation.status, charged: charge.value.status }, { status: 201 });
    });
}
```

A complete approval workflow uses the same idempotency key to park and resume
the durable run. Keep the handler proof on the handler rather than splitting
the two paths into helpers with handler-only proof properties.

<!-- compiler-probe: durable-wait-signal:start -->
```typescript
import { run, waitSignal, signal } from "zttp:durable";

structural ApprovalProof<T> = Proof<T,
    | "deterministic"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

function handler(req: Request): ApprovalProof<Response> {
    const key = req.headers.get("Idempotency-Key");
    if (key === undefined) {
        return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
    }
    if (req.method === "POST" && req.path === "/signal") {
        const delivered = signal(key, "approval", { approved: true });
        return Response.json({ delivered: delivered });
    }
    if (req.method !== "GET" || req.path !== "/wait") {
        return Response.json({ error: "not found" }, { status: 404 });
    }
    return run(key, () => {
        const approval = waitSignal("approval");
        return Response.json({ approved: approval !== undefined });
    });
}
```
<!-- compiler-probe: durable-wait-signal:end -->

## zttp:workflow (effect: write)

```typescript
import { call, saga, fanout, follow } from "zttp:workflow";

call(name: string, init?: { method?: string, path?: string, body?: unknown, headers?: object }): Response
saga(steps: { name: string, run: () => unknown, compensate?: () => unknown }[]): object
fanout(calls: { name: string, method?: string, path?: string, body?: unknown, headers?: object }[]): object
follow(resource: object, rel: string, init?: { body?: unknown, headers?: object }): object
```

In-process multi-handler orchestration. Requires a `--system <file>` handler bundle. Inside `durable.run()`, top-level `call`, `follow`, and `fanout` boundaries can be persisted through `--workflow-queue`; saga dispatch is intentionally rejected in queue mode.

Authoring rules:

- Use `req.headers.get("idempotency-key")` for durable run keys when the client supplies one.
- Put `workflow.call`, `fanout`, and `follow` at step depth 0 inside `run()`, not inside `step()`.
- ZTS509 rejects `workflow.call`, `saga`, `fanout`, or `follow` inside a durable `step()` callback.
- ZTS510 rejects statically analyzable saga steps when a non-last step lacks `compensate`.
- `fanout()` returns results in declaration order; it is ordered durable batch grouping, not true concurrency.

```typescript
import { run } from "zttp:durable";
import { call } from "zttp:workflow";

structural WorkflowGuarantees<T> = Proof<T,
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
>;

function handler(req: Request): WorkflowGuarantees<Response> {
    const key = req.headers.get("idempotency-key") ?? "workflow-demo";
    return run(key, () => {
        const child = call("greet", { method: "GET", path: "/workflow" });
        return Response.json({ childStatus: child.status });
    });
}
```

## zttp:sql (effect: io)

Registered SQL queries backed by SQLite. Queries are registered by name at module scope, then executed by name in the handler. All queries use parameter binding - never string interpolation.

```typescript
import { sql, sqlOne, sqlMany, sqlExec } from "zttp:sql";

sql(name: string, statement: string): boolean                              // register a named query
sqlOne(name: string, params?: object): object | undefined                  // single row or undefined
sqlMany(name: string, params?: object): object[]                           // array of rows
sqlExec(name: string, params?: object): { rowsAffected: number, lastInsertRowId?: number }  // write op
```

Register queries at module scope (runs once), execute in handler (runs per request):

```typescript
sql("get_user", "SELECT * FROM users WHERE id = :id");
sql("list_users", "SELECT id, name FROM users ORDER BY name LIMIT :limit");
sql("create_user", "INSERT INTO users (name, email) VALUES (:name, :email)");

function handler(req: Request): Response {
    const user = sqlOne("get_user", { id: req.params.id });
    if (user === undefined) return Response.json({ error: "not found" }, { status: 404 });
    return Response.json(user);
}
```
