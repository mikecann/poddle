import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";

// Execute the workflow's actual script with a fake GitHub client. No network,
// issues, report commits or secrets are needed to check the issue lifecycle.
const yaml = readFileSync(".github/workflows/e2e-nightly-report.yml", "utf8");
const script = yaml.split("          script: |\n")[1]!.split("\n").map(line => line.slice(12)).join("\n");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
async function reportRun(status: "passed" | "failed", openIssues: { number: number }[]) {
  const calls = { getLabel: vi.fn().mockResolvedValue({}), createLabel: vi.fn(), createComment: vi.fn(), update: vi.fn(), create: vi.fn(), listForRepo: vi.fn() };
  const github = { rest: { issues: calls }, paginate: vi.fn().mockResolvedValue(openIssues) };
  const report = { sha: "a".repeat(40), status, finishedAt: "2026-10-22T03:00:00Z",
    scenarios: [{ suite: "ios", name: "Undo archive", status: "failed" }], screenshots: ["screenshots/undo.png"] };
  const require = () => ({ readFileSync: () => JSON.stringify(report) });
  await new AsyncFunction("require", "github", "context", script)(require, github, { repo: { owner: "test", repo: "poddle" }, sha: "b".repeat(40) });
  return calls;
}
describe("nightly issue reporting", () => {
  it("creates a labelled failure with the tested commit and immutable screenshot links", async () => {
    const calls = await reportRun("failed", []);
    expect(calls.create).toHaveBeenCalledWith(expect.objectContaining({ labels: ["e2e-failure"],
      body: expect.stringContaining(`/blob/${"b".repeat(40)}/screenshots/undo.png`) }));
    expect(calls.create.mock.calls[0]![0].body).toContain("Undo archive");
    expect(calls.create.mock.calls[0]![0].body).toContain(`/commit/${"a".repeat(40)}`);
  });
  it("updates the existing failure instead of opening another issue", async () => {
    const calls = await reportRun("failed", [{ number: 42 }]);
    expect(calls.create).not.toHaveBeenCalled();
    expect(calls.update).toHaveBeenCalledWith(expect.objectContaining({ issue_number: 42, title: "Nightly E2E failed (aaaaaaaa)" }));
  });
  it("comments on and closes open failures after a green run", async () => {
    const calls = await reportRun("passed", [{ number: 42 }]);
    expect(calls.create).not.toHaveBeenCalled();
    expect(calls.createComment).toHaveBeenCalledWith(expect.objectContaining({ issue_number: 42, body: expect.stringContaining("Nightly E2E passed") }));
    expect(calls.update).toHaveBeenCalledWith(expect.objectContaining({ issue_number: 42, state: "closed" }));
  });
});
