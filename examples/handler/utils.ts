// Shared utility functions for handler examples

export structural GreetingName = string;
export structural GreetingText = string;
export structural JsonData = object;
export structural JsonText = string;

export function greet(name: GreetingName): GreetingText {
  return ["Hello, ", name, "!"].join("");
}

export function formatJson(data: JsonData): JsonText {
  return JSON.stringify(data);
}
