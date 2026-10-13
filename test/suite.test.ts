import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { parse } from "yuku-tsrx";

for (const kind of ["pass", "fail"]) {
  const dir = new URL(`suite/${kind}/`, import.meta.url);
  test.each(readdirSync(dir))(`${kind}/%s`, (name) => {
    const { diagnostics } = parse(readFileSync(new URL(name, dir), "utf8"), { path: name });
    const errors = diagnostics.filter((d) => d.severity === "error").map((d) => d.message);
    if (kind === "pass") expect(errors).toEqual([]);
    else expect(errors).not.toEqual([]);
  });
}
