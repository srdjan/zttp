// Proves: an exported function that exposes a raw built-in open type is refused (ZTS061).
export function widen(x: object): object {
    return x;
}

export function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ ok: 1 });
}
