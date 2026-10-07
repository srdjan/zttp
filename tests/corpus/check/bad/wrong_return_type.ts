// Proves: a function that returns a value of another type than its annotation is refused.
function label(): number {
    return "a";
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(label()));
}
