// Declare each related shape as its own `structural` record. The profile has
// no utility types (`Pick`, `Omit`, `Partial`, `Required`, `Readonly`): write
// each derived shape out.


type Guardrails<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "injection_safe"
    | "no_secret_leakage"
    | "input_validated"
>;

type User = {
    id: number;
    name: string;
    email: string;
    age: number;
};

// A public summary that carries only id and name.
type Summary = { id: number; name: string };

// The same record without the sensitive email.
type Safe = { id: number; name: string; age: number };

// Every field optional, for a patch payload.
type UserPatch = { id?: number; name?: string; email?: string; age?: number };

// A fully-specified config.
type Config = { host: string; port: number };

const summary: Summary = { id: 1, name: "Ada" };
const safe: Safe = { id: 2, name: "Grace", age: 36 };
const patch: UserPatch = { name: "Hedy" };
const config: Config = { host: "0.0.0.0", port: 8080 };

function handler(req: Request): Guardrails<Response> {
  return Response.json({
    summary: summary,
    safe: safe,
    patch: patch,
    config: config,
  });
}
