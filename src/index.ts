import { tsrx } from "#core";
import { parse as parseYuku, type ParseOptions, type SourceFile } from "yuku";

export type * from "./ast";
export { print } from "./print";

/**
 * Parses TSRX into an ESTree program with TSRX's own nodes, and with `semantic`, its scopes,
 * bindings, references, imports, and exports.
 */
export function parse(
  source: string | Uint8Array,
  options: Omit<ParseOptions, "lang" | "core"> = {},
): SourceFile {
  return parseYuku(source, { preserveParens: false, ...options, core: tsrx });
}
