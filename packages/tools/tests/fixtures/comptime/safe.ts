
function handler(req: Request): Proof<Response, "state_isolated"> {
    const status = comptime("ok");
    return Response.json({ status: status });
}
