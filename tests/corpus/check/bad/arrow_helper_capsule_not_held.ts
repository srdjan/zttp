// Proves: an arrow helper bound by const is held to its declared Proof capsule exactly as a function declaration is (ZTS500).
const stamp = (): Proof<number, "pure"> => {
    return Date.now();
};

export function handler(req: Request): Proof<Response, "read_only"> {
    const t = stamp();
    return Response.text(String(t));
}
