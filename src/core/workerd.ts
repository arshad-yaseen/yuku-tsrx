import { Core } from "yuku";
// workerd can't compile WebAssembly from bytes, so it imports the `.wasm` file as a module
import wasm from "#wasm";

export const tsrx: Core = new Core({ wasm });
