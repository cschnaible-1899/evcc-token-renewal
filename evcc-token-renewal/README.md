# EVCC Token Renewal

Automatically checks and renews the EVCC trial sponsor token once per day at a configurable time. Runs as a persistent add-on — no Home Assistant automation required.

## How it works

The add-on sleeps until the configured `check_time`, then:
1. Reads the current sponsor token from `evcc.yaml`
2. Decodes the JWT expiry — skips if still within the safe window
3. Fetches a fresh token from the EVCC documentation page
4. Updates `evcc.yaml` (with backup + write-verify)
5. Restarts the EVCC add-on via the Supervisor API
6. Loops back and sleeps until the next scheduled time

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `evcc_yaml_path` | `/homeassistant/evcc.yaml` | Path to your EVCC configuration file |
| `evcc_addon_slug` | `49686a9f_evcc` | Your EVCC add-on slug — find it with `ha addons list \| grep -i evcc` |
| `renewal_threshold_days` | `2` | Renew when fewer than this many days remain before expiry |
| `check_time` | `02:15` | Daily check time in `HH:MM` 24-hour format |

## Finding your EVCC add-on slug

From the Home Assistant terminal:

```bash
ha addons list | grep -i evcc
```

Common slugs: `local_evcc`, `c52fd6_evcc`, `a0d7b954_evcc`, `49686a9f_evcc`

## Logs

All activity is visible in the **Log** tab of the add-on in the HA UI.
