// Exported boundaries name their domains. Raw built-ins stay available inside
// a module, while public parameters and returns use a declared type, a fixed
// application ABI type, or a closed literal union.

import { nominal } from "zttp:core";
import type { Nominal } from "zttp:core";

declare const userIdBrand: unique symbol;
type UserId = Nominal<string, typeof userIdBrand>;
declare const featureEnabledBrand: unique symbol;
type FeatureEnabled = Nominal<boolean, typeof featureEnabledBrand>;

type PureBoundary<T> = Proof<T,
    | "total"
    | "pure"
    | "read_only"
    | "deterministic"
>;

export function sameUser(id: UserId): PureBoundary<UserId> {
  return id;
}

export function sameEnabled(enabled: FeatureEnabled): PureBoundary<FeatureEnabled> {
  return enabled;
}

export function sameUsers(ids: readonly UserId[]): PureBoundary<readonly UserId[]> {
  return ids;
}

export function sameRequest(req: Request): PureBoundary<Request> {
  return req;
}

export function sameMethod(method: "GET" | "POST"): PureBoundary<"GET" | "POST"> {
  return method;
}

type BoundaryProof<T> = Proof<T,
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

export function handler(req: Request): BoundaryProof<Response> {
  const id: UserId = nominal<UserId>("u-1");
  const enabled: FeatureEnabled = nominal<FeatureEnabled>(true);
  const ids: readonly UserId[] = [id];
  const method: "GET" | "POST" = "GET";
  sameRequest(req);

  return Response.json({
    id: sameUser(id),
    enabled: sameEnabled(enabled),
    count: sameUsers(ids).length,
    method: sameMethod(method),
  });
}
