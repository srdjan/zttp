// Proves: a Proof capsule on a helper that pushes onto a module array fails ZTS500 even when no handler calls it.
const seen: number[] = [];

function bump(): Proof<number, "pure"> {
    seen.push(1);
    return seen.length;
}

function handler(req: Request): Proof<Response, "result_safe"> {
    return Response.text("ok");
}
