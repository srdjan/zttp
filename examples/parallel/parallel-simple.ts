import { parallel } from "zttp:io";
import { fetch } from "zttp:fetch";

structural Guardrails<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
>;

function fetchUser(): unknown {
  return fetch("https://users.internal/api/v1/123", {});
}

function fetchOrders(): unknown {
  return fetch("https://orders.internal/api/v1?user=123", {});
}

function fetchInventory(): unknown {
  return fetch("https://inventory.internal/api/v1/789", {});
}

function handler(_req: Request): Guardrails<Response> {
  const results = parallel([
    fetchUser,
    fetchOrders,
    fetchInventory
  ]);
  const user = results[0];
  const orders = results[1];
  const inventory = results[2];

  let userPayload: unknown = undefined;
  if (user.ok) {
    userPayload = user.json();
  }
  let ordersPayload: unknown = { items: [] };
  if (orders.ok) {
    ordersPayload = orders.json();
  }
  let inventoryPayload: unknown = [];
  if (inventory.ok) {
    inventoryPayload = inventory.json();
  }

  return Response.json({
    user: userPayload,
    orders: ordersPayload,
    inventory: inventoryPayload
  });
}
