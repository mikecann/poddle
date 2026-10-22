import { decodeJwt, decodeProtectedHeader, exportPKCS8, generateKeyPair } from "jose";
import { describe, expect, test } from "vitest";
import { appleClientSecret, revokeRequest } from "../convex/appleRevoke";

// The hook for revoking Sign in with Apple tokens on account deletion (convex/appleRevoke.ts).

describe("Apple token revocation", () => {
  test("posts the token, its type and a signed client secret to Apple's revoke endpoint", () => {
    const { url, init } = revokeRequest({ clientId: "com.mikecann.poddle.web", clientSecret: "jwt", token: "r.123", hint: "refresh_token" });
    expect(url).toBe("https://appleid.apple.com/auth/revoke");
    expect(init.method).toBe("POST");
    expect(Object.fromEntries(new URLSearchParams(init.body))).toEqual({
      client_id: "com.mikecann.poddle.web",
      client_secret: "jwt",
      token: "r.123",
      token_type_hint: "refresh_token",
    });
  });

  test("the client secret is an ES256 JWT from the team, for the client, addressed to Apple", async () => {
    // A throwaway key, never a real one.
    const { privateKey } = await generateKeyPair("ES256", { extractable: true });
    const pem = await exportPKCS8(privateKey);
    for (const form of [pem, pem.replace(/\n/g, "\\n"), pem.split("\n").filter((l) => !l.startsWith("-----")).join("")]) {
      const jwt = await appleClientSecret({ privateKey: form, teamId: "TEAM123456", keyId: "KEY1234567", clientId: "com.example.web" });
      expect(decodeProtectedHeader(jwt)).toMatchObject({ alg: "ES256", kid: "KEY1234567" });
      expect(decodeJwt(jwt)).toMatchObject({ iss: "TEAM123456", sub: "com.example.web", aud: "https://appleid.apple.com" });
    }
  });
});
