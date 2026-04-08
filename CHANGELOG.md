# Changelog

## 0.1.0

Initial release.

- `Enclave.start_owner/0`, `Enclave.stop_owner/0`, `Enclave.allow/2`,
  `Enclave.owner/1`, `Enclave.deliverable?/2` — the core owner-resolution API.
- `Enclave.Dispatcher` — a `Phoenix.PubSub` dispatcher that filters
  subscribers through `Enclave.deliverable?/2`, letting async tests share a
  single PubSub instance without cross-test message leakage.
- Owner resolution walks explicit registrations, then `$callers`, then
  `$ancestors`, matching the Ecto SQL sandbox's ownership model.
- Cleanup is automatic: an owner's death removes every allowance pointing at
  it; an allowed pid's death removes just its own entry.
