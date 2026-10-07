// Proves: a .tsx handler is lowered by the TSX frontend and passes every stage with a narrow capsule.
structural GreetingProps = {
    message: string;
};

function Greeting(props: GreetingProps): JSX.Element {
    return <h1>{props.message}</h1>;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const html: string = renderToString(<Greeting message="hello" />);
    return Response.html(html);
}
