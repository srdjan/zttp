// Proves: a push through a local alias of a module record that a getter returns is a shared-state write (ZTS310).
structural Store = { items: number[] };
const store: Store = { items: [] };

function getStore(): Store {
    return store;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const s = getStore();
    s.items.push(1);
    return Response.text(String(store.items.length));
}
