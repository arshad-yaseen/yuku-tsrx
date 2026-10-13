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

Parsing the 11 pages of the TSRX website in [`test/fixtures`](test/fixtures) (327 KB) against the official parser, [`@tsrx/core`](https://www.npmjs.com/package/@tsrx/core), both building an ESTree AST with comments attached.

![Parse time of yuku-tsrx and @tsrx/core](bench/chart.svg)

Medians of 3 runs, each in a fresh Node.js 24 process on an Apple M3. Run it with `bun run bench`.

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
