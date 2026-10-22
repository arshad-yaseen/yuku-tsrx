declare module "#core" {
  export const tsrx: import("yuku").Core;
}

declare module "#wasm" {
  const module: WebAssembly.Module;
  export default module;
}

declare module "*.wasm" {
  const base64: string;
  export default base64;
}
