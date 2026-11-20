import { env } from "zttp:env";

export type ApiToken = string | undefined;
export type DisplayName = string;

export function apiToken(): ApiToken {
  return env("API_TOKEN");
}

export function displayName(): DisplayName {
  return env("APP_NAME") ?? "unnamed";
}
