// Proves: a boolean field read through two member accesses of a record parameter is typed boolean.
structural Todo = {
    text: string;
    done: boolean;
};

const progress = (props: { todo: Todo }): number => {
    const done = props.todo.done ? 1 : 0;
    const open = !props.todo.done;
    if (props.todo.done && !open) { return done + 1; }
    return done;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: progress({ todo: { text: "x", done: true } }) });
}
