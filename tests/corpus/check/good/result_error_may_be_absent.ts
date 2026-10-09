// Proves: the error field of a Result is absent on success, so ?? on it gives no ZTS103 warning.
import { parseJson } from "zttp:json";

const describe = (text: string): string => {
    const r = parseJson(text);
    const reason = r.error ?? "none";
    return reason;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("1") });
}
