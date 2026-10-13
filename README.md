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
