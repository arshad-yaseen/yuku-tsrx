import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
// @ts-expect-error @tsrx/core types itself with JSDoc in JavaScript
import { parseModule } from "@tsrx/core";
import { parse } from "yuku";
import { walk } from "yuku/ast";

const SUITE = new URL("suite/", import.meta.url);
const { version } = JSON.parse(
  readFileSync(new URL("../node_modules/@tsrx/core/package.json", import.meta.url), "utf8"),
);

const repo = mkdtempSync(join(tmpdir(), "tsrx-"));
try {
  const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, encoding: "utf8" });
  git(
    ...["-c", "advice.detachedHead=false", "clone", "--quiet", "--depth=1", "--filter=blob:none"],
    ...["--sparse", `--branch=@tsrx/core@${version}`, "https://github.com/tsrx-org/tsrx.git", "."],
  );
  git("sparse-checkout", "set", "--no-cone", "/**/*.tsrx", "/packages/tsrx/tests/**/*.test.js");

  const sources = new Set<string>();
  for (const path of git("ls-files").split("\n")) {
    if (path.endsWith(".tsrx")) sources.add(readFileSync(join(repo, path), "utf8"));
    if (!path.startsWith("packages/tsrx/tests/") || !path.endsWith(".test.js")) continue;
    const { program } = parse(readFileSync(join(repo, path), "utf8"), { lang: "js" });
    walk(program, {
      Literal(node) {
        if (typeof node.value === "string") sources.add(node.value);
      },
      TemplateLiteral(node) {
        if (node.expressions.length === 0) sources.add(node.quasis[0]!.value.cooked ?? "");
      },
    });
  }

  rmSync(SUITE, { recursive: true, force: true });
  const counts = { pass: 0, fail: 0 };
  for (const source of sources) {
    const kind = expected(source);
    if (kind === null) continue;
    const name = createHash("sha256").update(source).digest("hex").slice(0, 16);
    mkdirSync(new URL(kind, SUITE), { recursive: true });
    writeFileSync(new URL(`${kind}/${name}.tsrx`, SUITE), source);
    counts[kind]++;
  }
  console.log(`@tsrx/core@${version}: ${counts.pass} pass, ${counts.fail} fail`);
} finally {
  rmSync(repo, { recursive: true, force: true });
}

function expected(source: string): "pass" | "fail" | null {
  try {
    parseModule(source, "App.tsrx");
  } catch (error) {
    return (error as { code?: string }).code?.startsWith("TSRX") ? "fail" : null;
  }
  return /[<@{;=(]/.test(source) ? "pass" : null;
}
