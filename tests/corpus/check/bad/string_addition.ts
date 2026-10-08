// Proves: `+` joining a number and a string is refused, because string addition is not supported (ZTS105).
function handler(req: Request): Proof<Response, "deterministic"> {
    const joined = 1 + "a";
    return Response.text(joined);
}
