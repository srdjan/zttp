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

Name a record before putting it in an array. `Array<T>` is refused outright
(ZTS058, write `T[]`), and an inline `{ name: string }[]` currently resolves to
the element rather than the array, so the alias is the spelling that checks.

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
