import type { Nominal } from "zttp:core";
import { nominal } from "zttp:core";
// Proves: an optional boolean used as a condition inside an `export function` body is refused (ZTS100).
type Flag = boolean | undefined;
declare const tagBrand: unique symbol;
type Tag = Nominal<string, typeof tagBrand>;

export function pick(flag: Flag): Proof<Tag, "total" | "pure" | "read_only" | "deterministic"> {
    const tag: Tag = nominal<Tag>("a");
    if (flag) {
        return tag;
    }
    return tag;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: pick(true) });
}
