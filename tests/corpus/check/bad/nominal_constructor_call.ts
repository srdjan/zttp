import type { Nominal } from "zttp:core";
// Proves: a nominal type name used as a constructor call is refused (ZTS214).
declare const userIdBrand: unique symbol;
type UserId = Nominal<string, typeof userIdBrand>;

function handler(req: Request): Proof<Response, "deterministic"> {
    const id = UserId("u-1");
    return Response.text(id);
}
