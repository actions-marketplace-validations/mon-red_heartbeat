# Changelog

## 1.0.0

First release.

- Statuses `success`, `failure`, `cancelled`, `skipped` and `start`. A cancelled or skipped job is sent to mon.red as a failure
- Without `message`: the workflow, the run number, the branch and a link to the run
- One retry after 3 seconds on a network error or HTTP 5xx
- The URL and its token are masked in the log
- `fail-on-error`: by default a heartbeat that is not delivered is only a warning
- A clear warning for HTTP 404 (unknown URL), 429 (more than 60 heartbeats a minute) and a redirect
- Ubuntu, macOS and Windows runners
