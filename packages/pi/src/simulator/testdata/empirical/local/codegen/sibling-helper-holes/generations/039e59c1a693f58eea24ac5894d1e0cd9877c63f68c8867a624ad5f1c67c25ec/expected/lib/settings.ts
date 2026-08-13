import { env } from "zttp:env";

export function apiToken(): string | undefined {
  return env("API_TOKEN");
}

export function displayName(): string {
  return env("APP_NAME") ?? "unnamed";
}
