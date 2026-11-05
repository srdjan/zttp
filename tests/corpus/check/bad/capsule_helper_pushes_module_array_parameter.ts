// Proves: a Proof capsule on a helper that pushes onto its parameter, called with a module array, fails ZTS500.
const seen: number[] = [];

function bump(xs: number[]): Proof<number, "pure"> {
    xs.push(1);
    return xs.length;
}

function handler(req: Request): Proof<Response, "result_safe"> {
    return Response.text(String(bump(seen)));
}
