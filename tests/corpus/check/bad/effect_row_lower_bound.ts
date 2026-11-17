// Proves: a call through a value the compiler cannot resolve makes the effect row a lower bound (ZTS512).
import { sha256 } from "zttp:crypto";

structural Maker = { make: () => string };

function digest(): string {
    return sha256("zttp");
}

function build(): Maker {
    return { make: digest };
}

function handler(req: Request): Proof<Effects<Response, "crypto">, "state_isolated"> {
    const m = build();
    const f = m.make;
    return Response.text(f());
}
