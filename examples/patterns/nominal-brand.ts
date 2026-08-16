// Nominal brands: a scalar identity the checker enforces and the runtime does
// not pay for.
//
// `nominal` mints a type that is structurally its base and incompatible with
// every other type, including another brand over the same base. Two functions
// taking `string` are one fact to a caller; two taking `UserId` and `OrderRef`
// are two.
//
// Construction is the annotated declaration, and only that:
//
//     const id: UserId = "u-1";        // brands
//     const id = UserId("u-1");        // refused, ZTS214
//
// The call form is not a constructor. It used to check clean and then fault at
// runtime with NotCallable, because nothing lowered it. Branding at the
// declaration keeps one visible site where a raw value becomes a branded one,
// and keeps a raw value from being accepted anywhere a brand is declared -
// `takesUserId("u-1")` stays refused.
//
// The brand is erased at comptime. Below the checker a `UserId` is a `string`,
// which is what `typeof` reports in the response.

nominal UserId = string;
nominal OrderRef = string;
nominal Port = number;

function describeUser(id: UserId): string {
  return ["user:", id].join("");
}

function describeOrder(ref: OrderRef): string {
  return ["order:", ref].join("");
}

function describePort(p: Port): string {
  return ["port:", String(p)].join("");
}

structural Branded<T> = Proof<T,
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
  const id: UserId = "u-1";
  const ref: OrderRef = "o-9";
  const port: Port = 8080;

  return Response.json({
    user: describeUser(id),
    order: describeOrder(ref),
    port: describePort(port),
    erased: typeof id === "string",
  });
}
