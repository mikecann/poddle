import { describe, expect, test } from "vitest";
import { expressionRegex, featureSteps, swiftExpressions } from "../scripts/bdd-drift.mjs";
import { pairingErrors } from "../scripts/verify-bdd-pairing.mjs";

// The BDD checks themselves (docs/testing.md).

describe("BDD checks", () => {
  test("every feature in the checkout is paired with one step module", () => {
    expect(pairingErrors()).toEqual([]);
  });

  test("Cucumber expressions match like the Swift runner's", () => {
    const r = expressionRegex('they choose {float}× speed for {string} (really)');
    expect(r.exec('they choose 1.25× speed for "Morning Tones" (really)')?.slice(1)).toEqual(["1.25", "Morning Tones"]);
    expect(r.test('they choose fast× speed for "x" (really)')).toBe(false);
    expect(expressionRegex("{int} seconds").test("40 seconds")).toBe(true);
  });

  test("feature steps, with outlines expanded", () => {
    const steps = featureSteps(
      ["Feature: F", "  Scenario: A", "    Given one", "    # a comment", "  Scenario Outline: B", "    When <n> things", "    Examples:", "      | n |", "      | 2 |", "      | 3 |"].join("\n"),
      "f.feature",
    );
    expect(steps.map((s) => s.text)).toEqual(["one", "2 things", "3 things"]);
  });

  test("step expressions from Swift", () => {
    const src = 's.given("the listener follows {string}") { w, a in }\n        s.then("it says \\"hi\\"") { w, _ in }';
    expect(swiftExpressions(src, "x.swift").map((d) => d.expression)).toEqual(["the listener follows {string}", 'it says "hi"']);
  });
});
