# Multi-stage build for production-ready HTTPS load balancer
FROM rust:1.70-alpine as builder

# Install build dependencies
RUN apk add --no-cache musl-dev openssl-dev

# Set working directory
WORKDIR /app

# Copy dependency files
COPY Cargo.toml Cargo.lock ./

# Create dummy main.rs to build dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release
RUN rm -rf src

# Copy source code
COPY src/ ./src/

# Build the application
RUN cargo build --release

# Production stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache ca-certificates tzdata

# Create non-root user
RUN addgroup -g 1001 -S loadbalancer && \
    adduser -u 1001 -S loadbalancer -G loadbalancer

# Create necessary directories
RUN mkdir -p /etc/load-balancer/certs /var/log/load-balancer && \
    chown -R loadbalancer:loadbalancer /etc/load-balancer /var/log/load-balancer

# Copy binary from builder stage
COPY --from=builder /app/target/release/rust-load /usr/local/bin/
RUN chown loadbalancer:loadbalancer /usr/local/bin/rust-load

# Copy configuration
COPY config.toml /etc/load-balancer/
RUN chown loadbalancer:loadbalancer /etc/load-balancer/config.toml

# Switch to non-root user
USER loadbalancer

# Expose ports
EXPOSE 443 9090

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:9090/health || exit 1

# Default command
CMD ["rust-load", "--config", "/etc/load-balancer/config.toml"] 