import type { Spec } from "zttp:types";

function handler(req: Request): Response & Spec<"state_isolated"> {
    const nonce = comptime(Math.random());
    return Response.json({ nonce });
}
