import { expect, test } from "bun:test";
import type { Node } from "yuku";
import { parse } from "yuku-tsrx";

const parseTsrx = (source: string) => parse(source, { path: "App.tsrx", semanticErrors: true });

const firstError = (source: string) => {
  const error = parseTsrx(source).diagnostics.find((d) => d.severity === "error");
  return error === undefined ? null : (/^TSRX\d{4}/.exec(error.message)?.[0] ?? error.message);
};

const render = (source: string) => {
  const statement = parseTsrx(source).program.body[0] as Node & { body: { render: Node } };
  return statement.body.render;
};

const semicolonBefore = (token: string) =>
  `Expected a semicolon or an implicit semicolon after a statement, but found '${token}'`;

test.each([
  ["<a /> foo;", null],
  ["<a />(1);", null],
  ["(<a />).x;", null],
  ["const v = <a />.x;", semicolonBefore(".")],
  ["function f() { @{ <a /> } <b /> }", semicolonBefore("<")],
  ["function A() @{ @switch (x) { @case 1: { const z = 1; <a /> } } }", null],
  ["function A() @{ @switch (x) { @case 1: { <a /> <b /> } } }", "TSRX2011"],
  ["function A() @{ @switch (x) { @case 1: { if (y) break; <a /> } } }", null],
  ["function A() @{ @switch (x) { @case 1: { break; } } }", "TSRX2008"],
  ["function A() @{ @switch (x) { @case 1: { continue; } } }", "Illegal continue statement"],
  [
    "function A() @{ @switch (x) { @default: { <a /> } @default: { <b /> } } }",
    "A switch statement can only have one default clause",
  ],
  ["function A() @{ @for (const a of b; index i key k) { <a /> } }", null],
  ["function A() @{ @for (const a of b; index i;) { <a /> } }", null],
  ["function A() @{ @for (const a of b; key a, b) { <a /> } }", null],
  ["function A() @{ @for ({ a = 1 } of b) { <a /> } }", null],
  ["function A() @{ @for (const a of b; index [i]) { <a /> } }", "TSRX1011"],
  ["function A() @{ @for (const a of b; key k index i) { <a /> } }", "TSRX1011"],
  [
    "function A() @{ @for await (const a of b) { <a /> } }",
    "'for await' is only valid in async functions or modules",
  ],
  ["async function A() @{ @for await (const a of b) { <a /> } }", null],
  ["function A() @{ ; const a = 1;; <a />;; }", null],
  ["function A() @{ <div>@if (x) { <b /> } else (y)</div> }", null],
  ["function A() { @{ const v = @if (x) { return 1; <a /> }; <b /> } }", "TSRX2001"],
  ["function A() @{ @try { <div>@if (x) { return; }</div> } @catch { <b /> } }", "TSRX2001"],
  [
    "function A() @{ @try { <a /> } @catch (e, { r }) { <b /> } }",
    "The reset parameter of `@catch` names one identifier",
  ],
  ["function A() @{ @try { <a /> } }", "TSRX1010"],
  ["const a = <div><b>text</b>;", "TSRX1001"],
  ["function A() @{ <div> }", "TSRX1001"],
  ["function A() @{ <div><style>.a {}", "TSRX1001"],
  ["const a = <div><span>x</div>;", "TSRX1002"],
  ["const a = <div></span>;", "TSRX1002"],
  ["function A() @{ <div>a /* b</div> }", "TSRX1001"],
  ["function A() @{ <script>a</SCRIPT></script> }", "TSRX1004"],
  ["const a = <svg:rect />;", "TSRX1005"],
  ["const a = <a b={...c} />;", "TSRX1006"],
  ["function A() @{ <div>{a;}</div> }", "TSRX1007"],
  ["const a = <{undefined} />;", "TSRX2014"],
  ["const a = <{...a} />;", "TSRX2014"],
  ["const a = <div>a <é /></div>;", null],
  ["import { x } from type;", null],
])("%s", (source, error) => {
  expect(firstError(source)).toBe(error);
});

test("a tree is complete after the errors TSRX recovers from", () => {
  const { program, diagnostics } = parseTsrx("function A() @{ <a /> <b /> }\nconst z = 1;");
  expect(diagnostics.map((d) => d.message.slice(0, 8))).toEqual(["TSRX2011"]);
  expect(program.body).toMatchObject([
    { body: { body: [{ type: "JSXElement" }], render: { type: "JSXElement" } } },
    { type: "VariableDeclaration" },
  ]);
});

test("an error spans the part that is wrong", () => {
  const spans = (source: string) => parseTsrx(source).diagnostics.map((d) => [d.start, d.end]);
  expect(spans("function A() @{ <a /> const x = 1; }")).toEqual([[22, 34]]);
  expect(spans("const a = <{reg[a + b]} />;")).toEqual([[16, 21]]);
});

test("an `@for` head binds its index, and assigns to a pattern without a declaration", () => {
  expect(render("function A() @{ @for ([a, b] of c; index i) { <a /> } }")).toMatchObject({
    left: { type: "ArrayPattern", elements: [{ name: "a" }, { name: "b" }] },
    index: { type: "Identifier", name: "i" },
    key: null,
  });
  const source = "function A() @{ @for (x of xs; index i) { <li>{x}{i}</li> } }";
  const { references } = parse(source, { path: "App.tsrx", semantic: true });
  expect(references.map((reference) => [reference.name, reference.binding?.name ?? null])).toEqual([
    ["x", null],
    ["xs", null],
    ["x", null],
    ["i", "i"],
  ]);
});

test("a script is one text as written", () => {
  expect(render("function A() @{ <script>if (a < b) {}</script> }")).toMatchObject({
    children: [{ type: "JSXText", raw: "if (a < b) {}" }],
  });
});

test("only a function's own code block has a directive prologue", () => {
  const { program } = parseTsrx(`function A() @{ "use strict"; <div>@{ "x"; <b /> }</div> }`);
  expect(program.body[0]).toMatchObject({
    body: {
      body: [{ directive: "use strict" }],
      render: { children: [{ body: [{ type: "ExpressionStatement", directive: null }] }] },
    },
  });
});

test("a submodule's name is its identifier, escapes decoded", () => {
  expect(parseTsrx("import { x } from s\\u0065rver;").program.body[0]).toMatchObject({
    source: { type: "Identifier", name: "server" },
  });
});
