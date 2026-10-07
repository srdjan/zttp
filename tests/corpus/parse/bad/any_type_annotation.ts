// Proves: the `any` type is refused by the stripper in every position (the check currently reports it twice).
function handler(req: Request): Response {
    const x: any = 1;
    return Response.text("ok");
}
