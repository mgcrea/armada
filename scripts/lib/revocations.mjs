// What `generate-revocations.mjs` reads besides the production database.
//
// Dependency-free, like everything else under scripts/lib.

/**
 * Whether apps/api/wrangler.jsonc gives the test environment's database an id,
 * which is the point at which it exists and has licences to read.
 *
 * The test Worker signs with the production key, so a test purchase proves
 * the shipped app accepts it, and every key it mints is a real one. The
 * generator revokes all of them, so none outlives the next build. Read from
 * the raw text rather than parsed: the file is JSONC, and the binding is a
 * flat object with no braces inside it, comments included.
 */
export function testDatabaseConfigured(wrangler) {
  const binding = /\{[^{}]*"database_name"\s*:\s*"armada-licenses-test"[^{}]*\}/.exec(wrangler);
  return binding !== null && /"database_id"\s*:\s*"[^"]+"/.test(binding[0]);
}
