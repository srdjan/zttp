// Nominal brands: a scalar identity the checker enforces and the runtime does
// not pay for.
//
// `Nominal<Base, Identity>` adds a unique scalar identity that the runtime
// erases. Each `unique symbol` keeps its brand separate from every other brand.
// Two brands over the same base remain incompatible.
//
// Create a branded value only with the recognized `nominal<T>(value)` helper:
//
//     const id: UserId = nominal<UserId>("u-1"); // brands
//     const id: UserId = "u-1";                    // refused
//
// The helper checks the base value and preserves the value at runtime. A raw
// value cannot be passed where a brand is required.
//
// The brand is erased at comptime. Below the checker a `UserId` is a `string`,
// which is what `typeof` reports in the response.

import { nominal } from "zttp:core";
import type { Nominal } from "zttp:core";

declare const userIdBrand: unique symbol;
type UserId = Nominal<string, typeof userIdBrand>;
declare const orderRefBrand: unique symbol;
type OrderRef = Nominal<string, typeof orderRefBrand>;
declare const portBrand: unique symbol;
type Port = Nominal<number, typeof portBrand>;

function describeUser(id: UserId): string {
  return ["user:", id].join("");
}

function describeOrder(ref: OrderRef): string {
  return ["order:", ref].join("");
}

function describePort(p: Port): string {
  return ["port:", String(p)].join("");
}

// `typeof` reads the runtime value. The parameter is `unknown`, so the checker
// does not fold the comparison to a constant, as it does for a `UserId` read
// directly.
function isRuntimeString(value: unknown): boolean {
  return typeof value === "string";
}

type Branded<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "pure"
    | "stateless"
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

function handler(req: Request): Branded<Response> {
  const id: UserId = nominal<UserId>("u-1");
  const ref: OrderRef = nominal<OrderRef>("o-9");
  const port: Port = nominal<Port>(8080);

  return Response.json({
    user: describeUser(id),
    order: describeOrder(ref),
    port: describePort(port),
    erased: isRuntimeString(id),
  });
}
