# Homelab Infrastructure

A fully containerized self-hosted infrastructure stack built with Docker Compose.

This repository contains the complete configuration for the homelab environment running on Ubuntu Server, including reverse proxying, automation services, AI workloads, dashboards, and infrastructure tooling.

The entire setup is designed around a few core principles:

- reproducibility
- simplicity
- modularity
- infrastructure-as-code
- GPU-ready workloads
- long-term maintainability

---

# Overview

The infrastructure is organized into isolated Docker Compose stacks.

Each stack is grouped by responsibility and connected through shared Docker networks when required.

Current deployed services include:

| Service             | Purpose                                |
| ------------------- | -------------------------------------- |
| Homepage            | Central dashboard and service launcher |
| Nginx Proxy Manager | Reverse proxy and SSL management       |
| Forgejo             | Self-hosted Git service                |
| n8n                 | Workflow automation platform           |
| PostgreSQL          | Database backend for n8n               |
| Redis               | Queue/cache backend for n8n            |
| Ollama              | Local LLM runtime                      |
| Cloudflared         | Secure Cloudflare tunnel access        |
| Excalidraw          | Collaborative whiteboard               |

---

# Repository Structure

```text
.
├── stacks/
│   ├── core/
│   ├── automation/
│   ├── ai/
│   └── ...
├── volumes/
├── scripts/
├── .env
├── .env.example
└── README.md
```

## stacks/

Contains all Docker Compose definitions separated by infrastructure domain.

Each stack is intentionally isolated to:

- reduce coupling
- simplify maintenance
- allow independent deployments
- improve readability

## volumes/

Persistent application data.

All stateful services store their data here to preserve configuration and application state across container recreations.

## scripts/

Utility scripts for deployment, maintenance, backups, and automation.

## .env

Main environment configuration file.

Contains:

- image versions
- user/group IDs
- ports
- runtime configuration
- service environment variables

`.env.example` is included as a portable template.

---

# Infrastructure Design

## Docker Compose First

The entire environment is managed using Docker Compose instead of Kubernetes.

This decision prioritizes:

- operational simplicity
- fast recovery
- low overhead
- easier debugging
- lightweight management

The homelab is intentionally designed to remain understandable and maintainable without introducing unnecessary orchestration complexity.

---

# Networking

Services communicate through dedicated Docker bridge networks.

External exposure is handled through:

- Nginx Proxy Manager
- Cloudflare Tunnel

This architecture provides:

- centralized SSL termination
- secure external access
- simplified DNS management
- internal service isolation

---

# GPU Support

GPU acceleration support is enabled for compatible services.

The infrastructure currently includes NVIDIA runtime support directly inside the Compose stack configuration.

This allows GPU-aware containers to:

- access CUDA workloads
- run local AI inference
- expose GPU telemetry
- support future observability integrations

Current Compose configuration includes:

```yaml
NVIDIA_VISIBLE_DEVICES: all
NVIDIA_DRIVER_CAPABILITIES: compute,utility
```

with Docker device reservations for NVIDIA runtime integration.

---

# Homepage Dashboard

Homepage acts as the central operational dashboard for the homelab.

It provides:

- service discovery
- quick access links
- infrastructure organization
- operational visibility
- centralized entrypoint for daily management

The dashboard is designed to become the single control surface for the entire infrastructure.

---

# Automation Stack

## n8n

n8n is used as the primary automation platform.

Current architecture includes:

- PostgreSQL backend
- Redis backend
- persistent workflows
- isolated Compose deployment

This provides a stable foundation for:

- infrastructure automation
- scheduled jobs
- AI workflows
- API integrations
- internal tooling

---

# AI Stack

## Ollama

Ollama provides local LLM execution capabilities.

The service is designed to:

- leverage local GPU acceleration
- support local-first AI workloads
- avoid dependency on external providers
- integrate with automation pipelines

The infrastructure is intentionally prepared for future AI-oriented services and experimentation.

---

# Security Approach

The infrastructure follows a pragmatic self-hosting security model.

Key decisions include:

- minimal public exposure
- Cloudflare Tunnel integration
- reverse proxy centralization
- isolated container networking
- environment-based configuration
- controlled image versioning

Sensitive values are intentionally separated from repository-tracked files.

---

# Deployment

Typical deployment flow:

```bash
cp .env.example .env

# Edit environment variables
nano .env

# Deploy core stack
cd stacks/core
sudo docker compose up -d
```

Additional stacks can then be started independently.

---

# Updating Services

Service versions are centralized inside `.env`.

This allows controlled upgrades without modifying Compose definitions.

Typical update flow:

```bash
# Pull updated images
sudo docker compose pull

# Recreate containers
sudo docker compose up -d
```

---

# Maintenance Philosophy

This repository is maintained with a focus on:

- clean configuration
- explicit infrastructure decisions
- deterministic deployments
- reduced technical debt
- long-term maintainability

Every stack is expected to remain:

- understandable
- replaceable
- independently deployable

---

# Current Focus

## Ubuntu Server 26 LTS Migration

The next major infrastructure milestone is upgrading the host system to Ubuntu Server 26 LTS.

Planned objectives include:

- validating Docker compatibility
- validating NVIDIA runtime compatibility
- improving long-term platform stability
- preparing enhanced observability support

A key upcoming improvement is the integration of live GPU monitoring directly inside Homepage.

This will provide:

- GPU utilization visibility
- VRAM monitoring
- runtime health checks
- AI workload awareness

directly from the main dashboard.

---

# Philosophy

This homelab is intentionally built as a clean, modular, production-style self-hosted environment.

The goal is not simply running containers, but maintaining:

- a reliable infrastructure base
- reproducible deployments
- operational visibility
- scalable self-hosted services
- local-first AI capabilities

All infrastructure decisions prioritize clarity and maintainability over unnecessary complexity.
