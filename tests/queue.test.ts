import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { setup, TOKEN, type T } from "./helpers";
import { BASE, seedShow } from "./seed";

async function order(t: T, names: Map<string, string>) {
  const q = await t.query(api.queue.upNext, { token: TOKEN });
  return q.map((r) => names.get(r.item.episodeId)!);
}

async function fixture(n = 5) {
  const t = setup();
  const { episodeIds } = await seedShow(t, n);
  const names = new Map(episodeIds.map((id, i) => [id as string, "ABCDEFGHIJ"[i]!]));
  const [A, B, C, D, E] = episodeIds as Id<"episodes">[];
  return { t, names, A: A!, B: B!, C: C!, D: D!, E: E! };
}

const at = (n: number) => BASE + n * 1000;

describe("Up Next", () => {
  test("add top, next and bottom; play now puts the current item second", async () => {
    const { t, names, A, B, C, D } = await fixture();
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: A, position: "bottom", at: at(1) });
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: B, position: "bottom", at: at(2) });
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: C, position: "next", at: at(3) });
    expect(await order(t, names)).toEqual(["A", "C", "B"]);
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: D, position: "top", at: at(4) });
    expect(await order(t, names)).toEqual(["D", "A", "C", "B"]);
    await t.mutation(api.queue.playNow, { token: TOKEN, episodeId: B, at: at(5) });
    expect(await order(t, names)).toEqual(["B", "D", "A", "C"]);
  });

  test("move between neighbours, to the top, and falling back to the before neighbour", async () => {
    const { t, names, A, B, C, D } = await fixture();
    for (const [i, id] of [A, B, C, D].entries()) {
      await t.mutation(api.queue.add, { token: TOKEN, episodeId: id, position: "bottom", at: at(i) });
    }
    await t.mutation(api.queue.move, { token: TOKEN, episodeId: D, afterEpisodeId: A, at: at(10) });
    expect(await order(t, names)).toEqual(["A", "D", "B", "C"]);
    await t.mutation(api.queue.move, { token: TOKEN, episodeId: C, afterEpisodeId: null, at: at(11) });
    expect(await order(t, names)).toEqual(["C", "A", "D", "B"]);
    // The "after" neighbour has gone; fall back to "before B".
    await t.mutation(api.queue.remove, { token: TOKEN, episodeId: A, at: at(12) });
    await t.mutation(api.queue.move, { token: TOKEN, episodeId: C, afterEpisodeId: A, beforeEpisodeId: B, at: at(13) });
    expect(await order(t, names)).toEqual(["D", "C", "B"]);
  });

  test("two devices moving different items after the same neighbour both survive", async () => {
    const { t, names, A, B, C, D, E } = await fixture();
    for (const [i, id] of [A, B, C, D, E].entries()) {
      await t.mutation(api.queue.add, { token: TOKEN, episodeId: id, position: "bottom", at: at(i) });
    }
    // Both computed from the same view [A B C D E]: phone drags E after A, iPad drags D after A.
    await Promise.all([
      t.mutation(api.queue.move, { token: TOKEN, episodeId: E, afterEpisodeId: A, beforeEpisodeId: B, at: at(20) }),
      t.mutation(api.queue.move, { token: TOKEN, episodeId: D, afterEpisodeId: A, beforeEpisodeId: B, at: at(21) }),
    ]);
    const result = await order(t, names);
    expect(result).toHaveLength(5);
    expect(result[0]).toBe("A");
    expect(new Set(result.slice(1, 3))).toEqual(new Set(["D", "E"]));
    expect(result.slice(3)).toEqual(["B", "C"]);
    const keys = (await t.query(api.queue.upNext, { token: TOKEN })).map((r) => r.item.orderKey);
    expect(new Set(keys).size).toBe(5);
    expect([...keys].sort()).toEqual(keys);
  });

  test("a stale replayed move or add loses to a newer change", async () => {
    const { t, names, A, B, C } = await fixture();
    for (const [i, id] of [A, B, C].entries()) {
      await t.mutation(api.queue.add, { token: TOKEN, episodeId: id, position: "bottom", at: at(i) });
    }
    await t.mutation(api.queue.move, { token: TOKEN, episodeId: C, afterEpisodeId: null, at: at(30) });
    // An offline device's older move of C arrives late.
    expect(await t.mutation(api.queue.move, { token: TOKEN, episodeId: C, afterEpisodeId: B, at: at(25) })).toBe(false);
    expect(await order(t, names)).toEqual(["C", "A", "B"]);

    // Removed at 40 elsewhere; an add from 35 replays afterwards and is ignored.
    await t.mutation(api.queue.remove, { token: TOKEN, episodeId: B, at: at(40) });
    expect(await t.mutation(api.queue.add, { token: TOKEN, episodeId: B, position: "bottom", at: at(35) })).toBe(false);
    expect(await order(t, names)).toEqual(["C", "A"]);
    // A genuinely newer add brings it back.
    expect(await t.mutation(api.queue.add, { token: TOKEN, episodeId: B, position: "bottom", at: at(50) })).toBe(true);
    expect(await order(t, names)).toEqual(["C", "A", "B"]);
  });

  test("many interleaved moves keep a consistent total order", async () => {
    const { t, names, A, B, C, D, E } = await fixture();
    const ids = [A, B, C, D, E];
    for (const [i, id] of ids.entries()) await t.mutation(api.queue.add, { token: TOKEN, episodeId: id, position: "bottom", at: at(i) });
    // Model the expected order alongside.
    let model = ["A", "B", "C", "D", "E"];
    const letter = (id: Id<"episodes">) => names.get(id)!;
    let clock = 100;
    for (let round = 0; round < 30; round++) {
      const mover = ids[(round * 3) % 5]!;
      const after = round % 4 === 0 ? null : ids[(round * 7 + 1) % 5]!;
      if (after === mover) continue;
      await t.mutation(api.queue.move, { token: TOKEN, episodeId: mover, afterEpisodeId: after, at: at(clock++) });
      model = model.filter((x) => x !== letter(mover));
      const idx = after === null ? 0 : model.indexOf(letter(after)) + 1;
      model.splice(idx, 0, letter(mover));
    }
    expect(await order(t, names)).toEqual(model);
  });

  test("clear only removes items added before it", async () => {
    const { t, names, A, B, C } = await fixture();
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: A, position: "bottom", at: at(1) });
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: B, position: "bottom", at: at(2) });
    await t.mutation(api.queue.add, { token: TOKEN, episodeId: C, position: "bottom", at: at(10) });
    expect(await t.mutation(api.queue.clear, { token: TOKEN, at: at(5) })).toBe(2);
    expect(await order(t, names)).toEqual(["C"]);
  });
});
