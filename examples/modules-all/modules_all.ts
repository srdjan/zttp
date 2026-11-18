// Integration example: all virtual modules
// Tests that zttp:auth, zttp:validate, and zttp:cache resolve correctly

import { parseBearer, jwtVerify, jwtSign } from "zttp:auth";
import { env } from "zttp:env";
import { schemaCompile, validateJson, coerceJson } from "zttp:validate";
import { cacheGet, cacheSet, cacheStats } from "zttp:cache";
import { sha256 } from "zttp:crypto";
import { stringifyJson } from "zttp:json";

structural RequestBody = {
    name: string;
    age: number;
};

// Compile a schema on startup
schemaCompile(
  "user",
  '{"type":"object","required":["name","age"],"properties":{"name":{"type":"string","minLength":1,"maxLength":100},"age":{"type":"integer","minimum":0,"maximum":200}}}',
);

function handler(req: Request): Response {
  // Auth: check JWT from Authorization header
  const auth_header = req.headers.authorization;
  if (auth_header !== undefined) {
    const token = parseBearer(auth_header);
    if (token !== undefined) {
      const secret = env("JWT_SECRET");
      if (secret === undefined) {
        return Response.json(
          { error: "server misconfigured" },
          { status: 500 },
        );
      }

      const result = jwtVerify(token, secret);
      if (result.ok) {
        // Cache the verified user
        const cached = stringifyJson(result.value);
        if (cached.ok) {
          const encoded = cached.value;
          if (typeof encoded === "string") {
            cacheSet("users", sha256(token), encoded, 300);
          }
        }
      }
    }
  }

  // Validate request body
  if (req.method === "POST") {
    const validation = validateJson("user", req.body ?? "");
    if (!validation.ok) {
      return Response.json({ errors: validation.errors }, { status: 400 });
    }

    const secret = env("JWT_SECRET");
    if (secret === undefined) {
      return Response.json({ error: "server misconfigured" }, { status: 500 });
    }

    // Sign a response token
    const jwt = jwtSign(
      '{"sub":"user-123","iat":1700000000}',
      secret,
    );

    return Response.json(
      { user: validation.value, token: jwt, cache: cacheStats() },
      { status: 201 },
    );
  }

  return Response.json({ schema: "user", cache: cacheStats() });
}
