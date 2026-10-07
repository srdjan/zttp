// Proves: a schemaCompile literal that zttp:validate cannot compile is refused (ZTS514).
import { schemaCompile } from "zttp:validate";

function handler(req: Request): Proof<Response, "deterministic"> {
    const ok = schemaCompile("s", "{\"type\":\"object\",\"allOf\":[]}");
    return Response.json({ ok: ok });
}
