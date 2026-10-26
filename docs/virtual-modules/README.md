# Virtual Modules

Virtual modules are native Zig APIs imported from `zttp:*` specifiers. The
current built-in set is registered in `packages/zts/src/builtin_modules.zig`;
public module specs live in `packages/modules/module-specs/`.

Use `zttp modules --json` for the live export list from the built binary.

## Module Catalog

<!-- BEGIN GENERATED: module catalog. Edit the Zig bindings, then run `zttp module-spec-render`. -->
| Module | Exports | Capabilities |
|---|---|---|
| `zttp:auth` | `parseBearer`, `jwtVerify`, `jwtSign`, `verifyWebhookSignature`, `timingSafeEqual` | `crypto`, `clock` |
| `zttp:bytes` | `bytesFromOctets`, `bytesLength`, `byteAt`, `sliceBytes`, `concatBytes`, `encodeUtf8`, `decodeUtf8`, `decodeBase64`, `encodeBase64` | none |
| `zttp:cache` | `cacheGet`, `cacheSet`, `cacheDelete`, `cacheIncr`, `cacheStats` | `clock`, `policy_check` |
| `zttp:collections` | `dictEmpty`, `dictFromEntries`, `dictGet`, `dictSet`, `dictRemove`, `dictHas`, `dictEntries`, `dictMapValues`, `dictFilter`, `dictFold` | none |
| `zttp:crypto` | `sha256`, `hmacSha256`, `base64Encode`, `base64Decode` | `crypto` |
| `zttp:decode` | `decodeJson`, `decodeForm`, `decodeQuery`, `decodeFormMultipart` | none |
| `zttp:env` | `env` | `env`, `policy_check` |
| `zttp:fetch` | `fetch`, `fetchWithRetry` | `network`, `runtime_callback` |
| `zttp:http` | `parseCookies`, `setCookie`, `negotiate`, `parseContentType`, `cors` | none |
| `zttp:id` | `uuid`, `ulid`, `nanoid` | `clock`, `random` |
| `zttp:json` | `parseJson`, `parseJsonBytes`, `stringifyJson` | none |
| `zttp:log` | `logDebug`, `logInfo`, `logWarn`, `logError` | `clock`, `stderr` |
| `zttp:ratelimit` | `rateCheck`, `rateReset` | `clock` |
| `zttp:result` | `ok`, `err`, `mapResult`, `mapError`, `andThen`, `orElse`, `unwrapOr`, `collectAll` | none |
| `zttp:router` | `routerMatch` | none |
| `zttp:sql` | `sql`, `sqlOne`, `sqlMany`, `sqlExec` | `sqlite`, `policy_check` |
| `zttp:sse` | `sseEvents` | none |
| `zttp:text` | `escapeHtml`, `unescapeHtml`, `slugify`, `truncate`, `mask` | none |
| `zttp:time` | `formatIso`, `formatHttp`, `parseIso`, `addSeconds` | none |
| `zttp:url` | `urlParse`, `urlSearchParams`, `urlEncode`, `urlDecode` | none |
| `zttp:validate` | `schemaCompile`, `validateJson`, `validateObject`, `coerceJson`, `schemaDrop` | none |
<!-- END GENERATED: module catalog -->

## Common Usage

```ts
import { env } from "zttp:env";
import { routerMatch } from "zttp:router";
import { sha256 } from "zttp:crypto";

function handler(req: Request): Response {
    const routes = { "GET /users/:id": true };
    const match = routerMatch(routes, req);
    if (match !== undefined) {
        return Response.json({
            id: match.params.id,
            tokenHash: sha256(env("API_TOKEN") ?? ""),
        });
    }
    return Response.text("Not Found", { status: 404 });
}
```

## Runtime Requirements

Most modules work without extra flags. Modules that cross a process, disk, or
durability boundary need configuration:

| Module | Requirement |
|---|---|
| `zttp:env` | Proven literal env vars are checked at startup unless `--no-env-check` is passed. The flow analysis treats every `env` value as secret unless the policy lists the name in `env.public`. |
| `zttp:sql` | Run with `--sqlite <file>` for execution. Use `--sql-schema <schema.sql>` or `-Dsql-schema=<schema.sql>` for schema validation. |
| `zttp:fetch` | Enable outbound HTTP with `--outbound-http` or one or more `--outbound-host <host>` flags. |
| `zttp:log` | Writes structured lines to stderr. Do not log raw secrets, tokens, or PII. |

## State Scope

| Module | Where its state lives |
|---|---|
| `zttp:ratelimit` | One store per handler pool. Every runtime of the pool counts into it, and it survives recycle and live reload. |
| `zttp:cache` | One store per pooled runtime. Entries can differ between requests and vanish when the runtime recycles. |

## Effects

The compiler reads each export's effect annotation when deriving handler
properties and runtime policy.

| Effect | Meaning | Examples |
|---|---|---|
| `none` | Pure or analysis-only operation. | `sha256`, `routerMatch`, `parseCookies`, `decodeJson` |
| `read` | Reads runtime state without mutating it. | `env`, `cacheGet`, `cacheStats`, `sqlOne`, `sqlMany` |
| `write` | Mutates state, performs I/O, or schedules runtime callbacks. | `fetch`, `sqlExec`, `cacheSet`, `logInfo` |

`fetchWithRetry(url, init?, retryOptions?)` accepts `maxRetries`,
`baseDelayMs`, `maxDelayMs`, and `retryOn`. To keep synchronous retry sleeps
bounded, `maxRetries` must be at most 10, `baseDelayMs` at most 5000, and
`maxDelayMs` at most 30000. Negative retry or delay values are treated as 0.

For capability governance internals, see
[Module Capabilities](../internals/capabilities.md).

## Ambient Proof Types

`Proof<T, P>` and `Effects<T, R>` are ambient type names. They require no
virtual module or type-only import and are erased before runtime.

See [TypeScript](../typescript.md) and
[Contracts and Auto-Sandboxing](../contracts-and-sandboxing.md) for active
specs and helper capsules.
