// Proves: a for-of body that mutates the collection it iterates is refused (ZTS622).
function handler(req: Request): Proof<Response, "deterministic"> {
    const items = [1, 2];
    for (const item of items) {
        items.push(item);
    }
    return Response.json({ items: items });
}
