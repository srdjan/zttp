// Proves: an arrow function bound by const instead of passed as a call argument is refused (ZTS072).
const double = (x: number): number => x * 2;

function handler(req: Request): Response {
    return Response.text(String(double(4)));
}
