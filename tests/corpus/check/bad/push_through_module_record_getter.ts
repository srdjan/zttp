// Proves: a push onto an array that a getter returns from a module record is a shared-state write (ZTS310).
structural Store = { items: number[] };
const store: Store = { items: [] };

function getStore(): Store {
    return store;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    getStore().items.push(1);
    return Response.text(String(store.items.length));
}
