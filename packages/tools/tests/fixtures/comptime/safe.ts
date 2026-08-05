import type { Spec } from "zttp:types";

function handler(req: Request): Response & Spec<"state_isolated"> {
    const status = comptime("ok");
    return Response.json({ status });
}
