use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer, middleware, Error};
use actix_web::http::{StatusCode, header};
use awc::Client;
use serde::{Serialize, Deserialize};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::time;
use log::{info, error, warn, debug};
use tracing::{info_span, instrument};
use parking_lot::RwLock;
use dashmap::DashMap;
use futures::future::join_all;
use std::collections::HashMap;
use chrono::{DateTime, Utc};
use uuid::Uuid;
use metrics::{counter, gauge, histogram};
use std::path::PathBuf;
use clap::Parser;
use config::{Config, File};
use rustls::{ServerConfig, Certificate, PrivateKey};
use rustls_pemfile::{certs, pkcs8_private_keys};
use std::fs::File as StdFile;
use std::io::BufReader;

// Load balancing algorithms
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum LoadBalancingAlgorithm {
    RoundRobin,
    WeightedRoundRobin,
    LeastConnections,
    LeastResponseTime,
    IPHash,
    Random,
}

// Server health status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ServerStatus {
    Healthy,
    Unhealthy,
    Unknown,
}

// Backend server configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendServer {
    pub id: String,
    pub address: String,
    pub port: u16,
    pub weight: u32,
    pub max_connections: u32,
    pub timeout: Duration,
    pub health_check_path: String,
    pub health_check_interval: Duration,
    pub status: Arc<RwLock<ServerStatus>>,
    pub last_health_check: Arc<RwLock<DateTime<Utc>>>,
    pub active_connections: Arc<RwLock<u32>>,
    pub response_time: Arc<RwLock<Duration>>,
    pub total_requests: Arc<RwLock<u64>>,
    pub failed_requests: Arc<RwLock<u64>>,
}

impl BackendServer {
    pub fn new(
        address: String,
        port: u16,
        weight: u32,
        max_connections: u32,
        timeout: Duration,
        health_check_path: String,
        health_check_interval: Duration,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            address,
            port,
            weight,
            max_connections,
            timeout,
            health_check_path,
            health_check_interval,
            status: Arc::new(RwLock::new(ServerStatus::Unknown)),
            last_health_check: Arc::new(RwLock::new(Utc::now())),
            active_connections: Arc::new(RwLock::new(0)),
            response_time: Arc::new(RwLock::new(Duration::from_millis(0))),
            total_requests: Arc::new(RwLock::new(0)),
            failed_requests: Arc::new(RwLock::new(0)),
        }
    }

    pub fn get_url(&self) -> String {
        format!("http://{}:{}", self.address, self.port)
    }

    pub fn get_health_check_url(&self) -> String {
        format!("{}{}", self.get_url(), self.health_check_path)
    }

    pub async fn health_check(&self) -> bool {
        let client = Client::default();
        let url = self.get_health_check_url();
        
        let start = Instant::now();
        let response = client.get(&url).send().await;
        
        let response_time = start.elapsed();
        *self.response_time.write() = response_time;
        
        match response {
            Ok(resp) => {
                let is_healthy = resp.status().is_success();
                *self.status.write() = if is_healthy {
                    ServerStatus::Healthy
                } else {
                    ServerStatus::Unhealthy
                };
                *self.last_health_check.write() = Utc::now();
                
                if is_healthy {
                    counter!("health_check_success", 1, "server" => self.id.clone());
                } else {
                    counter!("health_check_failure", 1, "server" => self.id.clone());
                }
                
                histogram!("health_check_duration", response_time.as_millis() as f64, "server" => self.id.clone());
                is_healthy
            }
            Err(e) => {
                error!("Health check failed for {}: {}", self.get_url(), e);
                *self.status.write() = ServerStatus::Unhealthy;
                *self.last_health_check.write() = Utc::now();
                counter!("health_check_failure", 1, "server" => self.id.clone());
                false
            }
        }
    }

    pub fn can_accept_connection(&self) -> bool {
        let status = *self.status.read();
        let active_conns = *self.active_connections.read();
        
        matches!(status, ServerStatus::Healthy) && active_conns < self.max_connections
    }

    pub fn increment_connections(&self) {
        *self.active_connections.write() += 1;
        gauge!("active_connections", *self.active_connections.read() as f64, "server" => self.id.clone());
    }

    pub fn decrement_connections(&self) {
        *self.active_connections.write() -= 1;
        gauge!("active_connections", *self.active_connections.read() as f64, "server" => self.id.clone());
    }

    pub fn record_request(&self, success: bool) {
        *self.total_requests.write() += 1;
        if !success {
            *self.failed_requests.write() += 1;
        }
        
        counter!("total_requests", 1, "server" => self.id.clone());
        if !success {
            counter!("failed_requests", 1, "server" => self.id.clone());
        }
    }
}

// Load balancer configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoadBalancerConfig {
    pub bind_address: String,
    pub bind_port: u16,
    pub algorithm: LoadBalancingAlgorithm,
    pub health_check_interval: Duration,
    pub connection_timeout: Duration,
    pub read_timeout: Duration,
    pub write_timeout: Duration,
    pub max_connections: u32,
    pub enable_metrics: bool,
    pub metrics_port: u16,
    pub enable_tls: bool,
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub enable_rate_limiting: bool,
    pub rate_limit_per_second: u32,
    pub enable_sticky_sessions: bool,
    pub session_timeout: Duration,
}

impl Default for LoadBalancerConfig {
    fn default() -> Self {
        Self {
            bind_address: "0.0.0.0".to_string(),
            bind_port: 443,
            algorithm: LoadBalancingAlgorithm::RoundRobin,
            health_check_interval: Duration::from_secs(30),
            connection_timeout: Duration::from_secs(10),
            read_timeout: Duration::from_secs(30),
            write_timeout: Duration::from_secs(30),
            max_connections: 10000,
            enable_metrics: true,
            metrics_port: 9090,
            enable_tls: true,
            cert_file: None,
            key_file: None,
            enable_rate_limiting: true,
            rate_limit_per_second: 1000,
            enable_sticky_sessions: true,
            session_timeout: Duration::from_secs(3600),
        }
    }
}

// Rate limiter
#[derive(Debug)]
pub struct RateLimiter {
    requests: DashMap<String, Vec<Instant>>,
    max_requests: u32,
    window: Duration,
}

impl RateLimiter {
    pub fn new(max_requests: u32, window: Duration) -> Self {
        Self {
            requests: DashMap::new(),
            max_requests,
            window,
        }
    }

    pub fn is_allowed(&self, key: &str) -> bool {
        let now = Instant::now();
        let window_start = now - self.window;
        
        let mut requests = self.requests.entry(key.to_string()).or_insert_with(Vec::new);
        requests.retain(|&time| time > window_start);
        
        if requests.len() < self.max_requests as usize {
            requests.push(now);
            true
        } else {
            false
        }
    }
}

// Session manager for sticky sessions
#[derive(Debug)]
pub struct SessionManager {
    sessions: DashMap<String, String>, // client_id -> server_id
    last_access: DashMap<String, Instant>,
    timeout: Duration,
}

impl SessionManager {
    pub fn new(timeout: Duration) -> Self {
        Self {
            sessions: DashMap::new(),
            last_access: DashMap::new(),
            timeout,
        }
    }

    pub fn get_server_for_client(&self, client_id: &str) -> Option<String> {
        if let Some(server_id) = self.sessions.get(client_id) {
            if let Some(last_access) = self.last_access.get(client_id) {
                if last_access.elapsed() < self.timeout {
                    *self.last_access.get_mut(client_id).unwrap() = Instant::now();
                    return Some(server_id.clone());
                }
            }
        }
        None
    }

    pub fn set_server_for_client(&self, client_id: &str, server_id: &str) {
        self.sessions.insert(client_id.to_string(), server_id.to_string());
        self.last_access.insert(client_id.to_string(), Instant::now());
    }

    pub fn cleanup_expired_sessions(&self) {
        let now = Instant::now();
        self.last_access.retain(|client_id, last_access| {
            if now.duration_since(*last_access) > self.timeout {
                self.sessions.remove(client_id);
                false
            } else {
                true
            }
        });
    }
}

// Main load balancer
#[derive(Debug)]
pub struct LoadBalancer {
    servers: Arc<RwLock<Vec<BackendServer>>>,
    config: LoadBalancerConfig,
    current_index: Arc<RwLock<usize>>,
    rate_limiter: Arc<RateLimiter>,
    session_manager: Arc<SessionManager>,
    client: Client,
}

impl LoadBalancer {
    pub fn new(config: LoadBalancerConfig) -> Self {
        let client = Client::builder()
            .timeout(config.connection_timeout)
            .finish();

        Self {
            servers: Arc::new(RwLock::new(Vec::new())),
            config,
            current_index: Arc::new(RwLock::new(0)),
            rate_limiter: Arc::new(RateLimiter::new(
                self.config.rate_limit_per_second,
                Duration::from_secs(1),
            )),
            session_manager: Arc::new(SessionManager::new(self.config.session_timeout)),
            client,
        }
    }

    pub fn add_server(&self, server: BackendServer) {
        self.servers.write().push(server);
        info!("Added server: {}", server.get_url());
    }

    pub fn remove_server(&self, server_id: &str) {
        self.servers.write().retain(|s| s.id != server_id);
        info!("Removed server: {}", server_id);
    }

    pub fn get_healthy_servers(&self) -> Vec<BackendServer> {
        self.servers
            .read()
            .iter()
            .filter(|s| s.can_accept_connection())
            .cloned()
            .collect()
    }

    pub async fn select_server(&self, client_ip: &str) -> Option<BackendServer> {
        // Check for sticky session first
        if self.config.enable_sticky_sessions {
            if let Some(server_id) = self.session_manager.get_server_for_client(client_ip) {
                if let Some(server) = self.servers.read().iter().find(|s| s.id == server_id) {
                    if server.can_accept_connection() {
                        return Some(server.clone());
                    }
                }
            }
        }

        let healthy_servers = self.get_healthy_servers();
        if healthy_servers.is_empty() {
            return None;
        }

        let selected_server = match self.config.algorithm {
            LoadBalancingAlgorithm::RoundRobin => self.round_robin(&healthy_servers),
            LoadBalancingAlgorithm::WeightedRoundRobin => self.weighted_round_robin(&healthy_servers),
            LoadBalancingAlgorithm::LeastConnections => self.least_connections(&healthy_servers),
            LoadBalancingAlgorithm::LeastResponseTime => self.least_response_time(&healthy_servers),
            LoadBalancingAlgorithm::IPHash => self.ip_hash(&healthy_servers, client_ip),
            LoadBalancingAlgorithm::Random => self.random(&healthy_servers),
        };

        // Set sticky session if enabled
        if let Some(ref server) = selected_server {
            if self.config.enable_sticky_sessions {
                self.session_manager.set_server_for_client(client_ip, &server.id);
            }
        }

        selected_server
    }

    fn round_robin(&self, servers: &[BackendServer]) -> Option<BackendServer> {
        if servers.is_empty() {
            return None;
        }
        
        let mut index = self.current_index.write();
        let selected = servers[*index % servers.len()].clone();
        *index = (*index + 1) % servers.len();
        Some(selected)
    }

    fn weighted_round_robin(&self, servers: &[BackendServer]) -> Option<BackendServer> {
        if servers.is_empty() {
            return None;
        }

        let total_weight: u32 = servers.iter().map(|s| s.weight).sum();
        if total_weight == 0 {
            return self.round_robin(servers);
        }

        let mut index = self.current_index.write();
        let mut current_weight = 0;
        
        for server in servers {
            current_weight += server.weight;
            if *index < current_weight as usize {
                *index = (*index + 1) % total_weight as usize;
                return Some(server.clone());
            }
        }
        
        None
    }

    fn least_connections(&self, servers: &[BackendServer]) -> Option<BackendServer> {
        servers
            .iter()
            .min_by_key(|s| *s.active_connections.read())
            .cloned()
    }

    fn least_response_time(&self, servers: &[BackendServer]) -> Option<BackendServer> {
        servers
            .iter()
            .min_by_key(|s| *s.response_time.read())
            .cloned()
    }

    fn ip_hash(&self, servers: &[BackendServer], client_ip: &str) -> Option<BackendServer> {
        if servers.is_empty() {
            return None;
        }
        
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        
        let mut hasher = DefaultHasher::new();
        client_ip.hash(&mut hasher);
        let hash = hasher.finish();
        
        Some(servers[(hash as usize) % servers.len()].clone())
    }

    fn random(&self, servers: &[BackendServer]) -> Option<BackendServer> {
        if servers.is_empty() {
            return None;
        }
        
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let index = rng.gen_range(0..servers.len());
        Some(servers[index].clone())
    }

    pub async fn forward_request(
        &self,
        req: HttpRequest,
        body: web::Bytes,
    ) -> Result<HttpResponse, Error> {
        let client_ip = req.connection_info()
            .realip_remote_addr()
            .unwrap_or("unknown")
            .to_string();

        // Rate limiting
        if self.config.enable_rate_limiting {
            if !self.rate_limiter.is_allowed(&client_ip) {
                counter!("rate_limit_exceeded", 1);
                return Ok(HttpResponse::TooManyRequests()
                    .body("Rate limit exceeded"));
            }
        }

        // Select server
        let server = match self.select_server(&client_ip).await {
            Some(s) => s,
            None => {
                counter!("no_healthy_servers", 1);
                return Ok(HttpResponse::ServiceUnavailable()
                    .body("No healthy servers available"));
            }
        };

        // Increment connection count
        server.increment_connections();
        
        // Forward request
        let start = Instant::now();
        let result = self.forward_to_server(&server, req, body).await;
        let duration = start.elapsed();
        
        // Decrement connection count
        server.decrement_connections();
        
        // Record metrics
        let success = result.is_ok();
        server.record_request(success);
        histogram!("request_duration", duration.as_millis() as f64, "server" => server.id.clone());
        
        if success {
            counter!("requests_success", 1, "server" => server.id.clone());
        } else {
            counter!("requests_failed", 1, "server" => server.id.clone());
        }

        result
    }

    async fn forward_to_server(
        &self,
        server: &BackendServer,
        req: HttpRequest,
        body: web::Bytes,
    ) -> Result<HttpResponse, Error> {
        let url = format!("{}{}", server.get_url(), req.uri());
        
        let mut client_req = self.client.request_from(url, req.head());
        
        // Copy headers
        for (name, value) in req.headers() {
            if name != header::HOST {
                client_req.header(name, value);
            }
        }

        // Send request
        let response = client_req.send_body(body).await
            .map_err(|e| {
                error!("Failed to forward request to {}: {}", server.get_url(), e);
                actix_web::error::ErrorInternalServerError("Backend error")
            })?;

        // Build response
        let mut response_builder = HttpResponse::build(response.status());
        
        // Copy headers
        for (name, value) in response.headers() {
            response_builder.header(name, value);
        }

        // Get response body
        let body = response.body().await
            .map_err(|e| {
                error!("Failed to read response body from {}: {}", server.get_url(), e);
                actix_web::error::ErrorInternalServerError("Backend error")
            })?;

        Ok(response_builder.body(body))
    }

    pub async fn health_check_all(&self) {
        let servers = self.servers.read().clone();
        let health_futures: Vec<_> = servers.iter().map(|server| server.health_check()).collect();
        
        let results = join_all(health_futures).await;
        
        for (server, is_healthy) in servers.iter().zip(results) {
            if is_healthy {
                debug!("Server {} is healthy", server.get_url());
            } else {
                warn!("Server {} is unhealthy", server.get_url());
            }
        }
    }

    pub fn cleanup_sessions(&self) {
        self.session_manager.cleanup_expired_sessions();
    }
}

// Command line arguments
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, long, default_value = "config.toml")]
    config: String,
    
    #[arg(short, long)]
    verbose: bool,
}

// Load TLS configuration
fn load_tls_config(cert_file: &str, key_file: &str) -> Result<ServerConfig, Box<dyn std::error::Error>> {
    let cert_file = StdFile::open(cert_file)?;
    let key_file = StdFile::open(key_file)?;
    
    let mut cert_reader = BufReader::new(cert_file);
    let mut key_reader = BufReader::new(key_file);
    
    let certs: Vec<Certificate> = certs(&mut cert_reader)?
        .into_iter()
        .map(Certificate)
        .collect();
    
    let keys: Vec<PrivateKey> = pkcs8_private_keys(&mut key_reader)?
        .into_iter()
        .map(PrivateKey)
        .collect();
    
    if keys.is_empty() {
        return Err("No private keys found".into());
    }
    
    let config = ServerConfig::builder()
        .with_safe_defaults()
        .with_no_client_auth()
        .with_single_cert(certs, keys[0].clone())?;
    
    Ok(config)
}

// Request handler
async fn handle_request(
    lb: web::Data<Arc<LoadBalancer>>,
    req: HttpRequest,
    body: web::Bytes,
) -> Result<HttpResponse, Error> {
    lb.forward_request(req, body).await
}

// Health check endpoint
async fn health_check() -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({
        "status": "healthy",
        "timestamp": Utc::now().to_rfc3339()
    }))
}

// Metrics endpoint
async fn metrics() -> HttpResponse {
    use metrics_exporter_prometheus::PrometheusBuilder;
    
    let builder = PrometheusBuilder::new();
    let handle = builder.install_recorder().unwrap();
    
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(handle.render())
}

// Configuration loading
fn load_config(config_path: &str) -> Result<(LoadBalancerConfig, Vec<BackendServer>), Box<dyn std::error::Error>> {
    let settings = Config::builder()
        .add_source(File::with_name(config_path))
        .build()?;

    let config: LoadBalancerConfig = settings.get("load_balancer")?;
    let servers: Vec<BackendServer> = settings.get("servers")?;
    
    Ok((config, servers))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // Parse command line arguments
    let args = Args::parse();
    
    // Setup logging
    if args.verbose {
        std::env::set_var("RUST_LOG", "debug");
    } else {
        std::env::set_var("RUST_LOG", "info");
    }
    
    env_logger::init();
    tracing_subscriber::fmt::init();
    
    info!("Starting production HTTPS load balancer...");
    
    // Load configuration
    let (config, servers) = load_config(&args.config)
        .unwrap_or_else(|_| {
            warn!("Failed to load config file, using defaults");
            (LoadBalancerConfig::default(), Vec::new())
        });
    
    // Create load balancer
    let lb = Arc::new(LoadBalancer::new(config.clone()));
    
    // Add servers
    for server in servers {
        lb.add_server(server);
    }
    
    // Spawn health checker
    let lb_health = lb.clone();
    tokio::spawn(async move {
        let mut interval = time::interval(config.health_check_interval);
        loop {
            interval.tick().await;
            lb_health.health_check_all().await;
        }
    });
    
    // Spawn session cleanup
    let lb_cleanup = lb.clone();
    tokio::spawn(async move {
        let mut interval = time::interval(Duration::from_secs(300)); // Cleanup every 5 minutes
        loop {
            interval.tick().await;
            lb_cleanup.cleanup_sessions();
        }
    });
    
    // Start metrics server if enabled
    if config.enable_metrics {
        let metrics_addr = format!("{}:{}", config.bind_address, config.metrics_port);
        info!("Starting metrics server on {}", metrics_addr);
        
        tokio::spawn(async move {
            HttpServer::new(|| {
                App::new()
                    .route("/metrics", web::get().to(metrics))
            })
            .bind(&metrics_addr)
            .unwrap()
            .run()
            .await
        });
    }
    
    // Start main server
    let bind_addr = format!("{}:{}", config.bind_address, config.bind_port);
    info!("Starting load balancer on {}", bind_addr);
    
    let server = HttpServer::new(move || {
        App::new()
            .wrap(middleware::Logger::default())
            .app_data(web::Data::new(lb.clone()))
            .route("/health", web::get().to(health_check))
            .default_service(web::to(handle_request))
    });
    
    if config.enable_tls {
        if let (Some(cert_file), Some(key_file)) = (&config.cert_file, &config.key_file) {
            let tls_config = load_tls_config(cert_file, key_file)
                .expect("Failed to load TLS configuration");
            
            server
                .bind_rustls(&bind_addr, tls_config)?
                .run()
                .await?;
        } else {
            error!("TLS enabled but certificate or key file not specified");
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "TLS enabled but certificate or key file not specified"
            ));
        }
    } else {
        server
            .bind(&bind_addr)?
            .run()
            .await?;
    }
    
    Ok(())
}
