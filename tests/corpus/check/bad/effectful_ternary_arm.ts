// Proves: a call in a conditional-expression arm is refused, the arm must be a pure value (ZTS612).
function pick(): number {
    return 7;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const ready = true;
    const status = ready ? pick() : 5;
    return Response.json({ status: status });
}
