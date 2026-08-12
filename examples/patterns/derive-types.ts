// Derive related shapes from one source type with the utility-type family:
// Pick, Omit, Partial, Required. zts resolves these structurally - a named
// source type is looked up and transformed - so each field stays declared in
// exactly one place instead of being copied into hand-written aliases that can
// drift.

import type { Spec } from "zttp:types";

structural Guardrails = Spec<
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "injection_safe"
    | "no_secret_leakage"
    | "input_validated"
>;

structural User = {
    id: number;
    name: string;
    email: string;
    age: number;
};

// Pick: a public summary that carries only id and name.
structural Summary = Pick<User, "id" | "name">;

// Omit: the same record without the sensitive email.
structural Safe = Omit<User, "email">;

// Partial: every field optional, for a patch payload.
structural UserPatch = Partial<User>;

// Required: force every optional field present, deriving a fully-specified
// config from a loosely-typed source.
structural RawConfig = { host?: string; port?: number };
structural Config = Required<RawConfig>;

const summary: Summary = { id: 1, name: "Ada" };
const safe: Safe = { id: 2, name: "Grace", age: 36 };
const patch: UserPatch = { name: "Hedy" };
const config: Config = { host: "0.0.0.0", port: 8080 };

function handler(req: Request): Response & Guardrails {
  return Response.json({
    summary: summary,
    safe: safe,
    patch: patch,
    config: config,
  });
}
