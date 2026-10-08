// Proves: rebuilding a Dict from its entries with only the values changed is reported as dictMapValues (ZTS627).
// The golden also pins ZTS500: this source does not discharge "deterministic" either.
import { dictEntries, dictFromEntries } from "zttp:collections";

function handler(req: Request): Proof<Response, "deterministic"> {
    const built = dictFromEntries([["a", 1], ["b", 2]]);
    if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
    const d = built.value;
    if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
    const doubled = dictFromEntries(dictEntries(d).map((p) => [p[0], p[1] * 2]));
    return Response.json({ ok: doubled.ok });
}
