// Proves: a mutating array method on a readonly array is refused (ZTS215).
function addOne(items: readonly number[]): number {
    items.push(1);
    return items.length;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(addOne([1])));
}
