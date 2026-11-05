// Proves: a closure that module initialization made and a request calls writes state that outlives the request (ZTS310).
function makeCounter(): () => number {
    let n: number = 0;
    const inc = (): number => {
        n = n + 1;
        return n;
    };
    return inc;
}

const counter: () => number = makeCounter();

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(counter()));
}
