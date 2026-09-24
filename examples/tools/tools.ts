// Two reference tools (M4 T7). `convert` is pure and bounded. `order_status`
// reads one order for the caller's own tenant from an upstream, with a
// credential the runtime adds and this code never sees. See README.md.

import { toolCatalog, toolInput } from "zttp:tool";
import { routerMatch } from "zttp:router";
import { schemaCompile, validateJson } from "zttp:validate";
import { fetch } from "zttp:fetch";

// An order id is a nominal type: a plain string from anywhere else is not one.
// Only the tool's own validated input brands one, in `orderStatus`.
nominal OrderId = string;

schemaCompile("ConvertInput", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"value\",\"from\",\"to\"],\"properties\":{\"value\":{\"type\":\"number\",\"minimum\":-1000,\"maximum\":10000},\"from\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"C\",\"F\",\"K\"]},\"to\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"C\",\"F\",\"K\"]}}}");
schemaCompile("ConvertOutput", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"value\",\"unit\"],\"properties\":{\"value\":{\"type\":\"number\"},\"unit\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"C\",\"F\",\"K\"]}}}");
schemaCompile("OrderInput", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"tenant_id\",\"order_id\"],\"properties\":{\"tenant_id\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":32},\"order_id\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":16}}}");
schemaCompile("OrderOutput", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"order_id\",\"status\"],\"properties\":{\"order_id\":{\"type\":\"string\",\"maxLength\":16},\"status\":{\"type\":\"string\",\"maxLength\":16,\"enum\":[\"pending\",\"shipped\",\"delivered\"]}}}");
schemaCompile("UpstreamOrder", "{\"type\":\"object\",\"required\":[\"status\"],\"properties\":{\"status\":{\"type\":\"string\",\"maxLength\":64}}}");

toolCatalog({
  convert: {
    route: "POST /tools/convert",
    description: "Convert a temperature between Celsius, Fahrenheit, and Kelvin.",
    input: "ConvertInput",
    output: "ConvertOutput",
    maxInputBytes: 128
  },
  order_status: {
    route: "POST /tools/order_status",
    description: "Report the status of one order that belongs to the caller's tenant.",
    input: "OrderInput",
    output: "OrderOutput",
    maxInputBytes: 128,
    scope: { tenant: "tenant_id" }
  }
});

function toCelsius(value: number, unit: string): number {
  if (unit === "F") {
    return (value - 32) * 5 / 9;
  }
  if (unit === "K") {
    return value - 273.15;
  }
  return value;
}

function fromCelsius(value: number, unit: string): number {
  if (unit === "F") {
    return value * 9 / 5 + 32;
  }
  if (unit === "K") {
    return value + 273.15;
  }
  return value;
}

function convert(req: Request): Response {
  const parsed = toolInput("ConvertInput", req);
  if (!parsed.ok) {
    return Response.json({ error: "invalid input" }, { status: 400 });
  }
  const input = parsed.value;
  const celsius = toCelsius(input.value, input.from);
  return Response.json({ value: fromCelsius(celsius, input.to), unit: input.to });
}

// The one upstream call, with the credential the runtime adds after it has
// checked this exact request against the `orders` reference in zttp.json.
function lookupOrder(tenant: string, id: OrderId): Response {
  const res = fetch("http://127.0.0.1:39460/v1/orders", {
    credential: "orders",
    query: { tenant: tenant, order: id },
    maxResponseBytes: 4096
  });
  if (res.status !== 200) {
    return Response.json({ error: res.statusText }, { status: 502 });
  }
  const order = validateJson("UpstreamOrder", res.body);
  if (!order.ok) {
    return Response.json({ error: "upstream answer is not an order" }, { status: 502 });
  }
  const found = order.value;
  return Response.json({ order_id: id, status: found.status });
}

function orderStatus(req: Request): Response {
  const parsed = toolInput("OrderInput", req);
  if (!parsed.ok) {
    return Response.json({ error: "invalid input" }, { status: 400 });
  }
  const input = parsed.value;
  const id: OrderId = input.order_id;
  return lookupOrder(input.tenant_id, id);
}

const routes = {
  "POST /tools/convert": convert,
  "POST /tools/order_status": orderStatus
};

structural ToolGuarantees<T> = Proof<T,
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "injection_safe"
>;

function handler(req: Request): ToolGuarantees<Response> {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    return found.handler(req);
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
