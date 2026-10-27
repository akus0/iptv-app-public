# Optional pairing relay

LAN phone pairing works directly with the app. This service is only needed for internet pairing and encrypted payload storage; no hosted relay is configured by default.

Run with Python 3:

```sh
PAIR_VAULT_DIR="$HOME/.local/share/iptv-app/pair-vault" python3 tools/pair_relay/relay.py
```

The default bind is loopback on port 8930; override with `PAIR_HOST` and `PAIR_PORT`. From the source checkout, the relay uses the bundled pairing form; set `PAIR_PAGE` to override it. For deployment, use the supplied systemd/nginx templates, serve [pair.html](../../assets/pair/pair.html), replace the example domain and configure TLS. Review the service's storage and rate limits before exposure.

Pairing payloads expire after ten minutes. The vault uses `PAIR_VAULT_DIR` for encrypted blobs, with a seven-day expiry and a storage cap. Decryption keys stay with the clients.

Set the app's public build value with `--dart-define=PAIR_RELAY_BASE=https://pair.example.com`, using your own host. The retained `X-VesperTV-App` protocol marker is not authentication. Do not use the upstream project's hosted relay.
