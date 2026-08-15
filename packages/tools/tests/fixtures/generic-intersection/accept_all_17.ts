structural Box<T> = { value: T };

function requireAll(value: Box<string>
  & { p02: string }
  & { p03: string }
  & { p04: string }
  & { p05: string }
  & { p06: string }
  & { p07: string }
  & { p08: string }
  & { p09: string }
  & { p10: string }
  & { p11: string }
  & { p12: string }
  & { p13: string }
  & { p14: string }
  & { p15: string }
  & { p16: string }
  & { required17: string }
): string {
  return value.value;
}

export function handler(req: Request): Proof<Response, "pure"> {
  const result = requireAll({
    value: "ok",
    p02: "ok",
    p03: "ok",
    p04: "ok",
    p05: "ok",
    p06: "ok",
    p07: "ok",
    p08: "ok",
    p09: "ok",
    p10: "ok",
    p11: "ok",
    p12: "ok",
    p13: "ok",
    p14: "ok",
    p15: "ok",
    p16: "ok",
    required17: "ok",
  });
  return Response.text(result);
}
