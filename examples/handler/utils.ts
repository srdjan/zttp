// Shared utility functions for handler examples

import { stringifyJson } from "zttp:json";

export type GreetingName = string;
export type GreetingText = string;
export type JsonData = { greeting: GreetingText; status: string };
export type JsonText = string;

export function greet(name: GreetingName): GreetingText {
  return ["Hello, ", name, "!"].join("");
}

export function formatJson(data: JsonData): JsonText {
  const text = stringifyJson(data);
  if (text.ok) {
    const encoded = text.value;
    if (typeof encoded === "string") {
      return encoded;
    }
  }
  return "{}";
}
