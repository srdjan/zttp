// Proves: a field underscore (present) plus an explicit undefined arm cover an optional field.
structural Opt = { a?: string };

function describe(o: Opt): string {
    return match (o) {
        when { a: undefined }: "absent"
        when { a: _ }: "present"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Opt = { a: "x" };
    return Response.json({ out: describe(value) });
}
