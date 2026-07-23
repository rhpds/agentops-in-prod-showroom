#!/usr/bin/env bash
#
# lab-runner.sh - Automated validation for AgentOps in Production workshop
#
# Runs through all 6 lab modules and validates that the workshop environment
# is correctly deployed on OpenShift. Reports PASS/FAIL/SKIP per check.
#
# Prerequisites: oc, curl, jq
#
# Usage:
#   ./lab-runner.sh --api-url https://api.cluster.example.com:6443 --password openshift
#

set -o pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
API_URL=""
PASSWORD=""
USERNAME="user1"
USER_PREFIX="user"
USER_COUNT=1
SKIP_SINGLETON=false
SKIP_MODULES=""
VERBOSE=false
USE_COLOR=true

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
START_TIME=""

# Pod cache to reduce API calls (one oc get pods per namespace)
_POD_CACHE=""
_POD_CACHE_NS=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
_pass() {
  if [[ "$USE_COLOR" == "true" ]]; then
    printf '  \033[32mPASS\033[0m  %s\n' "$1"
  else
    printf '  PASS  %s\n' "$1"
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
}

_fail() {
  if [[ "$USE_COLOR" == "true" ]]; then
    printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1"
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [[ "$VERBOSE" == "true" && -n "${2:-}" ]]; then
    echo "        Detail: $2"
  fi
}

_skip() {
  if [[ "$USE_COLOR" == "true" ]]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "$1"
  else
    printf '  SKIP  %s\n' "$1"
  fi
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

_info() {
  if [[ "$USE_COLOR" == "true" ]]; then
    printf '  \033[36mINFO\033[0m  %s\n' "$1"
  else
    printf '  INFO  %s\n' "$1"
  fi
}

_section() {
  echo ""
  echo "======================================================================"
  echo "  $1"
  echo "======================================================================"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --api-url <URL> --password <PASSWORD> [OPTIONS]

Required:
  --api-url URL          OpenShift API URL (e.g. https://api.cluster.example.com:6443)
  --password PASSWORD    Cluster password

Options:
  --username USER        Login username (default: user1)
  --user-prefix PREFIX   User prefix for namespaces (default: user)
  --user-count N         Number of users to validate (default: 1)
  --skip-singleton       Skip cluster-wide infrastructure checks
  --skip-modules LIST    Comma-separated module numbers to skip (e.g. 5,6)
  --verbose              Show command output on failures
  --no-color             Disable colored output
  --help                 Show this help message
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url)
        [[ -z "${2:-}" ]] && { echo "Error: --api-url requires a value"; exit 1; }
        API_URL="$2"; shift 2 ;;
      --password)
        [[ -z "${2:-}" ]] && { echo "Error: --password requires a value"; exit 1; }
        PASSWORD="$2"; shift 2 ;;
      --username)
        [[ -z "${2:-}" ]] && { echo "Error: --username requires a value"; exit 1; }
        USERNAME="$2"; shift 2 ;;
      --user-prefix)
        [[ -z "${2:-}" ]] && { echo "Error: --user-prefix requires a value"; exit 1; }
        USER_PREFIX="$2"; shift 2 ;;
      --user-count)
        [[ -z "${2:-}" ]] && { echo "Error: --user-count requires a value"; exit 1; }
        USER_COUNT="$2"; shift 2 ;;
      --skip-singleton) SKIP_SINGLETON=true; shift ;;
      --skip-modules)
        [[ -z "${2:-}" ]] && { echo "Error: --skip-modules requires a value"; exit 1; }
        SKIP_MODULES="$2"; shift 2 ;;
      --verbose)  VERBOSE=true; shift ;;
      --no-color) USE_COLOR=false; shift ;;
      --help)     usage ;;
      *)          echo "Error: Unknown option: $1"; usage ;;
    esac
  done

  if [[ -z "$API_URL" ]]; then
    echo "Error: --api-url is required"; exit 1
  fi
  if [[ -z "$PASSWORD" ]]; then
    echo "Error: --password is required"; exit 1
  fi
  if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [[ "$USER_COUNT" -lt 1 ]]; then
    echo "Error: --user-count must be a positive integer (got: ${USER_COUNT})"; exit 1
  fi

  # Auto-detect non-tty: disable color when output is piped or redirected
  if [[ ! -t 1 ]]; then
    USE_COLOR=false
  fi
}

should_skip_module() {
  local mod="$1"
  echo ",$SKIP_MODULES," | grep -q ",$mod,"
}

# ---------------------------------------------------------------------------
# Pod cache: fetch pod list once per namespace, reuse across checks
# ---------------------------------------------------------------------------
_get_pods() {
  local ns="$1"
  if [[ "$ns" != "$_POD_CACHE_NS" ]]; then
    _POD_CACHE=$(oc get pods -n "$ns" --no-headers 2>/dev/null)
    _POD_CACHE_NS="$ns"
  fi
  echo "$_POD_CACHE"
}

_invalidate_pod_cache() {
  _POD_CACHE=""
  _POD_CACHE_NS=""
}

# ---------------------------------------------------------------------------
# Helper: check if a pod (by name prefix) is Running with expected containers
# ---------------------------------------------------------------------------
check_pod_ready() {
  local ns="$1" prefix="$2" expected_containers="$3"
  local pod_line
  pod_line=$(_get_pods "$ns" | grep "^${prefix}-" | grep -v "Completed\|Succeeded\|Evicted" | head -1)

  if [[ -z "$pod_line" ]]; then
    _fail "Pod ${prefix} not found in ${ns}"
    return 1
  fi

  local ready status
  ready=$(echo "$pod_line" | awk '{print $2}')
  status=$(echo "$pod_line" | awk '{print $3}')

  if [[ "$status" != "Running" ]]; then
    _fail "Pod ${prefix} status is ${status} (expected Running) in ${ns}" "$pod_line"
    return 1
  fi

  local ready_count total_count
  ready_count=$(echo "$ready" | cut -d/ -f1)
  total_count=$(echo "$ready" | cut -d/ -f2)

  if [[ "$ready_count" != "$total_count" ]]; then
    _fail "Pod ${prefix} containers ${ready} not fully ready in ${ns}" "$pod_line"
    return 1
  fi

  if [[ "$expected_containers" -gt 0 && "$total_count" != "$expected_containers" ]]; then
    _fail "Pod ${prefix} has ${total_count} containers (expected ${expected_containers}) in ${ns}" "$pod_line"
    return 1
  fi

  _pass "Pod ${prefix} running (${ready}) in ${ns}"
  return 0
}

# ---------------------------------------------------------------------------
# Helper: check namespace exists (used as guard in every module)
# ---------------------------------------------------------------------------
check_ns_exists() {
  local ns="$1" module="$2"
  if oc get namespace "$ns" &>/dev/null; then
    return 0
  else
    _fail "Namespace ${ns} not found"
    _info "Skipping remaining ${module} checks - namespace missing"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: check a route exists and get its host
# ---------------------------------------------------------------------------
get_route_host() {
  local ns="$1" route="$2"
  oc get route "$route" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null
}

check_route_exists() {
  local ns="$1" route="$2"
  local host
  host=$(get_route_host "$ns" "$route")
  if [[ -n "$host" ]]; then
    _pass "Route ${route} exists (${host})"
    return 0
  else
    _fail "Route ${route} not found in ${ns}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: check HTTP endpoint is reachable
# ---------------------------------------------------------------------------
check_http() {
  local url="$1" description="$2" accept_codes="${3:-200}"
  local http_code
  http_code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    _fail "${description} - connection failed"
    return 1
  fi

  if echo ",$accept_codes," | grep -q ",$http_code,"; then
    _pass "${description} (HTTP ${http_code})"
    return 0
  else
    _fail "${description} - HTTP ${http_code} (expected ${accept_codes})" "URL: ${url}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight: Login
# ---------------------------------------------------------------------------
check_login() {
  _section "Pre-flight: Cluster Authentication"

  local output
  output=$(oc login --insecure-skip-tls-verify "$API_URL" -u "$USERNAME" -p "$PASSWORD" 2>&1)
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    _fail "oc login failed" "$output"
    echo ""
    echo "FATAL: Cannot authenticate to cluster. Aborting."
    exit 1
  fi

  local whoami
  whoami=$(oc whoami 2>/dev/null)
  if [[ "$whoami" == "$USERNAME" ]]; then
    _pass "Logged in as ${USERNAME}"
  else
    _fail "oc whoami returned '${whoami}' (expected '${USERNAME}')"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Singleton infrastructure checks
# ---------------------------------------------------------------------------
check_singleton_infra() {
  _section "Singleton Infrastructure"

  # S1: RHOAI operator
  local rhods_pods
  rhods_pods=$(oc get pods -n redhat-ods-operator --no-headers 2>/dev/null | grep -i "rhods\|opendatahub" | grep Running)
  if [[ -n "$rhods_pods" ]]; then
    _pass "RHOAI operator running in redhat-ods-operator"
  else
    _fail "RHOAI operator not found running in redhat-ods-operator"
  fi

  # S2: DataScienceCluster
  if oc get datasciencecluster default-dsc --no-headers &>/dev/null; then
    _pass "DataScienceCluster 'default-dsc' exists"
  else
    _fail "DataScienceCluster 'default-dsc' not found"
  fi

  # S3: User workload monitoring enabled
  if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
    _pass "Cluster monitoring ConfigMap exists (user workload monitoring)"
  else
    _fail "cluster-monitoring-config not found in openshift-monitoring (Grafana dashboards will show no data)"
  fi

  # S4: MLflow pod
  local mlflow_pod
  mlflow_pod=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep "^mlflow-" | grep -v "operator" | grep Running | head -1)
  if [[ -n "$mlflow_pod" ]]; then
    local mlflow_ready
    mlflow_ready=$(echo "$mlflow_pod" | awk '{print $2}')
    _pass "MLflow pod running (${mlflow_ready}) in redhat-ods-applications"
  else
    _fail "MLflow pod not found running in redhat-ods-applications"
  fi

  # S5: MLflow operator
  local mlflow_op
  mlflow_op=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep "mlflow-operator" | grep Running | head -1)
  if [[ -n "$mlflow_op" ]]; then
    _pass "MLflow operator running in redhat-ods-applications"
  else
    _fail "MLflow operator not found running in redhat-ods-applications"
  fi

  # S6: LokiStack pods
  local loki_running
  loki_running=$(oc get pods -n openshift-logging --no-headers 2>/dev/null | grep -c Running || true)
  if [[ "$loki_running" -ge 5 ]]; then
    _pass "LokiStack: ${loki_running} pods running in openshift-logging"
  else
    _fail "LokiStack: only ${loki_running} pods running in openshift-logging (expected >= 5)"
  fi

  # S7: Log collector pods running
  local collector_pods
  collector_pods=$(oc get pods -n openshift-logging --no-headers 2>/dev/null | grep "^collector-" | grep -c Running || true)
  if [[ "$collector_pods" -ge 1 ]]; then
    _pass "Log collectors: ${collector_pods} pod(s) running"
  else
    _fail "No log collector pods found running in openshift-logging"
  fi

  # S8: LokiStack CR
  if oc get lokistack logging-loki -n openshift-logging --no-headers &>/dev/null; then
    _pass "LokiStack CR 'logging-loki' exists"
  else
    _fail "LokiStack CR 'logging-loki' not found in openshift-logging"
  fi

  # S9: ClusterLogForwarder
  if oc get clusterlogforwarder collector -n openshift-logging --no-headers &>/dev/null; then
    _pass "ClusterLogForwarder 'collector' exists"
  else
    _fail "ClusterLogForwarder 'collector' not found in openshift-logging"
  fi

  # S10: LokiStack PVCs bound
  local loki_pvcs_total loki_pvcs_bound
  loki_pvcs_total=$(oc get pvc -n openshift-logging --no-headers 2>/dev/null | grep -c "logging-loki" || true)
  loki_pvcs_bound=$(oc get pvc -n openshift-logging --no-headers 2>/dev/null | grep "logging-loki" | grep -c "Bound" || true)
  if [[ "$loki_pvcs_total" -eq 0 ]]; then
    _fail "No LokiStack PVCs found in openshift-logging"
  elif [[ "$loki_pvcs_bound" -eq "$loki_pvcs_total" ]]; then
    _pass "LokiStack PVCs: ${loki_pvcs_bound}/${loki_pvcs_total} Bound"
  else
    local pending_pvcs
    pending_pvcs=$(oc get pvc -n openshift-logging --no-headers 2>/dev/null | grep "logging-loki" | grep -v "Bound")
    _fail "LokiStack PVCs: ${loki_pvcs_bound}/${loki_pvcs_total} Bound (some not bound)" "$pending_pvcs"
  fi

  # S11: Loki MinIO PVC bound
  local minio_pvc
  minio_pvc=$(oc get pvc minio-pvc -n openshift-logging --no-headers 2>/dev/null)
  if [[ -n "$minio_pvc" ]]; then
    if echo "$minio_pvc" | grep -q "Bound"; then
      _pass "Loki MinIO PVC 'minio-pvc' Bound"
    else
      _fail "Loki MinIO PVC 'minio-pvc' not Bound" "$minio_pvc"
    fi
  else
    _fail "Loki MinIO PVC 'minio-pvc' not found in openshift-logging"
  fi
}

# ---------------------------------------------------------------------------
# Module 1: The Agentic App
# ---------------------------------------------------------------------------
check_module1() {
  local ns="$1"
  _section "Module 1: The Agentic App [${ns}]"

  check_ns_exists "$ns" "Module 1" || return

  # Warm the pod cache for this namespace
  _get_pods "$ns" > /dev/null

  # 1.1: Core pods
  check_pod_ready "$ns" "mortgage-ai-api" 1
  check_pod_ready "$ns" "mortgage-ai-ui" 1
  check_pod_ready "$ns" "mortgage-ai-db" 1
  check_pod_ready "$ns" "minio" 1

  # 1.2: Seed job completed (may be cleaned up by TTL after success)
  local seed_status
  seed_status=$(_get_pods "$ns" | grep "mortgage-ai-seed" | grep "Completed" | head -1)
  if [[ -n "$seed_status" ]]; then
    _pass "Seed job completed in ${ns}"
  else
    local seed_job
    seed_job=$(oc get job -n "$ns" --no-headers 2>/dev/null | grep "mortgage-ai-seed" | head -1)
    if [[ -n "$seed_job" ]]; then
      local succeeded
      succeeded=$(echo "$seed_job" | awk '{print $2}')
      if [[ "$succeeded" =~ ^[1-9] ]]; then
        _pass "Seed job succeeded (${succeeded}) in ${ns}"
      else
        _fail "Seed job not completed in ${ns}" "$seed_job"
      fi
    else
      _pass "Seed job cleaned up (TTL) - app is running, data assumed loaded"
    fi
  fi

  # 1.3: PVCs bound
  local expected_pvcs=("postgres-storage-mortgage-ai-db-0" "minio-pvc" "grafana-pvc" "mariadb-dspa")
  for pvc_name in "${expected_pvcs[@]}"; do
    local pvc_line
    pvc_line=$(oc get pvc "$pvc_name" -n "$ns" --no-headers 2>/dev/null)
    if [[ -z "$pvc_line" ]]; then
      _fail "PVC '${pvc_name}' not found in ${ns}"
    elif echo "$pvc_line" | grep -q "Bound"; then
      _pass "PVC '${pvc_name}' Bound in ${ns}"
    else
      _fail "PVC '${pvc_name}' not Bound in ${ns}" "$pvc_line"
    fi
  done

  # 1.4: Routes exist
  local routes=("mortgage-ai-ui-route" "mortgage-ai-api-route" "mortgage-ai-api-health-route" "mortgage-ai-api-docs-route" "mortgage-ai-api-admin-route")
  for route in "${routes[@]}"; do
    check_route_exists "$ns" "$route"
  done

  # 1.5: Health endpoint
  local health_host
  health_host=$(get_route_host "$ns" "mortgage-ai-api-health-route")
  if [[ -n "$health_host" ]]; then
    local health_response
    health_response=$(curl -sk --connect-timeout 10 --max-time 30 "https://${health_host}/health/" 2>/dev/null)
    local api_status db_status
    api_status=$(echo "$health_response" | jq -r '.[0].status // empty' 2>/dev/null)
    db_status=$(echo "$health_response" | jq -r '.[1].status // empty' 2>/dev/null)

    if [[ "$api_status" == "healthy" && "$db_status" == "healthy" ]]; then
      _pass "Health endpoint: API healthy, Database healthy"
    else
      _fail "Health endpoint: API=${api_status:-unknown}, Database=${db_status:-unknown}" "$health_response"
    fi
  else
    _fail "Cannot check health - route not found"
  fi

  # 1.6: UI responds
  local ui_host
  ui_host=$(get_route_host "$ns" "mortgage-ai-ui-route")
  if [[ -n "$ui_host" ]]; then
    check_http "https://${ui_host}/" "UI route responds" "200"
  else
    _fail "Cannot check UI - route not found"
  fi

  # 1.7: API serves product data (database integration test)
  local api_host
  api_host=$(get_route_host "$ns" "mortgage-ai-api-route")
  if [[ -n "$api_host" ]]; then
    local products_response
    products_response=$(curl -sk --connect-timeout 10 --max-time 30 "https://${api_host}/api/public/products" 2>/dev/null)
    local product_count
    product_count=$(echo "$products_response" | jq 'length' 2>/dev/null)
    if [[ -n "$product_count" && "$product_count" -gt 0 ]]; then
      _pass "API serves ${product_count} mortgage products (DB integration OK)"
    else
      _fail "API /api/public/products returned no data" "${products_response:0:200}"
    fi
  else
    _fail "Cannot test products endpoint - API route not found"
  fi

  # 1.8: LLM chat functional test (verifies full chain: API -> Agent -> LLM)
  local api_pod
  api_pod=$(_get_pods "$ns" | grep "^mortgage-ai-api-" | grep Running | awk '{print $1}' | head -1)
  if [[ -n "$api_pod" ]]; then
    _info "Testing LLM chat (this may take up to 60s)..."
    local chat_result
    chat_result=$(oc exec -n "$ns" "$api_pod" -c api -- timeout 60 python3 -c "
import asyncio, json
async def test():
    try:
        import websockets
    except ImportError:
        print('SKIP:websockets not available in pod')
        return
    try:
        async with websockets.connect('ws://localhost:8000/api/chat', open_timeout=10) as ws:
            await ws.send(json.dumps({'type': 'message', 'content': 'hello'}))
            full = ''
            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=45)
                    msg = json.loads(raw)
                    if msg.get('type') == 'done':
                        full = msg.get('content', full)
                        break
                    elif msg.get('type') == 'token':
                        full += msg.get('content', '')
                    elif msg.get('type') == 'error':
                        print('ERROR:' + msg.get('content', 'unknown'))
                        return
                except asyncio.TimeoutError:
                    print('ERROR:timeout waiting for LLM response')
                    return
            print('OK:' + str(len(full)))
    except Exception as e:
        print('ERROR:' + str(e))
asyncio.run(test())
" 2>&1 | tail -1)

    case "$chat_result" in
      OK:*)
        local resp_len="${chat_result#OK:}"
        _pass "LLM chat response received (${resp_len} chars) - model is working"
        ;;
      SKIP:*)
        _skip "LLM chat test - ${chat_result#SKIP:}"
        ;;
      ERROR:*)
        _fail "LLM chat test failed - ${chat_result#ERROR:}"
        ;;
      *)
        _fail "LLM chat test - unexpected result" "$chat_result"
        ;;
    esac
  else
    _fail "Cannot test LLM chat - mortgage-ai-api pod not found"
  fi
}

# ---------------------------------------------------------------------------
# Module 2: Observability Pillars (conceptual)
# ---------------------------------------------------------------------------
check_module2() {
  _section "Module 2: Observability Pillars"
  _skip "Conceptual module - no infrastructure to validate"
}

# ---------------------------------------------------------------------------
# Module 3: Metrics & KPIs
# ---------------------------------------------------------------------------
check_module3() {
  local ns="$1"
  _section "Module 3: Metrics & KPIs [${ns}]"

  check_ns_exists "$ns" "Module 3" || return

  # 3.1: Grafana pod
  check_pod_ready "$ns" "grafana-deployment" 2

  # 3.2: Grafana route accessible
  local grafana_host
  grafana_host=$(get_route_host "$ns" "grafana-route")
  if [[ -n "$grafana_host" ]]; then
    check_http "https://${grafana_host}/" "Grafana route accessible" "200,302,403"
  else
    _fail "Grafana route not found in ${ns}"
  fi

  # 3.3: GrafanaDashboard CR
  if oc get grafanadashboard mortgage-ai-backend -n "$ns" --no-headers &>/dev/null; then
    _pass "GrafanaDashboard 'mortgage-ai-backend' exists in ${ns}"
  else
    _fail "GrafanaDashboard 'mortgage-ai-backend' not found in ${ns}"
  fi

  # 3.4: Grafana datasources configured
  local ds_count
  ds_count=$(oc get grafanadatasource -n "$ns" --no-headers 2>/dev/null | grep -c "" || true)
  if [[ "$ds_count" -ge 1 ]]; then
    _pass "Grafana datasources: ${ds_count} configured in ${ns}"
  else
    _fail "No Grafana datasources found in ${ns} (dashboard will show 'No data')"
  fi

  # 3.5: ServiceMonitor
  local sm
  sm=$(oc get servicemonitor -n "$ns" --no-headers 2>/dev/null | grep "mortgage-ai")
  if [[ -n "$sm" ]]; then
    _pass "ServiceMonitor for mortgage-ai exists in ${ns}"
  else
    _fail "ServiceMonitor for mortgage-ai not found in ${ns}"
  fi
}

# ---------------------------------------------------------------------------
# Module 4: Tracing & MLflow
# ---------------------------------------------------------------------------
check_module4() {
  local ns="$1"
  _section "Module 4: Tracing & MLflow [${ns}]"

  check_ns_exists "$ns" "Module 4" || return

  # 4.1: MLflow accessible (via route or internal service)
  local mlflow_host
  mlflow_host=$(oc get route -n redhat-ods-applications --no-headers 2>/dev/null | grep "^mlflow" | grep -v operator | awk '{print $2}' | head -1)
  if [[ -n "$mlflow_host" ]]; then
    check_http "https://${mlflow_host}/" "MLflow route accessible" "200,302,401,403"
  else
    local mlflow_svc
    mlflow_svc=$(oc get svc -n redhat-ods-applications --no-headers 2>/dev/null | grep "^mlflow" | grep -v operator | head -1)
    if [[ -n "$mlflow_svc" ]]; then
      _pass "MLflow service exists (accessed via RHOAI dashboard, no external route)"
    else
      local mlflow_pod
      mlflow_pod=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep "^mlflow-" | grep -v operator | grep Running | head -1)
      if [[ -n "$mlflow_pod" ]]; then
        _pass "MLflow pod running (no external route or service found)"
      else
        _fail "MLflow not found in redhat-ods-applications (no route, service, or pod)"
      fi
    fi
  fi

  # 4.2: API docs endpoint
  local docs_host
  docs_host=$(get_route_host "$ns" "mortgage-ai-api-docs-route")
  if [[ -n "$docs_host" ]]; then
    local docs_response
    docs_response=$(curl -sk --connect-timeout 10 --max-time 30 "https://${docs_host}/docs" 2>/dev/null)
    if echo "$docs_response" | grep -qi "openapi\|swagger\|FastAPI"; then
      _pass "API docs endpoint returns OpenAPI content"
    else
      _fail "API docs endpoint did not return expected content" "Response length: ${#docs_response}"
    fi
  else
    _fail "Cannot check API docs - route not found"
  fi

  # 4.3: MLflow tracing - experiment exists and traces are being collected
  local api_pod
  api_pod=$(_get_pods "$ns" | grep "^mortgage-ai-api-" | grep Running | awk '{print $1}' | head -1)
  if [[ -z "$api_pod" ]]; then
    _fail "Cannot check MLflow tracing - mortgage-ai-api pod not found"
  else
    local mlflow_result
    mlflow_result=$(oc exec -n "$ns" "$api_pod" -c api -- timeout 15 python3 -c "
import json, urllib.request, ssl, os
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
uri = os.environ.get('MLFLOW_TRACKING_URI', '')
workspace = os.environ.get('MLFLOW_WORKSPACE', '')
experiment = os.environ.get('MLFLOW_EXPERIMENT_NAME', 'mortgage-ai')
if not uri:
    print('SKIP:MLFLOW_TRACKING_URI not configured')
else:
    token = ''
    try:
        with open('/run/secrets/kubernetes.io/serviceaccount/token') as f:
            token = f.read().strip()
    except Exception:
        pass
    headers = {'Authorization': 'Bearer ' + token, 'x-mlflow-workspace': workspace}
    try:
        url = uri + '/api/2.0/mlflow/experiments/get-by-name?experiment_name=' + experiment
        req = urllib.request.Request(url, headers=headers)
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        data = json.loads(resp.read())
        exp_id = data.get('experiment', {}).get('experiment_id', '')
        lifecycle = data.get('experiment', {}).get('lifecycle_stage', '')
        if not exp_id:
            print('ERROR:experiment not found')
        elif lifecycle != 'active':
            print('WARN:experiment lifecycle=' + lifecycle)
        else:
            payload = json.dumps({'experiment_ids': [exp_id], 'max_results': 5}).encode()
            req2 = urllib.request.Request(uri + '/api/2.0/mlflow/runs/search', data=payload,
                headers={**headers, 'Content-Type': 'application/json'})
            resp2 = urllib.request.urlopen(req2, context=ctx, timeout=10)
            runs = json.loads(resp2.read()).get('runs', [])
            print('OK:' + exp_id + ':' + str(len(runs)))
    except urllib.error.HTTPError as e:
        print('ERROR:HTTP ' + str(e.code))
    except Exception as e:
        print('ERROR:' + str(e))
" 2>&1 | tail -1)

    case "$mlflow_result" in
      OK:*)
        local exp_info="${mlflow_result#OK:}"
        local exp_id="${exp_info%%:*}"
        local run_count="${exp_info##*:}"
        _pass "MLflow experiment 'mortgage-ai' active (id=${exp_id}) in workspace ${ns}"
        if [[ "$run_count" -gt 0 ]]; then
          _pass "MLflow tracing active - ${run_count}+ run(s) recorded"
        else
          _info "MLflow has no traces yet - chat with the app to generate traces"
        fi
        ;;
      SKIP:*)
        _skip "MLflow tracing - ${mlflow_result#SKIP:}"
        ;;
      WARN:*|ERROR:*)
        _fail "MLflow tracing check - ${mlflow_result#*:}"
        ;;
      *)
        _fail "MLflow tracing check - unexpected result" "$mlflow_result"
        ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Module 5: Agent Evaluations
# ---------------------------------------------------------------------------
check_module5() {
  local ns="$1"
  _section "Module 5: Agent Evaluations [${ns}]"

  check_ns_exists "$ns" "Module 5" || return

  # 5.1: DSPA CR
  if oc get datasciencepipelinesapplication dspa -n "$ns" --no-headers &>/dev/null; then
    _pass "DSPA CR 'dspa' exists in ${ns}"
  else
    _fail "DSPA CR 'dspa' not found in ${ns}"
  fi

  # 5.2: DSPA pods
  local dspa_pods=("ds-pipeline-dspa" "ds-pipeline-metadata-envoy-dspa" "ds-pipeline-metadata-grpc-dspa" "ds-pipeline-persistenceagent-dspa" "ds-pipeline-scheduledworkflow-dspa" "ds-pipeline-workflow-controller-dspa" "mariadb-dspa")
  local dspa_containers=(2 2 1 1 1 1 1)
  for i in "${!dspa_pods[@]}"; do
    check_pod_ready "$ns" "${dspa_pods[$i]}" "${dspa_containers[$i]}"
  done

  # 5.3: llm-credentials secret exists
  if oc get secret llm-credentials -n "$ns" --no-headers &>/dev/null; then
    _pass "Secret 'llm-credentials' exists in ${ns}"
  else
    _fail "Secret 'llm-credentials' not found in ${ns}"
    _skip "LLM endpoint reachability - cannot check without credentials"
    _skip "Notebook execution (evaluate_agent.ipynb) - verify manually in Jupyter"
    return
  fi

  # 5.4: LLM credentials populated
  local llm_url llm_key
  llm_url=$(oc get secret llm-credentials -n "$ns" -o jsonpath='{.data.LLM_BASE_URL}' 2>/dev/null | base64 -d 2>/dev/null)
  llm_key=$(oc get secret llm-credentials -n "$ns" -o jsonpath='{.data.LLM_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ -n "$llm_url" && -n "$llm_key" ]]; then
    _pass "LLM credentials populated (LLM_BASE_URL and LLM_API_KEY set)"
  elif [[ -n "$llm_url" ]]; then
    _fail "LLM_API_KEY is empty in llm-credentials secret"
  elif [[ -n "$llm_key" ]]; then
    _fail "LLM_BASE_URL is empty in llm-credentials secret"
  else
    _fail "LLM_BASE_URL and LLM_API_KEY both empty in llm-credentials secret"
  fi

  # 5.5: LLM endpoint reachable
  if [[ -n "$llm_url" ]]; then
    local llm_models_url="${llm_url%/}/models"
    local llm_http
    llm_http=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
      -H "Authorization: Bearer ${llm_key}" "$llm_models_url" 2>/dev/null)
    if [[ -n "$llm_http" && "$llm_http" != "000" && "$llm_http" -lt 500 ]]; then
      _pass "LLM endpoint reachable at ${llm_url} (HTTP ${llm_http})"
    else
      _fail "LLM endpoint unreachable at ${llm_url} (HTTP ${llm_http:-000})" "Chat and evaluations will fail without a working LLM"
    fi
  else
    _skip "LLM endpoint reachability - LLM_BASE_URL not set"
  fi

  # 5.6: Notebook execution
  _skip "Notebook execution (evaluate_agent.ipynb) - verify manually in Jupyter"
}

# ---------------------------------------------------------------------------
# Module 6: Dev to Production
# ---------------------------------------------------------------------------
check_module6() {
  local ns="$1"
  _section "Module 6: Dev to Production [${ns}]"

  check_ns_exists "$ns" "Module 6" || return

  # 6.1: DSPA pipeline route
  local ds_host
  ds_host=$(get_route_host "$ns" "ds-pipeline-dspa")
  if [[ -n "$ds_host" ]]; then
    check_http "https://${ds_host}/" "DSPA pipeline route accessible" "200,302,401,403"
  else
    _fail "DSPA pipeline route not found in ${ns}"
  fi

  # 6.2: Pipeline execution
  _skip "Pipeline import and execution - verify manually in RHOAI console"

  # 6.3: Regression notebook
  _skip "Regression notebook (evaluate_agent_v2.ipynb) - verify manually in Jupyter"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - START_TIME))

  echo ""
  echo "======================================================================"
  echo "  VALIDATION SUMMARY"
  echo "======================================================================"
  echo ""
  echo "  Users validated:  ${USER_COUNT}"
  echo "  Modules checked:  1-6"
  echo "  Duration:         ${duration}s"
  echo ""
  if [[ "$USE_COLOR" == "true" ]]; then
    printf '  \033[32mPASS:  %s\033[0m\n' "$PASS_COUNT"
    printf '  \033[31mFAIL:  %s\033[0m\n' "$FAIL_COUNT"
    printf '  \033[33mSKIP:  %s\033[0m\n' "$SKIP_COUNT"
  else
    printf '  PASS:  %s\n' "$PASS_COUNT"
    printf '  FAIL:  %s\n' "$FAIL_COUNT"
    printf '  SKIP:  %s\n' "$SKIP_COUNT"
  fi
  echo "  TOTAL: ${total}"
  echo ""
  if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ "$USE_COLOR" == "true" ]]; then
      printf '  \033[32mResult: ALL CHECKS PASSED\033[0m\n'
    else
      echo "  Result: ALL CHECKS PASSED"
    fi
  else
    if [[ "$USE_COLOR" == "true" ]]; then
      printf '  \033[31mResult: %s CHECK(S) FAILED\033[0m\n' "$FAIL_COUNT"
    else
      printf '  Result: %s CHECK(S) FAILED\n' "$FAIL_COUNT"
    fi
  fi
  echo "======================================================================"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
  echo "======================================================================"
  echo "  AgentOps in Production - Lab Runner"
  echo "  Workshop Environment Validator"
  echo "======================================================================"
  echo ""
  echo "  Cluster:    ${API_URL}"
  echo "  Username:   ${USERNAME}"
  echo "  Users:      ${USER_PREFIX}1..${USER_PREFIX}${USER_COUNT}"
  if [[ -n "$SKIP_MODULES" ]]; then
    echo "  Skipping:   Module(s) ${SKIP_MODULES}"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  for cmd in oc curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Error: '${cmd}' is required but not found in PATH"
      exit 1
    fi
  done

  START_TIME=$(date +%s)
  print_banner
  check_login

  if [[ "$SKIP_SINGLETON" != "true" ]]; then
    check_singleton_infra
  fi

  for n in $(seq 1 "$USER_COUNT"); do
    local user="${USER_PREFIX}${n}"
    local ns="wksp-${user}"

    # Invalidate pod cache when switching users
    _invalidate_pod_cache

    if [[ $USER_COUNT -gt 1 ]]; then
      echo ""
      echo "----------------------------------------------------------------------"
      echo "  Validating user: ${user} | namespace: ${ns}"
      echo "----------------------------------------------------------------------"
    fi

    should_skip_module 1 || check_module1 "$ns"
    should_skip_module 2 || check_module2
    should_skip_module 3 || check_module3 "$ns"
    should_skip_module 4 || check_module4 "$ns"
    should_skip_module 5 || check_module5 "$ns"
    should_skip_module 6 || check_module6 "$ns"
  done

  print_summary

  if [[ $FAIL_COUNT -eq 0 ]]; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
