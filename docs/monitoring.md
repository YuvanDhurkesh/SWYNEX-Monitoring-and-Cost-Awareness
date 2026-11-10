# Logs and status checks

This page explains each monitoring signal for the CloudNotes Lite deployment: what it measures, where to find it, how quickly it updates, and what it costs.

| Signal | What it answers | Where | Delay | Cost |
|---|---|---|---|---|
| Status check | Can a visitor load the site right now, and are the Task 2 security settings still in place? | [`scripts/status-check.sh`](../scripts/status-check.sh), run locally and every 3 hours by GitHub Actions | Immediate | Free |
| CloudWatch metrics | How many requests, how much data, and what share of requests failed? | CloudWatch in `us-east-1`, or [`scripts/metrics.sh`](../scripts/metrics.sh) | About 1 to 3 minutes | Free (default CloudFront metrics) |
| Access logs | Which paths were requested, from which edge locations, and was the cache used? | S3 bucket `swynex-cloudnotes-logs-g3v99b`, summarised by [`scripts/log-report.sh`](../scripts/log-report.sh) | Within about an hour | S3 storage only (a few KB a day) |
| CloudTrail Event history | Who changed the bucket or distribution, and when? | CloudTrail console, Event history | About 5 minutes | Free (last 90 days) |

## 1. Status check (the visitor's view)

`status-check.sh` makes the same requests a browser would, from outside AWS. It needs only `curl` and `openssl`, so it runs anywhere, including GitHub Actions, without AWS credentials.

| Check | OK when | Why it matters |
|---|---|---|
| Home page is up | HTTP 200 within 10 seconds | The basic uptime signal |
| Response time | Under 1,500 ms | A slow edge or origin shows up here before users complain |
| Static assets load | `styles.css`, `app.js`, `build.js` return 200 | A deploy that dropped a file would leave a broken page that still returns 200 |
| HTTP redirects to HTTPS | 301 | Confirms the viewer protocol policy |
| HSTS header | Present | Confirms the security headers policy is still attached |
| Missing page returns 404 | 404 | Confirms the custom error responses |
| Direct S3 access is blocked | 403 | The most important security check: the bucket must stay private |
| TLS certificate | More than 30 days left | AWS renews `*.cloudfront.net`, but a custom domain added later would need watching |
| Edge cache result (INFO) | | `Hit`, `RefreshHit` or `Miss`, and the edge location that answered |
| Deployed build (INFO) | | The Git commit the live site is running, read from `build.js` |

```bash
./scripts/status-check.sh                                  # print the results
./scripts/status-check.sh --log status-history.csv         # also append a CSV line
```

The script exits with status 1 if any check fails, so it can be used in any scheduler. With `--log`, each run adds a line such as:

```
utc_time,result,http_code,response_ms,x_cache,edge_location,build
2026-11-10T06:21:34Z,OK,200,315,RefreshHit from cloudfront,MAA50-P1,504ae5f
```

### Scheduled check with GitHub Actions

[`.github/workflows/uptime-check.yml`](../.github/workflows/uptime-check.yml) runs the status check every 3 hours from GitHub's servers, and it can also be started by hand from the **Actions** tab. Each run writes a results table to the run's summary page. When a check fails, the run fails and GitHub emails the repository owner. This gives a second alert path that does not depend on AWS.

GitHub pauses scheduled workflows in a public repository after 60 days without activity. Re-enable the workflow from the Actions tab if that happens.

## 2. CloudWatch metrics

CloudFront sends these metrics to CloudWatch at no charge. They are global, so they appear in **us-east-1** with the dimensions `DistributionId=E3U1SQME8RV8W7` and `Region=Global`.

| Metric | Meaning |
|---|---|
| `Requests` | Number of viewer requests |
| `BytesDownloaded` | Bytes sent to viewers |
| `4xxErrorRate` | Percentage of requests that returned 4xx (for example missing pages) |
| `5xxErrorRate` | Percentage of requests that returned 5xx (CloudFront or S3 could not serve the file) |
| `TotalErrorRate` | 4xx and 5xx together |

**Console:** CloudFront → select the distribution → **Monitoring** tab, or CloudWatch (region N. Virginia) → **Metrics** → **CloudFront** → **Per-Distribution Metrics**.

**CLI:** `./scripts/metrics.sh [HOURS]` prints requests and errors for each hour, totals, and the state of each alarm:

```
  Hour (UTC)       Requests    4xx    5xx
  2026-11-10 05:00       63      6      0  #############
  2026-11-10 06:00      142      7      0  ##############################

  Total requests          205
  Data sent to viewers    349.0 KB
  4xx error rate          6.3%
  5xx error rate          0.0%
```

CloudFront also offers **additional metrics** (cache hit rate, origin latency, and error rates per status code). These are billed as CloudWatch custom metrics, so they are left off. The access log report below calculates the cache hit ratio from the logs at no extra cost.

## 3. Access logs

CloudFront standard logging writes one line per request to the private bucket `swynex-cloudnotes-logs-g3v99b`, under the `cloudfront/` prefix. Files arrive gzipped, usually within an hour.

How the log bucket is set up:

- **Private.** All four Block Public Access settings are on.
- **ACLs enabled** (`BucketOwnerPreferred`). Standard logging delivers files through a bucket ACL grant to the `awslogsdelivery` account, which CloudFront adds itself when logging is turned on.
- **Encrypted** with SSE-S3. SSE-KMS would need a customer managed KMS key with a key policy for log delivery, which has a monthly charge.
- **Logs deleted after 30 days** by a lifecycle rule, so storage cannot grow without limit.

Access logs contain client IP addresses, which count as personal data. They stay in a private bucket, expire after 30 days, and the report script counts IP addresses but never prints them.

`./scripts/log-report.sh [HOURS]` downloads the log files and summarises them:

```
Access log report: last 24 hours (since 2026-11-09 06:20:03 UTC), 1 log files
  Requests                 134
  Distinct client IPs      3
  Edge location cities     2
  Data sent                227.6 KB
  Cache hit ratio          93% (Hit + RefreshHit)
  Average time taken       40 ms (slowest 1463 ms)

  Paths that returned 4xx (broken links or scanners)
         1  /wp-login.php (404)
         1  /robots.txt (404)
         1  /.env (404)
         ...
  Edge locations (first 3 letters are the nearest airport code)
       132  MAA50-P1
         2  SEA900-P10
```

How to read it:

- **Cache hit ratio** shows how often CloudFront answered without going to S3. HTML is sent with `Cache-Control: no-cache`, so it shows as `RefreshHit`: CloudFront checked with S3 that its copy was still current.
- **Paths that returned 4xx** finds broken links after a deploy, and also bots probing for files such as `/wp-login.php` and `/.env`. To check that the report catches this, a few such requests were sent by hand as a test. They got the custom 404 page, because the bucket contains only the site's own files. The `/robots.txt` request was not a test: it came from a real crawler through the Seattle edge location.
- **Edge locations** shows where visitors are. `MAA` is Chennai and `SEA` is Seattle.

The fields used, in log order: `date`, `time`, `x-edge-location`, `sc-bytes`, `c-ip`, `cs-uri-stem`, `sc-status`, `x-edge-result-type`, `time-taken` and `cs-protocol-version`. The full list is in the [CloudFront log file format documentation](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logs-reference.html).

## 4. Change history (CloudTrail)

CloudTrail **Event history** records management actions, such as `UpdateDistribution`, `PutBucketPolicy` and `CreateInvalidation`, for 90 days at no cost. Open CloudTrail → **Event history** and filter by **Resource name** (the distribution ID or bucket name) to see who changed what. The account has no trail, so events older than 90 days are not kept (see the [access-control checklist](../README.md#access-control-checklist)).
