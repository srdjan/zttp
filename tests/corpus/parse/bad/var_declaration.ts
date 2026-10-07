// Proves: a `var` declaration is refused at parse time in favor of `let` or `const`.
function handler(req: Request): Response {
    var label = "ok";
    return Response.text(label);
}
