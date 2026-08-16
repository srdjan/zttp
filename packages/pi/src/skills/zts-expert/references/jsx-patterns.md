# JSX / TSX Patterns

JSX enters through the `.tsx` frontend. SSR only - no client hydration. `.jsx` source files are refused.

## Component Structure

```tsx
function Page(props: { title: string, children: JSX.Element }): JSX.Element {
    return (
        <html>
            <head><title>{props.title}</title></head>
            <body>{props.children}</body>
        </html>
    );
}

function handler(req: Request): Response {
    const html = renderToString(
        <Page title="Home">
            <h1>Hello from zttp</h1>
            <p>Method: {req.method}</p>
        </Page>
    );
    return Response.html(html);
}
```

## Built-in Runtime

- `h(tag, props, ...children)` - element creation (called by JSX transform)
- `renderToString(node)` - renders JSX tree to HTML string
- `Fragment` - groups children without a wrapper element

## Rules

- Props are plain objects. No classes, no hooks, no state.
- Components are pure functions from props to JSX.Element.
- Use `renderToString` to convert to HTML, then return via `Response.html`.
- Conditional rendering: use ternary or `&&` in JSX expressions.
- List rendering: use `Array.map` inside JSX.

`Array<T>` is refused (ZTS058); write `T[]`. Naming the record first is the
clearer spelling once a component takes more than one prop, and an inline
`{ name: string }[]` is admitted too.

```tsx
structural User = { name: string };

function UserList(props: { users: User[] }): JSX.Element {
    return (
        <ul>
            {props.users.map((u: User) => <li>{u.name}</li>)}
        </ul>
    );
}
```
