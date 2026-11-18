// Shared utility functions for handler examples

import { stringifyJson } from "zttp:json";

export structural GreetingName = string;
export structural GreetingText = string;
export structural JsonData = { greeting: GreetingText; status: string };
export structural JsonText = string;

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
