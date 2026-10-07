// Proves: an import from an unknown virtual module is refused at the import check.
import { nothing } from "zttp:no-such-module";

function handler(req: Request): Response {
    return Response.text("ok");
}
