> **Licensing update (31 October 2026):** The current policy requires prior written permission for reuse and a separate agreement for AI training. See [LICENSE](LICENSE). Earlier grants remain valid for previously licensed material; [LICENSE.previous](LICENSE.previous) preserves those terms. Any older license descriptions below describe the previous policy. Contact [ei@nsisong.com](mailto:ei@nsisong.com).

# production https load balancer

a high-performance, enterprise-grade https load balancer built in rust with actix-web. designed for production environments with advanced features including tls termination, multiple load balancing algorithms, health monitoring, metrics, rate limiting, and session persistence.

## enterprise features

### load balancing algorithms
- **round robin** - distributes requests evenly across servers
- **weighted round robin** - distributes based on server capacity weights
- **least connections** - routes to server with fewest active connections
- **least response time** - routes to fastest responding server
- **ip hash** - consistent routing based on client ip
- **random** - random server selection

### security & tls
- **https/tls termination** - full tls 1.3 support with rustls
- **certificate management** - automatic certificate loading and validation
- **rate limiting** - per-client rate limiting with configurable thresholds
- **request validation** - comprehensive request sanitization

### monitoring & observability
- **prometheus metrics** - comprehensive metrics export
- **health checks** - configurable health check endpoints
- **structured logging** - json-formatted logs with tracing
- **real-time monitoring** - server status and performance metrics

### high availability
- **health monitoring** - automatic server health detection
- **failover support** - automatic removal of unhealthy servers
- **session persistence** - sticky sessions for stateful applications
- **connection pooling** - efficient connection management

### performance & scalability
- **async i/o** - non-blocking request handling
- **connection limits** - per-server connection throttling
- **timeout management** - configurable request timeouts
- **memory efficient** - optimized for high-throughput scenarios

## quick start

### prerequisites
- rust 1.70+ and cargo
- tls certificates (for https mode)
- backend servers to load balance

### installation

```bash
# clone the repository
git clone https://github.com/1cbyc/rust-http-load-balancer.git
cd rust-http-load-balancer

# build the project
cargo build --release

# run with default configuration
cargo run --release
```

### configuration

the load balancer uses toml configuration files. create a `config.toml`:

```toml
[load_balancer]
bind_address = "0.0.0.0"
bind_port = 443
algorithm = "RoundRobin"
enable_tls = true
cert_file = "certs/server.crt"
key_file = "certs/server.key"
enable_metrics = true
metrics_port = 9090

[[servers]]
address = "192.168.1.10"
port = 8080
weight = 1
max_connections = 1000
health_check_path = "/health"
```

### running in production

```bash
# run with custom config
cargo run --release -- --config production.toml

# run with verbose logging
cargo run --release -- --config production.toml --verbose

# run in docker
docker build -t rust-load-balancer .
docker run -p 443:443 -p 9090:9090 rust-load-balancer
```

## monitoring & metrics

### prometheus metrics

the load balancer exposes comprehensive metrics at `/metrics`:

- `total_requests` - total requests processed per server
- `failed_requests` - failed requests per server
- `active_connections` - current active connections per server
- `health_check_success` - successful health checks
- `health_check_failure` - failed health checks
- `request_duration` - request duration histograms
- `rate_limit_exceeded` - rate limit violations

### health check endpoint

```
get /health
```

returns:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-15t10:30:00z"
}
```

## configuration reference

### load balancer configuration

| setting | type | default | description |
|---------|------|---------|-------------|
| `bind_address` | string | "0.0.0.0" | ip address to bind to |
| `bind_port` | integer | 443 | port to listen on |
| `algorithm` | string | "roundrobin" | load balancing algorithm |
| `health_check_interval` | integer | 30 | health check interval (seconds) |
| `connection_timeout` | integer | 10 | connection timeout (seconds) |
| `enable_tls` | boolean | true | enable https/tls |
| `cert_file` | string | - | tls certificate file path |
| `key_file` | string | - | tls private key file path |
| `enable_metrics` | boolean | true | enable prometheus metrics |
| `metrics_port` | integer | 9090 | metrics server port |
| `enable_rate_limiting` | boolean | true | enable rate limiting |
| `rate_limit_per_second` | integer | 1000 | rate limit per client |
| `enable_sticky_sessions` | boolean | true | enable session persistence |

### server configuration

| setting | type | required | description |
|---------|------|----------|-------------|
| `address` | string | yes | server ip address |
| `port` | integer | yes | server port |
| `weight` | integer | yes | server weight for weighted algorithms |
| `max_connections` | integer | yes | maximum concurrent connections |
| `timeout` | integer | yes | request timeout (seconds) |
| `health_check_path` | string | yes | health check endpoint path |
| `health_check_interval` | integer | yes | health check interval (seconds) |

## deployment

### docker deployment

```dockerfile
from rust:1.70 as builder
workdir /app
copy . .
run cargo build --release

from debian:bullseye-slim
run apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
copy --from=builder /app/target/release/rust-load /usr/local/bin/
copy config.toml /etc/load-balancer/
copy certs/ /etc/load-balancer/certs/

expose 443 9090
cmd ["rust-load", "--config", "/etc/load-balancer/config.toml"]
```

### kubernetes deployment

```yaml
apiversion: apps/v1
kind: deployment
metadata:
  name: rust-load-balancer
spec:
  replicas: 3
  selector:
    matchlabels:
      app: rust-load-balancer
  template:
    metadata:
      labels:
        app: rust-load-balancer
    spec:
      containers:
      - name: load-balancer
        image: rust-load-balancer:latest
        ports:
        - containerport: 443
        - containerport: 9090
        volumemounts:
        - name: config
          mountpath: /etc/load-balancer
        - name: certs
          mountpath: /etc/load-balancer/certs
      volumes:
      - name: config
        configmap:
          name: load-balancer-config
      - name: certs
        secret:
          secretname: load-balancer-certs
```

## security considerations

### tls configuration
- use strong cipher suites (tls 1.3 recommended)
- regular certificate rotation
- private key protection
- certificate chain validation

### rate limiting
- configure appropriate rate limits per client
- monitor rate limit violations
- implement ip whitelisting for trusted clients

### network security
- use firewall rules to restrict access
- implement network segmentation
- monitor for suspicious traffic patterns

## performance tuning

### connection pooling
- adjust `max_connections` based on server capacity
- monitor connection pool utilization
- implement connection timeouts

### memory optimization
- configure appropriate buffer sizes
- monitor memory usage patterns
- implement memory limits

### cpu optimization
- use appropriate worker thread counts
- monitor cpu utilization
- implement cpu limits

## troubleshooting

### common issues

1. **certificate errors**
   - verify certificate file paths
   - check certificate validity
   - ensure proper file permissions

2. **health check failures**
   - verify backend server health endpoints
   - check network connectivity
   - review health check configuration

3. **rate limiting issues**
   - adjust rate limit thresholds
   - monitor client ip detection
   - review rate limiting logs

### debug mode

run with verbose logging for detailed debugging:

```bash
rust_log=debug cargo run -- --verbose
```

## contributing

1. fork the repository
2. create a feature branch
3. make your changes
4. add tests
5. submit a pull request

## license

this project is licensed under the mit license - see the [license](license) file for details.

## support

- **documentation**: [wiki](https://github.com/1cbyc/rust-http-load-balancer/wiki)
- **issues**: [github issues](https://github.com/1cbyc/rust-http-load-balancer/issues)
- **discussions**: [github discussions](https://github.com/1cbyc/rust-http-load-balancer/discussions)

---

**built with love in rust for production environments**
