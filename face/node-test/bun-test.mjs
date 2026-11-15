// The part of bun:test the Biopass app's tests use, on node:test: describe/test/it, the before/after hooks and
// expect() with the matchers below (and .not). toEqual ignores properties that are undefined, as bun's does.
import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

export { describe, it, it as test, before as beforeAll, after as afterAll, beforeEach, afterEach };

function withoutUndefined(value) {
  if (Array.isArray(value)) return value.map(withoutUndefined);
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, v]) => v !== undefined)
        .map(([k, v]) => [k, withoutUndefined(v)]),
    );
  }
  return value;
}

function passes(fn) {
  try {
    fn();
    return true;
  } catch (e) {
    if (e instanceof assert.AssertionError) return false;
    throw e;
  }
}

const matchers = {
  toBe: (a, b) => assert.ok(Object.is(a, b), `expected ${String(a)} to be ${String(b)}`),
  toEqual: (a, b) => assert.deepStrictEqual(withoutUndefined(a), withoutUndefined(b)),
  toStrictEqual: (a, b) => assert.deepStrictEqual(a, b),
  toBeNull: (a) => assert.equal(a, null),
  toBeUndefined: (a) => assert.equal(a, undefined),
  toBeDefined: (a) => assert.notEqual(a, undefined),
  toBeTruthy: (a) => assert.ok(a),
  toBeFalsy: (a) => assert.ok(!a),
  toContain: (a, b) => assert.ok(a.includes(b), `expected ${String(a)} to contain ${String(b)}`),
  toHaveLength: (a, n) => assert.equal(a.length, n),
  toMatch: (a, re) => assert.match(a, typeof re === "string" ? new RegExp(re) : re),
  toBeGreaterThan: (a, b) => assert.ok(a > b, `expected ${a} > ${b}`),
  toBeGreaterThanOrEqual: (a, b) => assert.ok(a >= b, `expected ${a} >= ${b}`),
  toBeLessThan: (a, b) => assert.ok(a < b, `expected ${a} < ${b}`),
  toBeLessThanOrEqual: (a, b) => assert.ok(a <= b, `expected ${a} <= ${b}`),
  toThrow: (fn, expected) => {
    if (expected === undefined) assert.throws(fn);
    else if (typeof expected === "string")
      assert.throws(fn, (e) => String(e?.message ?? e).includes(expected));
    else assert.throws(fn, expected);
  },
};

export function expect(actual) {
  const make = (negate) =>
    Object.fromEntries(
      Object.entries(matchers).map(([name, check]) => [
        name,
        (...args) => {
          if (!negate) return check(actual, ...args);
          assert.ok(!passes(() => check(actual, ...args)), `expected not ${name}(${args.map(String).join(", ")})`);
        },
      ]),
    );
  const positive = make(false);
  positive.not = make(true);
  positive.resolves = new Proxy({}, {
    get: (_, name) => async (...args) => matchers[name](await actual, ...args),
  });
  positive.rejects = new Proxy({}, {
    get: (_, name) => async (...args) => {
      let error = null;
      try {
        await actual;
      } catch (e) {
        error = e;
      }
      assert.ok(error !== null, "expected a rejection");
      return matchers[name](() => { throw error; }, ...args);
    },
  });
  return positive;
}
