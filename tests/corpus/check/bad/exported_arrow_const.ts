// Proves: an exported function-valued const is refused in favor of an exported function (ZTS609).
export const handler = (req: Request): Proof<Response, "deterministic"> => Response.json({ ok: 9 });
