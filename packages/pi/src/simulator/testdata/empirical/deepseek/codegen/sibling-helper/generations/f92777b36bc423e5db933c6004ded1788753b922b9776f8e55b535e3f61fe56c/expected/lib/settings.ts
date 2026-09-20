import { env } from "zttp:env";

export structural ApiToken = string | undefined;
export structural DisplayName = string;

export function apiToken(): ApiToken {
  return env("API_TOKEN");
}

export function displayName(): DisplayName {
  return env("APP_NAME") ?? "unnamed";
}
