// Syntactic sugar demo.
//
// The conveniences the model-minimal profile keeps: arrow callbacks, the array
// higher-order functions, and `Object.keys`. Compound assignment is not one of
// them - `score += 50` is ZTS613, so the update is written in full.

function handler(req: Request): Response {
  const double = (x: number): number => x * 2;

  let score = 100;
  score = score + 50;

  const items = [1, 2, 3, 4, 5];
  const evens = items.filter((n: number) => n % 2 === 0);
  const doubled = evens.map((n: number) => n * 2);
  const total = doubled.reduce((acc: number, n: number) => acc + n, 0);

  const piped = double(score);

  const keys = Object.keys({ a: 1, b: 2 });

  return Response.json({
    score: score,
    evens: evens,
    doubled: doubled,
    total: total,
    piped: piped,
    keys: keys,
  });
}
