// Proves: a static saga whose non-last step has no compensate is reported (ZTS510).
import { saga } from "zttp:workflow";

function handler(req: Request): Proof<Response, "deterministic"> {
    const out = saga([
        { name: "reserve", run: () => 1 },
        { name: "ship", run: () => 3 },
    ]);
    return Response.json({ out: out });
}
