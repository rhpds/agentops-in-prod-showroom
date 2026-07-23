# Lab Runner

Automated validation script for the **AgentOps in Production** workshop environment. Runs through all 6 lab modules and checks that the OpenShift cluster has everything deployed correctly.

## Prerequisites

- `oc` CLI installed and in PATH
- `curl` available
- `jq` available
- Network access to the cluster API and application routes

## Quick Start

```bash
chmod +x lab-runner.sh

./lab-runner.sh \
  --api-url https://api.cluster.example.com:6443 \
  --password openshift
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--api-url URL` | (required) | OpenShift API URL |
| `--password PASS` | (required) | Cluster password |
| `--username USER` | `user1` | Login username |
| `--user-prefix PREFIX` | `user` | User prefix for namespace derivation |
| `--user-count N` | `1` | Number of user environments to validate |
| `--skip-singleton` | off | Skip cluster-wide infrastructure checks |
| `--skip-modules LIST` | none | Comma-separated module numbers to skip (e.g. `5,6`) |
| `--verbose` | off | Show detailed output on failures |
| `--help` | | Show usage |

## Examples

Validate a single user as admin:

```bash
./lab-runner.sh \
  --api-url https://api.cluster-abc.example.com:6443 \
  --password mypassword \
  --username admin
```

Validate 5 users (wksp-user1 through wksp-user5):

```bash
./lab-runner.sh \
  --api-url https://api.cluster-abc.example.com:6443 \
  --password mypassword \
  --username admin \
  --user-count 5
```

Skip Jupyter notebook modules and focus on core infrastructure:

```bash
./lab-runner.sh \
  --api-url https://api.cluster-abc.example.com:6443 \
  --password openshift \
  --skip-modules 5,6
```

## What Gets Checked

| Module | Checks | Notes |
|--------|--------|-------|
| **Singleton** | RHOAI operator, DataScienceCluster, MLflow (pod + operator), LokiStack, ClusterLogForwarder | Run once before per-user checks |
| **Module 1** | Namespace, core pods (API, UI, DB, MinIO), seed job, routes, health endpoint, UI response | Core application validation |
| **Module 2** | (skipped) | Conceptual module - no infrastructure |
| **Module 3** | Grafana pod, route, GrafanaDashboard CR, ServiceMonitor | Observability stack |
| **Module 4** | MLflow route, API docs endpoint | Tracing infrastructure |
| **Module 5** | DSPA CR, all DSPA pods, llm-credentials secret, LLM credentials populated | Evaluation infrastructure (notebook execution skipped) |
| **Module 6** | DSPA pipeline route, MariaDB | Pipeline infrastructure (execution skipped) |

## Exit Codes

- `0` - All checks passed (SKIPs do not count as failures)
- `1` - At least one check failed

## Output Format

```
  PASS  Pod mortgage-ai-api running (1/1) in wksp-user1
  FAIL  Health endpoint returned unhealthy
  SKIP  Notebook execution - verify manually in Jupyter
```
