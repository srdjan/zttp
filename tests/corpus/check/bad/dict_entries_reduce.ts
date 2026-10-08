// Proves: a reduce over dictEntries is reported as dictFold (ZTS628).
// The golden also pins ZTS500: this source does not discharge "deterministic" either.
import { dictEntries, dictFromEntries } from "zttp:collections";

function handler(req: Request): Proof<Response, "deterministic"> {
    const built = dictFromEntries([["a", 1], ["b", 2]]);
    if (!built.ok) { return Response.json({ error: "bad" }, { status: 400 }); }
    const d = built.value;
    if (!isDict(d)) { return Response.json({ error: "not-a-dict" }, { status: 400 }); }
    const total = dictEntries(d).reduce((acc, p) => acc + p[1], 0);
    return Response.json({ total: total });
}
