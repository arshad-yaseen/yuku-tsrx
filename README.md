# yuku-tsrx

A fast [TSRX](https://tsrx.dev) parser, analyzer, and code generator, built on [Yuku](https://yuku.fyi).

```bash
npm install yuku-tsrx
```

## Usage

```ts
import { analyze, generate, parse } from "yuku-tsrx";

const source = `export const List = ({ items }) => @{
  @for (const item of items; key item.id) {
    <li>{item.name}</li>
  } @empty {
    <p>Nothing yet</p>
  }
}`;

const { program, diagnostics } = parse(source);

analyze(source).rootScope.find("List");

generate(program).code;
```

It runs in Node.js 14.18 or newer, Bun, Deno, Workers, and browsers.

## Benchmark

Parsing the 61 small TSRX files of the [TSRX repository](https://github.com/tsrx-org/tsrx) in [`bench/fixtures`](bench/fixtures) against the official parser, [`@tsrx/core`](https://www.npmjs.com/package/@tsrx/core), both building an ESTree AST.

![Time per file to parse with yuku-tsrx and @tsrx/core](bench/chart.svg)

Median time per file over 3 runs, each in a fresh Node.js 24 process on an Apple M3. Run it with `bun run bench`.

## Development

Needs [Zig](https://ziglang.org) 0.17 and [Bun](https://bun.sh), with [Yuku](https://github.com/yuku-toolchain/yuku) checked out next to this repository.

```bash
bun install
bun run build      # zig build && tsdown
bun run typecheck
bun run test
```

## License

MIT
