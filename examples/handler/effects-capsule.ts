// Effects<...> example: author-declared capability ceilings.
//
// `Effects<T, "...">` is the capability dual of `Proof<T, "...">`. On the
// handler's return type it is a budget: the handler's own inferred effect
// row may be no wider than the named capabilities, and the budget also
// bounds every helper the handler reaches. The check is
// `inferred is a subset of declared`.
//
// Where a ceiling goes is a decidable rule, not a style choice: an exported
// function with a nonempty inferred row must declare one (ZTS610), and a
// module-internal function must not (ZTS623). `digest` is module-internal,
// so it carries no ceiling - the compiler infers its row, and the handler's
// budget already bounds it.
//
// This handler is fully discharged. `digest` reaches only `crypto`, and the
// handler's budget covers it. A helper reaching a capability outside the
// budget fails with ZTS607, attributed to that helper; the handler reaching
// one directly fails with ZTS506.

import type { Effects } from "zttp:types";
import { sha256 } from "zttp:crypto";

function digest(s: string): string {
    sha256(s);
    return s;
}

function handler(req: Request): Effects<Response, "crypto"> {
    return Response.text(digest("zttp"));
}
