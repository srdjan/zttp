// Proves: a call that names more type arguments than the function declares is refused (ZTS210).
function first<T>(items: T[]): T | undefined {
    return items[0];
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const head = first<string, number>(["a"]);
    return Response.json({ head: head });
}
