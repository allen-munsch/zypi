```yaml
# docker-compose.yml
# ZTEE Multi-Tenant Architecture
# Zero-Trust Execution Environment for Enterprise Agentic AI
#
# Uses:
# - Bifrost: https://github.com/maximhq/bifrost
# - Invariant Gateway: https://github.com/invariantlabs-ai/invariant-gateway
# - YAS-MCP: https://github.com/allen-munsch/yas-mcp
# - Zypi: Elixir/Firecracker orchestration

version: "3.8"

services:
  # ============================================================================
  # TIER 0: INFRASTRUCTURE
  # ============================================================================
  
  postgres:
    image: postgres:16-alpine
    container_name: ztee-postgres
    environment:
      POSTGRES_USER: ztee
      POSTGRES_PASSWORD: ztee_secret
      POSTGRES_DB: ztee
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ztee"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - ztee_internal
    ports:
      - "5432:5432"

  redis:
    image: redis:7-alpine
    container_name: ztee-redis
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - ztee_internal
    ports:
      - "6379:6379"

  # ============================================================================
  # TIER 1: DMZ - PUBLIC FACING
  # ============================================================================

  nginx:
    image: nginx:alpine
    container_name: ztee-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - bifrost
      - yas-mcp
      - invariant
    networks:
      - ztee_dmz
      - ztee_internal

  # YAS-MCP - OpenAPI to MCP Server (Rust)
  # https://github.com/allen-munsch/yas-mcp
  yas-mcp:
    build:
      context: ./services/yas-mcp
      dockerfile: Dockerfile
    image: ztee/yas-mcp:latest
    container_name: ztee-yas-mcp
    environment:
      RUST_LOG: info
      YAS_MCP_PORT: "3000"
    volumes:
      - ./specs/public:/specs:ro
    ports:
      - "3000:3000"
    networks:
      - ztee_dmz
      - ztee_internal

  # ============================================================================
  # TIER 2: APPLICATION ZONE - BIFROST LLM GATEWAY
  # ============================================================================

  # Bifrost - Multi-provider LLM Gateway
  # https://github.com/maximhq/bifrost
  #
  # Bifrost handles:
  # - Multi-provider routing (OpenAI, Anthropic, Bedrock, Vertex, etc.)
  # - Load balancing and fallbacks
  # - Request/response transformation
  # - Rate limiting
  #
  # We configure it with providers based on tenant tier
  bifrost:
    build:
      context: ./services/bifrost
      dockerfile: Dockerfile
    image: ztee/bifrost:latest
    container_name: ztee-bifrost
    environment:
      # Bifrost configuration via environment
      BIFROST_LOG_LEVEL: info
      BIFROST_PORT: "8080"
      
      # Provider API Keys (from .env or secrets)
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:-}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:-}
      AWS_REGION: ${AWS_REGION:-us-east-1}
      GOOGLE_APPLICATION_CREDENTIALS: /etc/bifrost/gcp-credentials.json
      
      # Ollama (local, always allowed)
      OLLAMA_BASE_URL: http://ollama:11434
      
      # Snowflake Cortex (PCI-preferred)
      SNOWFLAKE_ACCOUNT: ${SNOWFLAKE_ACCOUNT:-}
      SNOWFLAKE_USER: ${SNOWFLAKE_USER:-}
      SNOWFLAKE_PASSWORD: ${SNOWFLAKE_PASSWORD:-}
    volumes:
      - ./config/bifrost/config.yaml:/etc/bifrost/config.yaml:ro
      - ./config/bifrost/gcp-credentials.json:/etc/bifrost/gcp-credentials.json:ro
    ports:
      - "8080:8080"
    depends_on:
      redis:
        condition: service_healthy
      ollama:
        condition: service_started
    networks:
      - ztee_internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ============================================================================
  # TIER 3: INVARIANT GATEWAY - AI GUARDRAILS
  # ============================================================================

  # Invariant Gateway - AI Firewall & Policy Enforcement
  # https://github.com/invariantlabs-ai/invariant-gateway
  #
  # Invariant handles:
  # - Input guardrails (prompt injection, jailbreak detection)
  # - Output guardrails (PII/secrets detection, content filtering)
  # - Policy-based routing
  # - Audit logging with traces
  #
  # Sits between clients and Bifrost for policy enforcement
  invariant:
    build:
      context: ./services/invariant
      dockerfile: Dockerfile
    image: ztee/invariant:latest
    container_name: ztee-invariant
    environment:
      # Invariant configuration
      INVARIANT_LOG_LEVEL: info
      INVARIANT_PORT: "8000"
      
      # Backend LLM gateway (Bifrost)
      INVARIANT_BACKEND_URL: http://bifrost:8080
      
      # Database for traces/audit
      INVARIANT_DATABASE_URL: postgres://ztee:ztee_secret@postgres:5432/ztee
      
      # Redis for rate limiting
      INVARIANT_REDIS_URL: redis://redis:6379
      
      # Presidio integration for PII detection
      PRESIDIO_ANALYZER_URL: http://presidio-analyzer:5001
      PRESIDIO_ANONYMIZER_URL: http://presidio-anonymizer:5002
      
      # Explorer UI
      INVARIANT_EXPLORER_ENABLED: "true"
    volumes:
      - ./config/invariant/policies:/app/policies:ro
      - ./config/invariant/config.yaml:/app/config.yaml:ro
    ports:
      - "8000:8000"   # Gateway API
      - "8001:8001"   # Explorer UI
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      bifrost:
        condition: service_healthy
    networks:
      - ztee_internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ============================================================================
  # TIER 4: PII/PCI DETECTION - PRESIDIO
  # ============================================================================

  presidio-analyzer:
    image: mcr.microsoft.com/presidio-analyzer:latest
    container_name: ztee-presidio-analyzer
    ports:
      - "5001:5001"
    networks:
      - ztee_internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  presidio-anonymizer:
    image: mcr.microsoft.com/presidio-anonymizer:latest
    container_name: ztee-presidio-anonymizer
    ports:
      - "5002:5002"
    networks:
      - ztee_internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5002/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ============================================================================
  # TIER 5: LLM BACKENDS
  # ============================================================================

  # Ollama - Local LLM (always allowed for all tiers)
  ollama:
    image: ollama/ollama:latest
    container_name: ztee-ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0
    networks:
      - ztee_internal
    # Uncomment for GPU support
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  # ============================================================================
  # TIER 6: EXECUTION ZONE - ZYPI CLUSTERS
  # ============================================================================

  # Zypi Tier 2 - External Devs + Internal Users
  # YOLO mode enabled, all LLM backends via Invariant→Bifrost
  zypi-tier2:
    build:
      context: .
      dockerfile: Dockerfile
    image: zypi:latest
    container_name: ztee-zypi-tier2
    cgroup: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/kvm:/dev/kvm
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - zypi_tier2_data:/var/lib/zypi
      - zypi_tier2_overlaybd:/var/lib/overlaybd
      - ./config/overlaybd.json:/etc/overlaybd/overlaybd.json:ro
      - /dev:/dev
    environment:
      ZYPI_DATA_DIR: /var/lib/zypi
      ZYPI_KERNEL_PATH: /opt/zypi/kernel/vmlinux
      ZYPI_LOG_LEVEL: info
      ZYPI_API_PORT: "4000"
      ZYPI_CLUSTER_ID: tier2
      # LLM Gateway (goes through Invariant for guardrails)
      ZYPI_LLM_GATEWAY_URL: http://invariant:8000
      # Tier-specific settings
      ZYPI_TENANT_TIER: tier2
      ZYPI_YOLO_MODE_ENABLED: "true"
      ZYPI_PCI_SCOPE: "false"
      MIX_ENV: prod
    ports:
      - "4000:4000"
      - "4001:4001"
    networks:
      ztee_execution:
        ipv4_address: 172.30.0.10
      ztee_internal:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # Zypi PCI - Merchants
  # Governed agents only, restricted LLM backends, Presidio mandatory
  zypi-pci:
    build:
      context: .
      dockerfile: Dockerfile
    image: zypi:latest
    container_name: ztee-zypi-pci
    cgroup: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/kvm:/dev/kvm
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - zypi_pci_data:/var/lib/zypi
      - zypi_pci_overlaybd:/var/lib/overlaybd
      - ./config/overlaybd.json:/etc/overlaybd/overlaybd.json:ro
      - /dev:/dev
    environment:
      ZYPI_DATA_DIR: /var/lib/zypi
      ZYPI_KERNEL_PATH: /opt/zypi/kernel/vmlinux
      ZYPI_LOG_LEVEL: info
      ZYPI_API_PORT: "4000"
      ZYPI_CLUSTER_ID: pci
      # LLM Gateway (Invariant enforces PCI policies)
      ZYPI_LLM_GATEWAY_URL: http://invariant:8000
      # PCI-specific settings
      ZYPI_TENANT_TIER: pci
      ZYPI_YOLO_MODE_ENABLED: "false"
      ZYPI_PCI_SCOPE: "true"
      ZYPI_PRESIDIO_REQUIRED: "true"
      MIX_ENV: prod
    ports:
      - "4010:4000"
      - "4011:4001"
    networks:
      ztee_pci:
        ipv4_address: 172.31.0.10
      ztee_internal:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # Zypi Sanctum - Inner Sanctum
  # Human-in-the-loop required, full audit, session recording
  zypi-sanctum:
    build:
      context: .
      dockerfile: Dockerfile
    image: zypi:latest
    container_name: ztee-zypi-sanctum
    cgroup: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/kvm:/dev/kvm
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - zypi_sanctum_data:/var/lib/zypi
      - zypi_sanctum_overlaybd:/var/lib/overlaybd
      - ./config/overlaybd.json:/etc/overlaybd/overlaybd.json:ro
      - /dev:/dev
      - zypi_sanctum_recordings:/var/log/zypi/recordings
    environment:
      ZYPI_DATA_DIR: /var/lib/zypi
      ZYPI_KERNEL_PATH: /opt/zypi/kernel/vmlinux
      ZYPI_LOG_LEVEL: debug
      ZYPI_API_PORT: "4000"
      ZYPI_CLUSTER_ID: sanctum
      # LLM Gateway
      ZYPI_LLM_GATEWAY_URL: http://invariant:8000
      # Inner Sanctum settings
      ZYPI_TENANT_TIER: sanctum
      ZYPI_YOLO_MODE_ENABLED: "false"
      ZYPI_PCI_SCOPE: "true"
      ZYPI_PRESIDIO_REQUIRED: "true"
      ZYPI_HITL_REQUIRED: "true"
      ZYPI_SESSION_RECORDING: "true"
      MIX_ENV: prod
    ports:
      - "4020:4000"
      - "4021:4001"
    networks:
      ztee_sanctum:
        ipv4_address: 172.32.0.10
      ztee_internal:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ============================================================================
  # TIER 7: SUPPORTING SERVICES
  # ============================================================================

  # Audit Service - Lightweight service for compliance logging
  # Receives events from Invariant and Zypi
  audit:
    build:
      context: ./services/audit
      dockerfile: Dockerfile
    image: ztee/audit:latest
    container_name: ztee-audit
    environment:
      AUDIT_PORT: "8082"
      AUDIT_DATABASE_URL: postgres://ztee:ztee_secret@postgres:5432/ztee
      AUDIT_LOG_PATH: /var/log/ztee/audit.jsonl
    ports:
      - "8082:8082"
    volumes:
      - audit_logs:/var/log/ztee
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - ztee_internal

  # Provenance Service - Image signature verification
  provenance:
    build:
      context: ./services/provenance
      dockerfile: Dockerfile
    image: ztee/provenance:latest
    container_name: ztee-provenance
    environment:
      PROVENANCE_PORT: "8083"
      PROVENANCE_DATABASE_URL: postgres://ztee:ztee_secret@postgres:5432/ztee
    ports:
      - "8083:8083"
    volumes:
      - ./keys:/keys:ro
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - ztee_internal

# ============================================================================
# NETWORKS
# ============================================================================

networks:
  ztee_dmz:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24

  ztee_internal:
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.0.0/24

  ztee_execution:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.30.0.0/24

  ztee_pci:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.31.0.0/24

  ztee_sanctum:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.32.0.0/24

# ============================================================================
# VOLUMES
# ============================================================================

volumes:
  postgres_data:
  redis_data:
  ollama_data:
  audit_logs:
  zypi_tier2_data:
  zypi_tier2_overlaybd:
  zypi_pci_data:
  zypi_pci_overlaybd:
  zypi_sanctum_data:
  zypi_sanctum_overlaybd:
  zypi_sanctum_recordings:
```

Now the Dockerfiles that use the actual repos:

**services/bifrost/Dockerfile** - Building from the real Bifrost repo:

```dockerfile
# services/bifrost/Dockerfile
# Bifrost LLM Gateway
# https://github.com/maximhq/bifrost

FROM golang:1.22-alpine AS builder

WORKDIR /build

RUN apk add --no-cache git ca-certificates make

# Clone Bifrost
RUN git clone --depth 1 https://github.com/maximhq/bifrost.git .

# Build
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o bifrost ./cmd/bifrost

# Runtime
FROM alpine:3.19

RUN apk add --no-cache ca-certificates curl

WORKDIR /app

COPY --from=builder /build/bifrost /usr/local/bin/bifrost

# Create config directory
RUN mkdir -p /etc/bifrost

# Default config location
ENV BIFROST_CONFIG=/etc/bifrost/config.yaml

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

CMD ["bifrost", "serve"]
```

**services/invariant/Dockerfile** - Building from the real Invariant Gateway repo:

```dockerfile
# services/invariant/Dockerfile
# Invariant Gateway - AI Guardrails
# https://github.com/invariantlabs-ai/invariant-gateway

FROM python:3.11-slim-bookworm AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Clone Invariant Gateway
RUN git clone --depth 1 https://github.com/invariantlabs-ai/invariant-gateway.git .

# Install dependencies
RUN pip install --no-cache-dir poetry && \
    poetry config virtualenvs.create false && \
    poetry install --no-dev --no-interaction --no-ansi

# Runtime
FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy installed packages and source
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /build /app

# Create directories
RUN mkdir -p /app/policies

ENV INVARIANT_PORT=8000

EXPOSE 8000 8001

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

# Run the gateway
CMD ["python", "-m", "gateway"]
```

**services/yas-mcp/Dockerfile** - Building from YAS-MCP repo:

```dockerfile
# services/yas-mcp/Dockerfile
# YAS-MCP: OpenAPI to MCP Server
# https://github.com/allen-munsch/yas-mcp

FROM rust:1.75-slim-bookworm AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

# Clone yas-mcp
RUN git clone --depth 1 https://github.com/allen-munsch/yas-mcp.git .

# Build release
RUN cargo build --release

# Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/yas-mcp /usr/local/bin/yas-mcp

RUN mkdir -p /specs

ENV RUST_LOG=info

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD curl -sf http://localhost:3000/health || exit 1

# YAS-MCP serves OpenAPI specs as MCP tools
CMD ["yas-mcp", "serve", "--port", "3000", "--spec-dir", "/specs"]
```

Now the configuration files:

**config/bifrost/config.yaml** - Bifrost provider configuration:

```yaml
# config/bifrost/config.yaml
# Bifrost LLM Gateway Configuration
# https://github.com/maximhq/bifrost

server:
  port: 8080
  host: "0.0.0.0"

logging:
  level: info
  format: json

# Provider configurations
providers:
  # Ollama - Local LLM (always available)
  ollama:
    type: ollama
    base_url: ${OLLAMA_BASE_URL:-http://ollama:11434}
    models:
      - llama3.2
      - codellama
      - mistral
    default_model: llama3.2

  # OpenAI
  openai:
    type: openai
    api_key: ${OPENAI_API_KEY}
    models:
      - gpt-4o
      - gpt-4o-mini
      - gpt-4-turbo
    default_model: gpt-4o-mini

  # Anthropic
  anthropic:
    type: anthropic
    api_key: ${ANTHROPIC_API_KEY}
    models:
      - claude-sonnet-4-20250514
      - claude-3-5-sonnet-20241022
      - claude-3-5-haiku-20241022
    default_model: claude-sonnet-4-20250514

  # AWS Bedrock
  bedrock:
    type: bedrock
    region: ${AWS_REGION:-us-east-1}
    models:
      - anthropic.claude-3-sonnet-20240229-v1:0
      - anthropic.claude-3-haiku-20240307-v1:0
      - amazon.titan-text-express-v1
    default_model: anthropic.claude-3-sonnet-20240229-v1:0

  # Google Vertex AI
  vertex:
    type: vertex
    project: ${GCP_PROJECT}
    location: ${GCP_LOCATION:-us-central1}
    models:
      - gemini-1.5-pro
      - gemini-1.5-flash
    default_model: gemini-1.5-flash

# Routing rules based on tenant tier (set via X-Tenant-Tier header)
routing:
  # Default route
  default:
    providers:
      - ollama
      - openai
      - anthropic
    strategy: fallback

  # PCI tier - restricted to local/sovereign providers
  pci:
    providers:
      - ollama
    strategy: primary
    # Cortex would be added here when configured

  # Inner Sanctum - most restricted
  sanctum:
    providers:
      - ollama
    strategy: primary

  # Tier 2 - all providers allowed
  tier2:
    providers:
      - ollama
      - openai
      - anthropic
      - bedrock
      - vertex
    strategy: fallback

# Rate limiting
rate_limiting:
  enabled: true
  redis_url: ${REDIS_URL:-redis://redis:6379}
  default_limit: 100  # requests per minute
  
# Health check
health:
  enabled: true
  path: /health
```

**config/invariant/config.yaml** - Invariant Gateway configuration:

```yaml
# config/invariant/config.yaml
# Invariant Gateway Configuration
# https://github.com/invariantlabs-ai/invariant-gateway

server:
  port: 8000
  host: "0.0.0.0"

# Explorer UI for viewing traces
explorer:
  enabled: true
  port: 8001

# Backend LLM gateway (Bifrost)
backend:
  url: ${INVARIANT_BACKEND_URL:-http://bifrost:8080}
  timeout: 300

# Database for traces
database:
  url: ${INVARIANT_DATABASE_URL:-postgres://ztee:ztee_secret@postgres:5432/ztee}

# Redis for caching/rate limiting  
redis:
  url: ${INVARIANT_REDIS_URL:-redis://redis:6379}

# Logging
logging:
  level: info
  format: json

# Guardrail policies
policies:
  # Load policies from directory
  directory: /app/policies
  
  # Default policy for all requests
  default:
    input:
      - prompt_injection
      - jailbreak_detection
    output:
      - pii_detection
      - secrets_detection

# Presidio integration for PII/PCI detection
presidio:
  analyzer_url: ${PRESIDIO_ANALYZER_URL:-http://presidio-analyzer:5001}
  anonymizer_url: ${PRESIDIO_ANONYMIZER_URL:-http://presidio-anonymizer:5002}
  
  # Entities to detect
  entities:
    pii:
      - PERSON
      - EMAIL_ADDRESS
      - PHONE_NUMBER
      - US_SSN
      - IP_ADDRESS
      - LOCATION
    pci:
      - CREDIT_CARD
      - US_BANK_NUMBER
      - IBAN_CODE
      - CRYPTO

# Tracing
tracing:
  enabled: true
  # All requests are traced for audit
  sample_rate: 1.0
```

**config/invariant/policies/default.yaml** - Default guardrail policy:

```yaml
# config/invariant/policies/default.yaml
# Default guardrail policy for Tier 2 (External Devs + Internal)

name: default
description: Standard guardrails for general usage

# Input guardrails - applied to user prompts
input:
  rules:
    - name: prompt_injection
      enabled: true
      action: block
      
    - name: jailbreak_detection
      enabled: true
      action: block
      
    - name: harmful_content
      enabled: true
      action: block

# Output guardrails - applied to model responses
output:
  rules:
    - name: pii_detection
      enabled: true
      action: redact
      entities:
        - EMAIL_ADDRESS
        - PHONE_NUMBER
        - IP_ADDRESS
      
    - name: secrets_detection
      enabled: true
      action: redact
      patterns:
        - aws_access_key
        - github_token
        - api_key
```

**config/invariant/policies/pci.yaml** - PCI-scoped guardrail policy:

```yaml
# config/invariant/policies/pci.yaml
# PCI-scoped guardrails for Merchant tier

name: pci
description: Strict guardrails for PCI-scoped workloads

# Applies to requests with X-Tenant-Tier: pci
tenant_tier: pci

# Input guardrails
input:
  rules:
    - name: prompt_injection
      enabled: true
      action: block
      
    - name: jailbreak_detection
      enabled: true
      action: block
      
    - name: pci_data_in_prompt
      enabled: true
      action: block
      description: Block any PCI data in prompts
      entities:
        - CREDIT_CARD
        - US_BANK_NUMBER
        - IBAN_CODE

# Output guardrails  
output:
  rules:
    - name: pii_detection
      enabled: true
      action: redact
      entities:
        - PERSON
        - EMAIL_ADDRESS
        - PHONE_NUMBER
        - US_SSN
        - IP_ADDRESS
        - LOCATION
      
    - name: pci_detection
      enabled: true
      action: block  # Block, not just redact
      entities:
        - CREDIT_CARD
        - US_BANK_NUMBER
        - IBAN_CODE
        - CRYPTO
      
    - name: secrets_detection
      enabled: true
      action: redact

# Audit requirements
audit:
  log_all_requests: true
  log_all_responses: true
  include_content: false  # Don't log actual content for PCI
```

**config/invariant/policies/sanctum.yaml** - Inner Sanctum policy:

```yaml
# config/invariant/policies/sanctum.yaml
# Inner Sanctum guardrails - most restrictive

name: sanctum
description: Maximum security for Inner Sanctum access

tenant_tier: sanctum

# Human-in-the-loop required
approval:
  required: true
  approvers:
    - security-team
    - compliance-team

# Input guardrails
input:
  rules:
    - name: prompt_injection
      enabled: true
      action: block
      
    - name: jailbreak_detection
      enabled: true
      action: block
      
    - name: all_pii_pci
      enabled: true
      action: block
      description: Block ALL sensitive data in prompts

# Output guardrails
output:
  rules:
    - name: all_sensitive_data
      enabled: true
      action: block
      description: Block any sensitive data in outputs

# Full audit with session recording
audit:
  log_all_requests: true
  log_all_responses: true
  include_content: true  # Full content for audit
  session_recording: true
  retention_days: 2555  # 7 years for PCI
```

**config/nginx/conf.d/default.conf** - Updated nginx config routing through Invariant:

```nginx
# config/nginx/conf.d/default.conf

# Rate limiting
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/m;
limit_req_zone $http_x_api_key zone=api_key_limit:10m rate=100r/m;

# Upstreams
upstream invariant {
    server invariant:8000;
    keepalive 32;
}

upstream invariant_explorer {
    server invariant:8001;
    keepalive 16;
}

upstream yas_mcp {
    server yas-mcp:3000;
    keepalive 32;
}

upstream zypi_tier2 {
    server zypi-tier2:4000;
    keepalive 16;
}

upstream zypi_pci {
    server zypi-pci:4000;
    keepalive 16;
}

# MCP Public API
server {
    listen 80;
    server_name mcp.localhost mcp.*;

    limit_req zone=api_key_limit burst=20 nodelay;

    location / {
        proxy_pass http://yas_mcp;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Request-ID $request_id;
        proxy_set_header Connection '';
        proxy_buffering off;
    }
}

# Invariant Explorer UI
server {
    listen 80;
    server_name explorer.localhost explorer.*;

    location / {
        proxy_pass http://invariant_explorer;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

# Main API - Routes through Invariant for guardrails
server {
    listen 80 default_server;
    server_name api.localhost localhost;

    # LLM API - goes through Invariant guardrails
    location /v1/ {
        proxy_pass http://invariant;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Request-ID $request_id;
        proxy_set_header Connection '';
        
        # Pass tenant tier header for policy routing
        proxy_set_header X-Tenant-Tier $http_x_tenant_tier;
        
        proxy_read_timeout 300s;
    }

    # Zypi Tier 2 execution
    location /exec/tier2/ {
        rewrite ^/exec/tier2/(.*)$ /$1 break;
        proxy_pass http://zypi_tier2;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Request-ID $request_id;
        proxy_read_timeout 300s;
        client_max_body_size 500M;
    }

    # Zypi PCI execution
    location /exec/pci/ {
        rewrite ^/exec/pci/(.*)$ /$1 break;
        proxy_pass http://zypi_pci;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Request-ID $request_id;
        proxy_read_timeout 300s;
        client_max_body_size 500M;
    }


    # Health checks
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
```

Finally, the minimal Zypi hook to call the LLM gateway through Invariant:

**lib/zypi/gateway/llm_client.ex** - LLM Gateway client for Zypi:

```elixir
defmodule Zypi.Gateway.LLMClient do
  @moduledoc """
  Client for calling LLMs through the Invariant→Bifrost gateway.
  
  Routes requests through Invariant for guardrails, then to Bifrost for
  multi-provider LLM routing.
  """

  require Logger

  @gateway_url Application.compile_env(:zypi, :llm_gateway_url, "http://invariant:8000")
  @timeout 300_000  # 5 minutes for long completions

  defmodule CompletionRequest do
    defstruct [:model, :messages, :max_tokens, :temperature, :stream]
  end

  defmodule CompletionResponse do
    defstruct [:content, :model, :usage, :id]
  end

  @doc """
  Send a chat completion request through the gateway.
  
  The tenant tier is passed via header, which Invariant uses to select
  the appropriate guardrail policy.
  """
  def chat_completion(%CompletionRequest{} = request, opts \\ []) do
    tenant_tier = Keyword.get(opts, :tenant_tier, "tier2")
    request_id = Keyword.get(opts, :request_id, generate_request_id())

    body = %{
      model: request.model || default_model(tenant_tier),
      messages: request.messages,
      max_tokens: request.max_tokens || 1024,
      temperature: request.temperature || 0.7,
      stream: request.stream || false
    }

    headers = [
      {"Content-Type", "application/json"},
      {"X-Tenant-Tier", tenant_tier},
      {"X-Request-ID", request_id}
    ]

    url = "#{@gateway_url}/v1/chat/completions"

    case http_post(url, Jason.encode!(body), headers) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_completion_response(response_body)

      {:ok, %{status: 403, body: response_body}} ->
        # Guardrail blocked the request
        Logger.warning("LLM request blocked by guardrails: #{response_body}")
        {:error, {:guardrail_blocked, parse_error(response_body)}}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("LLM request failed: #{status} - #{response_body}")
        {:error, {:gateway_error, status, response_body}}

      {:error, reason} ->
        Logger.error("LLM request error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Simple completion helper for common use case.
  """
  def complete(prompt, opts \\ []) when is_binary(prompt) do
    request = %CompletionRequest{
      messages: [%{role: "user", content: prompt}],
      model: Keyword.get(opts, :model),
      max_tokens: Keyword.get(opts, :max_tokens),
      temperature: Keyword.get(opts, :temperature)
    }

    chat_completion(request, opts)
  end

  # Select default model based on tier
  defp default_model("pci"), do: "llama3.2"      # Ollama only
  defp default_model("sanctum"), do: "llama3.2" # Ollama only
  defp default_model(_), do: "gpt-4o-mini"       # OpenAI for tier2

  defp parse_completion_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = response} ->
        {:ok, %CompletionResponse{
          content: content,
          model: response["model"],
          usage: response["usage"],
          id: response["id"]
        }}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> body
    end
  end

  defp http_post(url, body, headers) do
    headers_charlist = Enum.map(headers, fn {k, v} -> 
      {String.to_charlist(k), String.to_charlist(v)} 
    end)

    case :httpc.request(
      :post,
      {String.to_charlist(url), headers_charlist, 'application/json', body},
      [{:timeout, @timeout}],
      []
    ) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: to_string(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

**lib/zypi/gateway/supervisor.ex**:

```elixir
defmodule Zypi.Gateway.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = []
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Now update **lib/zypi/application.ex** to include the gateway:

```elixir
# Add to children list in lib/zypi/application.ex

children = [
  Zypi.Store.Supervisor,
  Zypi.Pool.Supervisor,
  Zypi.Cluster.Supervisor,
  Zypi.Image.Supervisor,
  Zypi.Container.Supervisor,
  Zypi.Scheduler.Supervisor,
  Zypi.System.Cleanup,
  Zypi.Gateway.Supervisor,  # Add this line
  Zypi.API.Supervisor,
  Zypi.API.ConsoleSocket
]
```

And add config in **config/config.exs**:

```elixir
# ZTEE Gateway Configuration
config :zypi, :llm_gateway_url, 
  System.get_env("ZYPI_LLM_GATEWAY_URL", "http://invariant:8000")

config :zypi, :tenant_tier,
  System.get_env("ZYPI_TENANT_TIER", "tier2")
```

---

**Summary of the architecture:**

```
Internet → Nginx → ┬→ YAS-MCP (Public MCP API)
                   │
                   └→ Invariant Gateway (Guardrails)
                           │
                           ↓
                      Bifrost (LLM Router)
                           │
                   ┌───────┼───────┐
                   ↓       ↓       ↓
                Ollama  OpenAI  Anthropic  (etc.)


Execution:
                   ┌→ Zypi-Tier2 (YOLO mode, all providers)
Nginx → Invariant →┼→ Zypi-PCI (Governed, Ollama/Cortex only)
                   └→ Zypi-Sanctum (HITL, full audit)
```

The flow:
1. **Public API** → YAS-MCP converts OpenAPI specs to MCP tools
2. **LLM requests** → Invariant applies guardrails based on tenant tier → Bifrost routes to provider
3. **Execution** → Zypi clusters isolated by tier, each calling back to Invariant→Bifrost for LLM
