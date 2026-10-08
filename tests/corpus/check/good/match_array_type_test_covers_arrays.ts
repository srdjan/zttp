// Proves: the array type test covers every array, so an exact-length arm followed by it is exhaustive.
function describe(xs: number[]): string {
    return match (xs) {
        when []: "empty"
        when array: "some"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe([1, 2]) });
}
