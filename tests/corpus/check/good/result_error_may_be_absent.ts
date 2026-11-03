// Proves: the error field of a Result is absent on success, so ?? on it gives no ZTS103 warning.
import { validateJson } from "zttp:validate";

const describe = (text: string): string => {
    const r = validateJson("user", text);
    const reason = r.error ?? "none";
    return reason;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("1") });
}
