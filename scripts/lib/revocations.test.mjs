// Tests for when `make revocations` reads the test environment's database.
//
// The test Worker signs with the production key, so that a test purchase
// proves the shipped app accepts it. That makes every key it mints a real one,
// and the generator revokes all of them, but only once the database exists,
// which is when wrangler.jsonc gains its id. Before that there is nothing to
// read, and reading anyway would fail every run.
//
// So every assertion runs against the wrangler.jsonc the Worker deploys from.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { testDatabaseConfigured } from "./revocations.mjs";

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const wrangler = readFileSync(join(root, "apps/api/wrangler.jsonc"), "utf8");

describe("testDatabaseConfigured", () => {
  it("is false for the committed config, whose test database has no id yet", () => {
    assert.equal(testDatabaseConfigured(wrangler), false);
  });

  it("is true once the test database's binding carries an id", () => {
    const configured = wrangler.replace(
      /("database_name":\s*"armada-licenses-test",)/,
      '$1\n          "database_id": "00000000-0000-0000-0000-000000000000",',
    );
    assert.notEqual(configured, wrangler);
    assert.equal(testDatabaseConfigured(configured), true);
  });

  it("is not fooled by the production database's id", () => {
    assert.match(wrangler, /"database_id"\s*:\s*"[^"]+"/);
    assert.equal(testDatabaseConfigured(wrangler), false);
  });

  it("is not fooled by an empty id", () => {
    const blank = wrangler.replace(
      /("database_name":\s*"armada-licenses-test",)/,
      '$1\n          "database_id": "",',
    );
    assert.equal(testDatabaseConfigured(blank), false);
  });
});
