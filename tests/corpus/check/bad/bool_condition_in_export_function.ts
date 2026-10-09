// Proves: an optional boolean used as a condition inside an `export function` body is refused (ZTS100).
structural Flag = boolean | undefined;
nominal Tag = string;

export function pick(flag: Flag): Proof<Tag, "total" | "pure" | "read_only" | "deterministic"> {
    const tag: Tag = "a";
    if (flag) {
        return tag;
    }
    return tag;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: pick(true) });
}
