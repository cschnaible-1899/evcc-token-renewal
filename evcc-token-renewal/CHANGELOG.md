## 1.0.0

- Initial release as a Home Assistant add-on
- Self-contained daily timer — no HA automation required
- Configurable daily check time (HH:MM), EVCC yaml path, add-on slug, renewal threshold
- Uses Supervisor API token automatically — no long-lived HA token needed
- Idempotent: skips renewal when token is not near expiry or docs page not yet updated
- Backup and write-verify before modifying evcc.yaml
