// Proves: an anonymous arrow that annotates some of its parameters but not all is refused, because its call sites would check against less than it declares.
const first = (a: number, b): number => a;

function handler(req: Request): Proof<Response, "deterministic"> {
    const n = first(1, 2);
    return Response.text(String(n));
}
