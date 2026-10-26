import type {
  BaseNode,
  BindingPattern,
  BlockStatement,
  CatchClause,
  Expression,
  ForStatementLeft,
  Identifier,
  IfStatement,
  JSXClosingElement,
  JSXElement,
  JSXFragment,
  JSXOpeningElement,
  Statement,
  SwitchCase,
} from "yuku";

declare module "yuku" {
  interface DialectNodes {
    JSXCodeBlock: JSXCodeBlock;
    JSXIfExpression: JSXIfExpression;
    JSXForExpression: JSXForExpression;
    JSXSwitchExpression: JSXSwitchExpression;
    JSXTryExpression: JSXTryExpression;
    JSXStyleElement: JSXStyleElement;
    StyleSheet: CSSStyleSheet;
    Rule: CSSRule;
    Atrule: CSSAtrule;
    Block: CSSBlock;
    Declaration: CSSDeclaration;
    SelectorList: CSSSelectorList;
    ComplexSelector: CSSComplexSelector;
    RelativeSelector: CSSRelativeSelector;
    Combinator: CSSCombinator;
    TypeSelector: CSSTypeSelector;
    IdSelector: CSSIdSelector;
    ClassSelector: CSSClassSelector;
    PseudoClassSelector: CSSPseudoClassSelector;
    PseudoElementSelector: CSSPseudoElementSelector;
    AttributeSelector: CSSAttributeSelector;
    NestingSelector: CSSNestingSelector;
    Nth: CSSNth;
    Percentage: CSSPercentage;
  }
}

/** What a template renders. */
export type TemplateOutput =
  | JSXElement
  | JSXFragment
  | JSXStyleElement
  | JSXCodeBlock
  | JSXIfExpression
  | JSXForExpression
  | JSXSwitchExpression
  | JSXTryExpression;

/** `@{ statements output }`, a template with the code that sets it up. */
export interface JSXCodeBlock extends BaseNode {
  type: "JSXCodeBlock";
  body: Statement[];
  render: TemplateOutput | null;
}

/** `@if (test) { } @else { }`, an `@else if` being an `IfStatement`. */
export interface JSXIfExpression extends BaseNode {
  type: "JSXIfExpression";
  statementType: "IfStatement";
  test: Expression;
  consequent: BlockStatement;
  alternate: BlockStatement | IfStatement | null;
}

/** `@for (left of right; index i; key k) { } @empty { }`. */
export interface JSXForExpression extends BaseNode {
  type: "JSXForExpression";
  statementType: "ForOfStatement";
  await: boolean;
  left: ForStatementLeft;
  right: Expression;
  index: Identifier | null;
  key: Expression | null;
  body: BlockStatement;
  empty: BlockStatement | null;
}

/** `@switch (discriminant) { @case test: { } @default: { } }`. */
export interface JSXSwitchExpression extends BaseNode {
  type: "JSXSwitchExpression";
  statementType: "SwitchStatement";
  discriminant: Expression;
  cases: SwitchCase[];
}

/** `@try { } @pending { } @catch (error, reset) { }`. */
export interface JSXTryExpression extends BaseNode {
  type: "JSXTryExpression";
  statementType: "TryStatement";
  block: BlockStatement;
  pending: BlockStatement | null;
  handler: (CatchClause & { resetParam: BindingPattern | null }) | null;
  finalizer: null;
}

/** `<style>`, its CSS kept as written. */
export interface JSXStyleElement extends BaseNode {
  type: "JSXStyleElement";
  openingElement: JSXOpeningElement;
  /** The CSS, or nothing for `<style />`. */
  children: CSSStyleSheet[];
  closingElement: JSXClosingElement | null;
}

/** The CSS of a `<style>`, with its text as written. */
export interface CSSStyleSheet extends BaseNode {
  type: "StyleSheet";
  source: string;
  children: Array<CSSRule | CSSAtrule>;
}

export interface CSSRule extends BaseNode {
  type: "Rule";
  prelude: CSSSelectorList;
  block: CSSBlock;
}

export interface CSSAtrule extends BaseNode {
  type: "Atrule";
  name: string;
  prelude: string;
  block: CSSBlock | null;
}

export interface CSSBlock extends BaseNode {
  type: "Block";
  children: Array<CSSDeclaration | CSSRule | CSSAtrule>;
}

export interface CSSDeclaration extends BaseNode {
  type: "Declaration";
  property: string;
  value: string;
}

export interface CSSSelectorList extends BaseNode {
  type: "SelectorList";
  children: CSSComplexSelector[];
}

export interface CSSComplexSelector extends BaseNode {
  type: "ComplexSelector";
  children: CSSRelativeSelector[];
}

/** Simple selectors after a combinator, or after none at the start. */
export interface CSSRelativeSelector extends BaseNode {
  type: "RelativeSelector";
  combinator: CSSCombinator | null;
  selectors: CSSSimpleSelector[];
}

export type CSSSimpleSelector =
  | CSSTypeSelector
  | CSSIdSelector
  | CSSClassSelector
  | CSSPseudoClassSelector
  | CSSPseudoElementSelector
  | CSSAttributeSelector
  | CSSNestingSelector
  | CSSNth
  | CSSPercentage;

interface CSSNamed<Type extends string> extends BaseNode {
  type: Type;
  name: string;
}

/** `+`, `~`, `>`, `||`, or `" "` for whitespace. */
export type CSSCombinator = CSSNamed<"Combinator">;
export type CSSTypeSelector = CSSNamed<"TypeSelector">;
export type CSSIdSelector = CSSNamed<"IdSelector">;
export type CSSClassSelector = CSSNamed<"ClassSelector">;
export type CSSNestingSelector = CSSNamed<"NestingSelector">;

export interface CSSPseudoClassSelector extends CSSNamed<"PseudoClassSelector"> {
  args: CSSSelectorList | null;
}

export interface CSSPseudoElementSelector extends CSSNamed<"PseudoElementSelector"> {
  args: CSSSelectorList | null;
}

export interface CSSAttributeSelector extends CSSNamed<"AttributeSelector"> {
  matcher: string | null;
  value: string | null;
  flags: string | null;
}

/** An `An+B` argument, such as `2n+1` or `odd`. */
export interface CSSNth extends BaseNode {
  type: "Nth";
  value: string;
}

export interface CSSPercentage extends BaseNode {
  type: "Percentage";
  value: string;
}
