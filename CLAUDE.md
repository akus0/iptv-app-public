# Maintenance notes

Read [development](docs/development.md) and [release preparation](docs/release.md).

- Preserve package identifiers, database schemas and stored preference keys unless a migration is explicitly required.
- Keep playback, sports matching and UI changes separate from documentation cleanup.
- Guide and library operations must remain bounded and asynchronous; do not scan entire playlists during widget builds.
- Use existing shared sessions/caches when entering sports through multiview. Preserve selection, scroll position and matches during background updates.
- A playlist may allow only one stream. Use synthetic/offline fixtures for routine tests; never automatically open real subscription streams.
- Keep credentials, device addresses, private fixture locations and deployment details in the ignored `.env`. Store binary keys and private datasets outside the checkout.
- Never include `.env`, local databases, device captures, logs or generated APKs in source archives. Reviewed app screenshots rendered with synthetic data may be kept in `docs/screenshots/`. Do not print credential-bearing URLs in logs or diagnostics.
- Console failure logs should name the operation and exception type, not raw exception text, SQL arguments or provider-supplied labels. Those may contain account data.
- Preserve upstream and dependency copyright/licence notices. Keep fork branding distinct.
- Review existing uncommitted changes before editing. Do not discard unrelated work.
- Record behaviour changes in `CHANGELOG.md`; keep machine-specific investigation notes outside the repository.
- Explain implementation decisions in comments; omit conversation history, personal setups and credential-shaped examples.
