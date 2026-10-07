// Proves: dynamic computed property access is refused (ZTS605).
import { env } from "zttp:env";

function handler(req: Request): Proof<Response, "deterministic"> {
    const obj = { a: 1 };
    const key = env("KEY") ?? "a";
    const v = obj[key];
    return Response.json({ v: v });
}
