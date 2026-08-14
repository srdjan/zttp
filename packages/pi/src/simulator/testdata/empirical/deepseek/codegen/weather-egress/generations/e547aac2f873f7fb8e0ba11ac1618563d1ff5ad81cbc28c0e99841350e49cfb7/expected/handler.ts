import { fetch } from "zttp:fetch";
import { schemaCompile } from "zttp:validate";
import { decodeQuery } from "zttp:decode";
import type { Spec } from "zttp:types";

schemaCompile("cityQuery", JSON.stringify({
    type: "object",
    required: ["city"],
    properties: {
        city: { type: "string", minLength: 1, maxLength: 100 }
    }
}));

function handler(req: Request): Response & Spec<"input_validated" | "injection_safe" | "no_secret_leakage" | "no_credential_leakage"> {
    const parsed = decodeQuery("cityQuery", req.query);
    if (!parsed.ok) {
        return Response.json({ error: "city query parameter is required" }, { status: 400 });
    }
    const city = parsed.value.city;
    const res = fetch("https://api.open-meteo.com/v1/forecast", {
        query: { city: city, current_weather: "true" }
    });
    if (!res.ok) {
        return Response.json({ error: "weather service unavailable" }, { status: 502 });
    }
    return Response.json(res.json());
}
