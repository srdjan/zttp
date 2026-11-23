import { nominal } from "zttp:core";
import type { Nominal } from "zttp:core";
// Proves: declared function bodies that guard an optional before use pass the boolean checks they are now walked by.
type Flag = boolean | undefined;
declare const tagBrand: unique symbol;
type Tag = Nominal<string, typeof tagBrand>;

function label(name: string | undefined, flag: Flag): string {
  if (name !== undefined && name === "x") {
    return "x";
  }
  if (flag !== undefined && flag) {
    return "on";
  }
  return "off";
}

export function pick(
  flag: Flag,
): Proof<Tag, "total" | "pure" | "read_only" | "deterministic"> {
  const tag: Tag = nominal<Tag>("a");
  if (flag !== undefined && flag) {
    return tag;
  }
  return tag;
}

function handler(req: Request): Proof<Response, "deterministic"> {
  return Response.json({ a: label("x", true), b: pick(true) });
}
