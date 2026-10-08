// Proves: an argument outside the `extends` bound of its type parameter is refused (ZTS209).
function idOf<T extends { id: string }>(v: T): string {
    return v.id;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const s = idOf({ name: "no id" });
    return Response.json({ s: s });
}
