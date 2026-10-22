import { Core } from "yuku";
import wasm from "../../zig-out/bin/yuku-tsrx.wasm";

export const tsrx: Core = new Core({ wasm });
