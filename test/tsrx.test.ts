// every fixture parses and analyzes cleanly, and prints back to source that reparses to the same
// code. tests the built package, as it ships
import { expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { analyze, generate, parse } from "yuku-tsrx";

const fixtures = new URL("fixtures/", import.meta.url);

test.each(readdirSync(fixtures))("%s", async (name) => {
  const source = await Bun.file(new URL(name, fixtures)).text();
  const { program, diagnostics } = parse(source);
  expect(diagnostics).toEqual([]);
  expect(analyze(source).diagnostics).toEqual([]);

  const { code } = generate(program);
  const reparsed = parse(code);
  expect(reparsed.diagnostics).toEqual([]);
  expect(generate(reparsed.program).code).toBe(code);
});

test("reports TSRX errors", () => {
  const { diagnostics } = parse("@if (ok) <p />");
  expect(diagnostics.map((d) => d.message)).toEqual([
    "TSRX1008: Expected `{` after JSX control-flow directive.",
  ]);
});
