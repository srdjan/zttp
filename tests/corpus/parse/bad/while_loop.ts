// Proves: a `while` loop is refused at parse time.
function handler(req: Request): Response {
    let n = 0;
    while (n < 3) {
        n = n + 1;
    }
    return Response.text(String(n));
}
