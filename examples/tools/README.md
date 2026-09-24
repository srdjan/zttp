# Reference tools

Two tool routes in one handler, for a model or agent to call over HTTP. Each
tool has a closed input schema, a closed output schema, and a byte bound on
its input. The runtime checks the caller's token, the input, and the output;
the handler code checks none of that itself.

- **`convert`** is pure and bounded. It converts a temperature between
  Celsius, Fahrenheit, and Kelvin, and it reaches no module that does I/O.
- **`order_status`** reads one order from an upstream for the caller's own
  tenant. The catalog `scope` binds the input field `tenant_id` to the tenant
  in the verified token, so a caller cannot ask about another tenant. The
  upstream call carries a credential that the runtime adds and this code never
  sees.

## Files

- `tools.ts`: the handler, the schemas, and the `toolCatalog` declaration.
- `zttp.json`: the entry, the token settings (`auth`), and the `orders`
  credential reference.
- `declaration.json`: the capability ceiling. The handler must stay inside the
  `adapter` profile and may not use `zttp:crypto`.
- `policy.json`: the egress policy. It allows the one upstream endpoint and the
  `loopback` address scope; without an address scope no outbound request
  connects.

## Build and run

```bash
zttp build -o tools
export TOOLS_JWT_KEY=<the HS256 key your token issuer signs with>
export ORDERS_API_KEY=<the upstream API key>
./tools -p 3000 --outbound-host 127.0.0.1
```

The binary refuses to start when either variable is unset or empty. A deployed
binary makes no outbound request unless the operator allows it with
`--outbound-http` or, narrower, `--outbound-host`. A request
names a tool route and carries a bearer token whose `tenant` claim is the
caller's tenant:

```bash
curl -X POST http://127.0.0.1:3000/tools/order_status \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"tenant_id":"acme","order_id":"o-17"}'
```

## The upstream endpoint

The `orders` reference names `http://127.0.0.1:39460`, a loopback address, so
the example runs as written against a local upstream; the check below serves
one there. A credential may use plain HTTP only to a loopback IP literal. For a
real upstream, change the endpoint in zttp.json, the URL in `lookupOrder`, and
the entry in `policy.json` to the same `https://` origin, set
`allow_address_scopes` to `public`, and adjust `paths` to the upstream's path
prefix. The build refuses a URL whose endpoint is not the reference's.

## What is checked

`zig build test-reference-tools` builds this directory into an artifact, runs
it, and sends real requests. It checks the positive path and each applicable
B8 case at its own boundary: another tenant's token (403), a forged `OrderId`
and a reach outside the ceiling (both refused at build), an oversized upstream
answer (502), a result outside the output schema (500), and one changed byte in
the declaration or the catalog of the artifact (refused at start). See
`packages/runtime/src/reference_tools_check.zig`.
