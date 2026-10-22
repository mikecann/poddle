import { ConvexError } from "convex/values";
import { describe, expect, test } from "vitest";
import { isSignedOutError } from "./sessionErrors";

describe("isSignedOutError", () => {
  test("the server's unauthenticated error, either way the client hands it over", () => {
    expect(isSignedOutError(new ConvexError({ code: "unauthenticated", message: "Sign in first" }))).toBe(true);
    expect(
      isSignedOutError(new Error('[CONVEX Q(queue:upNext)] Server Error\nUncaught ConvexError: {"code":"unauthenticated","message":"Sign in first"}')),
    ).toBe(true);
  });

  test("anything else isn't", () => {
    expect(isSignedOutError(new ConvexError({ code: "inviteOnly", message: "x" }))).toBe(false);
    expect(isSignedOutError(new Error("Network down"))).toBe(false);
    expect(isSignedOutError(null)).toBe(false);
  });
});
