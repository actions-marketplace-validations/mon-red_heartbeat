# mon.red Heartbeat

[![Tests](https://github.com/mon-red/heartbeat/actions/workflows/test.yml/badge.svg)](https://github.com/mon-red/heartbeat/actions/workflows/test.yml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-mon.red%20Heartbeat-blue?logo=github)](https://github.com/marketplace/actions/mon-red-heartbeat)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Get an alert in Telegram, Slack, Matrix or by email when a scheduled GitHub workflow fails or stops running. One step at the end of the job sends a heartbeat to [mon.red](https://mon.red).

## Why

Scheduled workflows break quietly. A nightly backup fails, a parser stops, and you find out a week later.

- When a scheduled run fails, GitHub emails only the person who last changed its cron line.
- When a run does not happen at all, nobody is told. GitHub turns off scheduled workflows in public repositories after 60 days without activity, and at busy hours scheduled runs start late or are dropped.

mon.red waits for the heartbeat. A failed run alerts you at once. A run that did not come alerts you when its period and the grace time have passed.

## Quick start

1. Sign in at [mon.red](https://mon.red), press **Add a monitor**, open the **Heartbeat** tab and set **Expect a signal every** to the schedule of your workflow (a day for a nightly job). Copy the URL from the card of the monitor.
2. In your repository open **Settings > Secrets and variables > Actions** and add the secret `MONRED_HEARTBEAT_URL` with that URL.
3. Add the step at the end of the job:

```yaml
name: Nightly backup
on:
  schedule:
    - cron: '0 3 * * *'

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: ./backup.sh

      - uses: mon-red/heartbeat@v1
        if: always()
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
          status: ${{ job.status }}
```

`if: always()` runs the step after a failed step too. So mon.red can tell "did not run" (no heartbeat) from "ran and failed" (a heartbeat with the status `failure`).

The shortest form sends a success whenever the step is reached:

```yaml
      - uses: mon-red/heartbeat@v1
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
```

Scheduled runs often start late. Give a nightly job a **Grace time** of an hour or more, so a late run does not alert you.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `url` | yes | | The heartbeat URL of your mon.red monitor. Keep it in a secret |
| `status` | no | `success` | `success`, `failure`, `cancelled` or `skipped` (what `job.status` and `needs.<job>.result` give), or `start` at the beginning of the job |
| `message` | no | the run | A short text for mon.red, up to 200 bytes. Without it the action sends the workflow, the run number, the branch and a link to the run |
| `timeout` | no | `10` | Seconds for one request, 1 to 300 |
| `fail-on-error` | no | `false` | `true` fails the step when mon.red does not accept the heartbeat. By default it is only a warning, so the monitor never breaks your pipeline |

## Outputs

| Output | Value |
| --- | --- |
| `sent` | `true` when mon.red accepted the heartbeat, else `false` |
| `response-code` | The HTTP code of the answer of mon.red, empty when mon.red could not be reached |

## What is sent

| Status | Request | What mon.red does |
| --- | --- | --- |
| `success` | `GET <url>` | The monitor is up. The next heartbeat is due within the period and the grace time |
| `failure`, `cancelled`, `skipped` | `GET <url>/fail` | The monitor is down at once and you get an alert |
| `start` | `GET <url>/start` | The job has started. mon.red shows how long it ran and alerts when the end does not come within the grace time |

The text goes in `?msg=` and is shown in the alert and on the incident page. mon.red keeps it as one line of plain text. On a network error or an HTTP 5xx the action tries once more after 3 seconds. mon.red takes up to 60 heartbeats a minute for one monitor, the next ones get HTTP 429 and change nothing. The User-Agent is `mon-red-heartbeat-action/<version>`.

## Examples

### Nightly tests with their duration

A heartbeat at the start and one at the end. mon.red shows how long the tests ran and alerts when they hang.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: mon-red/heartbeat@v1
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
          status: start

      - uses: actions/checkout@v7
      - run: npm ci && npm test

      - uses: mon-red/heartbeat@v1
        if: always()
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
          status: ${{ job.status }}
```

### Deploy with your own text

A failed deploy alerts at once. Set the period of the monitor to the longest time between two deploys.

```yaml
      - uses: mon-red/heartbeat@v1
        if: always()
        with:
          url: ${{ secrets.MONRED_DEPLOY_HEARTBEAT_URL }}
          status: ${{ job.status }}
          message: Deploy of ${{ github.sha }} to production
```

### A matrix: one heartbeat for all its jobs

```yaml
jobs:
  test:
    strategy:
      matrix:
        node: [20, 22]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with:
          node-version: ${{ matrix.node }}
      - run: npm ci && npm test

  heartbeat:
    needs: test
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: mon-red/heartbeat@v1
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
          status: ${{ needs.test.result }}
```

### A workflow that also runs on pull requests

Secrets are empty in pull requests from forks and from Dependabot, and the step fails without its URL. Send the heartbeat only from the scheduled runs:

```yaml
      - uses: mon-red/heartbeat@v1
        if: always() && github.event_name == 'schedule'
        with:
          url: ${{ secrets.MONRED_HEARTBEAT_URL }}
          status: ${{ job.status }}
```

## How it compares to plain curl

`curl https://ping.mon.red/<token>` at the end of the job works too. The action adds:

- the status: a failed, cancelled or skipped job alerts you at once, not when the time is up
- a link to the run in the alert
- `status: start`: how long the job ran, and an alert when it hangs
- one retry on a network error or an HTTP 5xx
- the URL and its token are masked in the log
- nothing breaks: when mon.red cannot be reached, the step only warns
- the same on Ubuntu, macOS and Windows runners, with nothing to install

## mon.red

[mon.red](https://mon.red) checks websites and servers from different places and watches heartbeats of jobs. The free plan has 5 monitors, heartbeats included. [Create a free account](https://mon.red/#pricing).

## License

MIT. Questions and ideas: team@mon.red or an issue in this repository.
