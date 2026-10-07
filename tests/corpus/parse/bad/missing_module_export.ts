// Proves: an import of a name the virtual module does not export is refused at the import check.
import { noSuchExport } from "zttp:env";

function handler(req: Request): Response {
    return Response.text("ok");
}
