const mb = @import("module_binding.zig");

const helpers =
    \\  const nominalKey: unique symbol;
    \\  const matcherKey: unique symbol;
    \\  const patternKey: unique symbol;
    \\
    \\  type Scalar = string | number | boolean;
    \\
    \\  type BaseOf<T> = T extends {
    \\      readonly [nominalKey]: { readonly base: infer Base extends Scalar };
    \\  } ? Base : never;
    \\
    \\  type Literal = string | number | boolean | null | undefined;
    \\  type TypeName = "boolean" | "number" | "string" | "array" | "Dict" | "Bytes";
    \\  type PatternName = TypeName | "any" | "present";
    \\  type Descriptor<Name extends PatternName> = { readonly [patternKey]: Name };
    \\  type AnyPattern = Descriptor<"any">;
    \\  type PresentPattern = Descriptor<"present">;
    \\
    \\  type TypePattern =
    \\      | Descriptor<"boolean">
    \\      | Descriptor<"number">
    \\      | Descriptor<"string">
    \\      | Descriptor<"array">
    \\      | Descriptor<"Dict">
    \\      | Descriptor<"Bytes">;
    \\
    \\  type ArrayValue = readonly unknown[];
    \\  type UnknownFields = { readonly [key: string]: unknown };
    \\
    \\  type UnknownArrayItemPattern =
    \\      | AnyPattern
    \\      | Literal
    \\      | UnknownArrayPattern
    \\      | UnknownRecordPattern;
    \\
    \\  type UnknownArrayPattern = readonly UnknownArrayItemPattern[];
    \\
    \\  type UnknownRecordFieldPattern =
    \\      | PresentPattern
    \\      | Literal
    \\      | UnknownArrayPattern
    \\      | UnknownRecordPattern;
    \\
    \\  type UnknownRecordPattern = {
    \\      readonly [key: string]: UnknownRecordFieldPattern;
    \\      readonly [patternKey]?: never;
    \\  };
    \\
    \\  type UnknownPattern = Literal | UnknownArrayPattern | UnknownRecordPattern | TypePattern;
    \\
    \\  type DescriptorValue<Name extends TypeName> =
    \\      Name extends "boolean" ? boolean
    \\          : Name extends "number" ? number
    \\          : Name extends "string" ? string
    \\          : Name extends "array" ? readonly unknown[]
    \\          : Name extends "Dict" ? Dict<unknown, unknown>
    \\          : Name extends "Bytes" ? Bytes
    \\          : never;
    \\
    \\  type PossibleIntersection<Value, Candidate> = Value extends unknown
    \\      ? Value extends Candidate
    \\          ? Value
    \\          : Candidate extends Value
    \\              ? Candidate
    \\              : never
    \\      : never;
    \\
    \\  type PropertyValue<Value, Key extends PropertyKey> = Key extends keyof Value
    \\      ? Value[Key]
    \\      : never;
    \\
    \\  type HasNeverField<Value extends object> = {
    \\      [Key in keyof Value]-?: [Value[Key]] extends [never] ? Key : never;
    \\  }[keyof Value] extends never ? false : true;
    \\
    \\  type TupleKey<Value extends ArrayValue> = Exclude<keyof Value, keyof readonly unknown[]>;
    \\
    \\  type ArrayElementAt<Value extends ArrayValue, Index extends PropertyKey> =
    \\      Index extends keyof Value ? Value[Index] : Value[number];
    \\
    \\  type HasNeverArrayElement<Value extends ArrayValue, Pattern extends ArrayValue> = {
    \\      [Index in TupleKey<Pattern>]: [Narrow<ArrayElementAt<Value, Index>, Pattern[Index]>] extends [never]
    \\          ? Index
    \\          : never;
    \\  }[TupleKey<Pattern>] extends never ? false : true;
    \\
    \\  type NarrowFixedArray<Value extends ArrayValue, Pattern extends ArrayValue> =
    \\      HasNeverArrayElement<Value, Pattern> extends true
    \\          ? never
    \\          : Value & {
    \\              readonly [Index in keyof Pattern]: Index extends TupleKey<Pattern>
    \\                  ? Narrow<ArrayElementAt<Value, Index>, Pattern[Index]>
    \\                  : Pattern[Index];
    \\          };
    \\
    \\  type NarrowArray<Value extends ArrayValue, Pattern extends ArrayValue> =
    \\      number extends Pattern["length"]
    \\          ? Value
    \\          : number extends Value["length"]
    \\              ? NarrowFixedArray<Value, Pattern>
    \\              : Value["length"] extends Pattern["length"]
    \\                  ? Pattern["length"] extends Value["length"]
    \\                      ? NarrowFixedArray<Value, Pattern>
    \\                      : never
    \\                  : never;
    \\
    \\  type NarrowRecord<Value extends object, Pattern extends object> = {
    \\      readonly [Key in keyof Pattern]-?: Narrow<PropertyValue<Value, Key>, Pattern[Key]>;
    \\  } extends infer Fields extends object
    \\      ? HasNeverField<Fields> extends true
    \\          ? never
    \\          : Value & Fields & UnknownFields
    \\      : never;
    \\
    \\  type NarrowUnknownArray<Pattern extends ArrayValue> = {
    \\      readonly [Index in keyof Pattern]: Index extends TupleKey<Pattern>
    \\          ? NarrowUnknown<Pattern[Index]>
    \\          : Pattern[Index];
    \\  };
    \\
    \\  type NarrowUnknownRecord<Pattern extends object> = UnknownFields & {
    \\      readonly [Key in keyof Pattern]-?: NarrowUnknown<Pattern[Key]>;
    \\  };
    \\
    \\  type NarrowUnknown<Pattern> = Pattern extends PresentPattern
    \\      ? unknown
    \\      : Pattern extends AnyPattern
    \\          ? unknown
    \\          : Pattern extends ArrayValue
    \\              ? NarrowUnknownArray<Pattern>
    \\              : Pattern extends object
    \\                  ? NarrowUnknownRecord<Pattern>
    \\                  : Pattern extends Literal
    \\                      ? Pattern
    \\                      : never;
    \\
    \\  type NarrowOne<Value, Pattern> = Pattern extends Descriptor<infer Name extends TypeName>
    \\      ? PossibleIntersection<Value, DescriptorValue<Name>>
    \\      : Pattern extends PresentPattern
    \\          ? Exclude<Value, undefined>
    \\          : Pattern extends AnyPattern
    \\              ? Value
    \\              : Pattern extends ArrayValue
    \\                  ? Value extends ArrayValue
    \\                      ? NarrowArray<Value, Pattern>
    \\                      : unknown extends Value
    \\                          ? NarrowUnknownArray<Pattern>
    \\                          : never
    \\                  : Pattern extends object
    \\                      ? Value extends object
    \\                          ? NarrowRecord<Value, Pattern>
    \\                          : unknown extends Value
    \\                              ? NarrowUnknownRecord<Pattern>
    \\                              : never
    \\                      : Pattern extends Literal
    \\                          ? Pattern extends Value ? Pattern : never
    \\                          : never;
    \\
    \\  type Narrow<Value, Pattern> = Value extends unknown ? NarrowOne<Value, Pattern> : never;
    \\
    \\  type SubtractRecordField<
    \\      Value extends object,
    \\      Pattern extends object,
    \\      Key extends keyof Pattern,
    \\  > = Subtract<PropertyValue<Value, Key>, Pattern[Key]> extends infer Rest
    \\      ? [Rest] extends [never]
    \\          ? never
    \\          : Value & { readonly [Field in Key]-?: Rest }
    \\      : never;
    \\
    \\  type SubtractRecord<Value extends object, Pattern extends object> = {
    \\      [Key in keyof Pattern]: SubtractRecordField<Value, Pattern, Key>;
    \\  }[keyof Pattern];
    \\
    \\  type SubtractArrayElement<
    \\      Value extends ArrayValue,
    \\      Pattern extends ArrayValue,
    \\      Index extends TupleKey<Pattern>,
    \\  > = Subtract<ArrayElementAt<Value, Index>, Pattern[Index]> extends infer Rest
    \\      ? [Rest] extends [never]
    \\          ? never
    \\          : Value & { readonly [Element in Index]-?: Rest }
    \\      : never;
    \\
    \\  type SubtractArray<Value extends ArrayValue, Pattern extends ArrayValue> =
    \\      number extends Pattern["length"]
    \\          ? Value
    \\          : number extends Value["length"]
    \\              ? Value
    \\              : Value["length"] extends Pattern["length"]
    \\                  ? Pattern["length"] extends Value["length"]
    \\                      ? {
    \\                          [Index in TupleKey<Pattern>]: SubtractArrayElement<Value, Pattern, Index>;
    \\                      }[TupleKey<Pattern>]
    \\                      : Value
    \\                  : Value;
    \\
    \\  type SubtractOne<Value, Pattern> = [NarrowOne<Value, Pattern>] extends [never]
    \\      ? Value
    \\      : Pattern extends Descriptor<infer Name extends TypeName>
    \\          ? Exclude<Value, DescriptorValue<Name>>
    \\          : Pattern extends PresentPattern
    \\              ? Extract<Value, undefined>
    \\              : Pattern extends AnyPattern
    \\                  ? never
    \\                  : Pattern extends ArrayValue
    \\                      ? Value extends ArrayValue
    \\                          ? SubtractArray<Value, Pattern>
    \\                          : Value
    \\                      : Pattern extends object
    \\                          ? Value extends object
    \\                              ? SubtractRecord<Value, Pattern>
    \\                              : Value
    \\                          : Pattern extends Literal
    \\                              ? Exclude<Value, Pattern>
    \\                              : Value;
    \\
    \\  type Subtract<Value, Pattern> = Value extends unknown ? SubtractOne<Value, Pattern> : never;
    \\
    \\  type Matchable<Value, Pattern> = [Narrow<Value, Pattern>] extends [never] ? never : unknown;
    \\
    \\  interface Matcher<Remaining, Output> {
    \\      readonly [matcherKey]: Remaining;
    \\
    \\      with<const Pattern extends UnknownPattern, Next>(
    \\          pattern: Pattern & Matchable<Remaining, Pattern>,
    \\          callback: (value: Narrow<Remaining, Pattern>) => Next,
    \\      ): Matcher<Subtract<Remaining, Pattern>, Output | Next>;
    \\
    \\      exhaustive(this: Matcher<never, Output>): Output;
    \\
    \\      otherwise<Next>(
    \\          this: [Remaining] extends [never] ? never : Matcher<Remaining, Output>,
    \\          callback: (value: Remaining) => Next,
    \\      ): Output | Next;
    \\  }
    \\
;

pub const binding = mb.ModuleBinding{
    .specifier = "zttp:core",
    .name = "core",
    .exports = &.{},
    .type_exports = &.{"Nominal"},
    .type_declarations = &.{.{
        .name = "Nominal",
        .typescript =
        \\  type Nominal<Base extends Scalar, Identity extends symbol> = Base & {
        \\      readonly [nominalKey]: {
        \\          readonly base: Base;
        \\          readonly identity: Identity;
        \\      };
        \\  };
        \\
        ,
    }},
    .intrinsic_exports = &.{
        .{ .name = "nominal", .kind = .nominal, .typescript = "  function nominal<T extends Nominal<Scalar, symbol>>(base: BaseOf<T>): T;\n" },
        .{ .name = "match", .kind = .match, .typescript = "  function match<Value>(subject: Value): Matcher<Value, never>;\n" },
        .{ .name = "assert", .kind = .assert, .typescript = "  function assert(condition: boolean): asserts condition;\n" },
        .{ .name = "P", .kind = .pattern_namespace, .typescript =
        \\  const P: {
        \\      readonly any: AnyPattern;
        \\      readonly present: PresentPattern;
        \\      readonly boolean: Descriptor<"boolean">;
        \\      readonly number: Descriptor<"number">;
        \\      readonly string: Descriptor<"string">;
        \\      readonly array: Descriptor<"array">;
        \\      readonly Dict: Descriptor<"Dict">;
        \\      readonly Bytes: Descriptor<"Bytes">;
        \\  };
        \\
        },
    },
    .typescript_helpers = helpers,
};
