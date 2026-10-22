import { defineConfig } from "tsdown";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    "core/default": "src/core/default.ts",
    "core/node": "src/core/node.ts",
    "core/workerd": "src/core/workerd.ts",
  },
  platform: "neutral",
  target: "es2020",
  dts: { entry: "src/index.ts" },
  hash: false,
  loader: { ".wasm": "base64" },
  copy: ["zig-out/bin/yuku-tsrx.wasm", { from: "zig-out/native/*.node", to: "dist/native" }],
  // `#core` picks the build at runtime, with the addon in Node.js, Bun, and Deno
  deps: { neverBundle: [/^#/] },
  // bundlers for workerd load an import as WebAssembly only when its path ends in `.wasm`
  outputOptions: { paths: { "#wasm": "../yuku-tsrx.wasm" } },
});
