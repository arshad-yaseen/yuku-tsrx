import { Core } from "yuku";
import wasm from "../../zig-out/bin/yuku-tsrx.wasm";

export const tsrx: Core = new Core({
  wasm,
  addons: {
    "darwin-arm64": () => new URL("../native/darwin-arm64.node", import.meta.url),
    "darwin-x64": () => new URL("../native/darwin-x64.node", import.meta.url),
    "linux-arm64": () => new URL("../native/linux-arm64.node", import.meta.url),
    "linux-x64": () => new URL("../native/linux-x64.node", import.meta.url),
    "win32-arm64": () => new URL("../native/win32-arm64.node", import.meta.url),
    "win32-x64": () => new URL("../native/win32-x64.node", import.meta.url),
  },
});
