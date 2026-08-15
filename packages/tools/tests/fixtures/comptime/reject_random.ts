
function handler(req: Request): Proof<Response, "state_isolated"> {
    const nonce = comptime(Math.random());
    return Response.json({ nonce: nonce });
}
