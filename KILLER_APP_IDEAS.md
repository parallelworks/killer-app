# ParallelWorks Activate — Killer App Demo Workflow Ideas

## Goal

Create a turnkey, visually stunning demo workflow that showcases the unique power of the ParallelWorks Activate platform:

- **Multi-site orchestration** — Launch clusters across multiple clouds/sites and unify them
- **Multi-scheduler support** — Slurm, Kubernetes, Flux working together
- **Portable execution** — Same workflow runs anywhere
- **Spot instance economics** — Burst capacity with cost optimization
- **Real-time visualization** — Live plots/graphs served in the session interface (like TensorBoard in the medical fine-tuning workflow)
- **Governance & access control** — Different resources for different workloads
- **Turnkey experience** — Start clusters → run workflow → see results → shut down

---

## Idea 1: Multi-Cloud Burst Rendering (Recommended — Most Visual)

### Concept

Distribute a ray-tracing or scientific visualization render across GPU and CPU resources at multiple cloud sites. Tiles of the image render in parallel, assembling in real-time in the browser — each tile color-coded by which cloud rendered it.

### Why This is a Killer Demo

- **Immediately intuitive** — non-technical audiences understand "this piece came from AWS, that piece from Google"
- **Visually stunning** — the image assembles tile-by-tile in front of you
- **Exercises every platform capability** — multi-site, multi-scheduler, spot instances, fault tolerance, load balancing
- **Fast feedback** — results appear in seconds, not hours
- **Great template** — the pattern generalizes to any embarrassingly parallel workload

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ACTIVATE WORKFLOW                         │
│                                                             │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐               │
│  │  Site A   │   │  Site B   │   │  Site C   │   Resources  │
│  │ AWS GPU   │   │ GCP CPU   │   │ On-Prem   │              │
│  │ (Slurm)   │   │ (K8s)     │   │ (Flux)    │              │
│  └────┬──────┘   └────┬──────┘   └─────┬─────┘              │
│       │               │               │                     │
│       └───────────┬───┘───────────────┘                     │
│                   │                                         │
│           ┌───────▼────────┐                                │
│           │  Tile Broker    │  Distributes render tiles      │
│           │  (Controller)   │  across sites, tracks progress │
│           └───────┬────────┘                                │
│                   │                                         │
│           ┌───────▼────────┐                                │
│           │  Live Dashboard │  Assembles tiles, shows stats  │
│           │  (Session UI)   │  Cost, throughput, site map    │
│           └────────────────┘                                │
└─────────────────────────────────────────────────────────────┘
```

### Live Dashboard Components

1. **Tile Assembly View** — Image builds up tile-by-tile, each tile colored by source site
2. **Site Map** — World map showing active compute locations with throughput bars
3. **Cost Ticker** — Real-time cloud spend across providers
4. **Throughput Chart** — Tiles/second per site, stacked area chart
5. **Fault Tolerance Demo** — Kill a spot instance, watch tiles reassign automatically

### Workflow Steps (DAG)

```yaml
jobs:
  setup_sites:        # Start clusters on 2-3 cloud providers
  distribute_tiles:   # Break scene into tiles, assign to sites
  render:             # Parallel render across all sites (Slurm/K8s/Flux)
  assemble:           # Collect tiles, build final image
  dashboard:          # Live web dashboard showing progress
  teardown:           # Shut down clusters
```

### Renderer Options

| Renderer | Pros | Cons |
|----------|------|------|
| **Blender (Cycles)** | Beautiful output, well-known, GPU+CPU | Heavier setup |
| **POV-Ray** | Lightweight, CPU-only, easy to install | Less flashy |
| **OSPRay** | Scientific viz, Intel optimized | Niche |
| **Custom Python (Matplotlib 3D)** | Zero deps, easy to explain | Less impressive visually |
| **Mandelbrot/Fractal** | Trivially parallel, no deps, stunning | "Toy" feel |

**Recommendation:** Start with **Mandelbrot/fractal rendering** for the MVP (zero dependencies, trivially parallel, stunning visuals, easy to explain), then upgrade to **Blender Cycles** for production demos.

### Real-Time Visualization Stack

Use a lightweight web server (FastAPI or Node.js) served through the ACTIVATE session proxy:
- WebSocket connection pushes completed tiles to the browser
- Dashboard built with D3.js or Plotly for live charts
- Same pattern as TensorBoard in the medical fine-tuning workflow

---

## Idea 2: Unified HPC Cluster Fabric (Recommended — Most Technical)

### Concept

Spin up compute resources across 3+ cloud providers, join them into a single logical compute fabric, and run a real parallel benchmark (HPL/HPCG or a weather simulation) across the unified cluster. A live Grafana-style dashboard shows performance metrics from all sites.

### Why This is a Killer Demo

- **Directly demonstrates the platform's core value** — unified multi-cloud HPC
- **Impressive to HPC audiences** — running MPI across clouds is genuinely hard
- **Quantitative results** — FLOPS, latency, efficiency numbers tell a clear story
- **Shows governance** — different workloads routed to appropriate resources

### Architecture

```
┌──────────────────────────────────────────────────┐
│              UNIFIED CLUSTER FABRIC               │
│                                                  │
│  AWS Slurm ──┐                                   │
│  GCP K8s   ──┼── Flux Meta-Scheduler ── MPI Job  │
│  On-Prem   ──┘                                   │
│                                                  │
│  Live Grafana Dashboard:                         │
│  • Node topology (color = cloud)                 │
│  • FLOPS per site                                │
│  • Network latency heatmap                       │
│  • Job Gantt chart                               │
└──────────────────────────────────────────────────┘
```

### Workflow Steps

```yaml
jobs:
  start_clusters:      # Launch resources on 2-3 providers
  install_fabric:      # Install Flux/overlay network on all nodes
  join_cluster:        # Connect nodes into unified fabric
  run_benchmark:       # HPL, HPCG, or OSU micro-benchmarks
  run_application:     # Weather sim, molecular dynamics, etc.
  monitoring:          # Grafana + Prometheus dashboard session
  report:              # Generate performance comparison report
  teardown:            # Shut down all clusters
```

---

## Idea 3: Federated AI Training Pipeline

### Concept

Fine-tune a language model with preprocessing on CPU (Site A), training on GPU (Site B), and evaluation/inference served on GPU (Site C) — all orchestrated as a single workflow with live TensorBoard metrics.

### Why This is a Killer Demo

- **AI/ML is universally interesting** — everyone understands "training a model"
- **Natural multi-resource fit** — CPU for data, GPU for training, different GPU for serving
- **Builds on existing medical fine-tuning workflow** — proven pattern
- **TensorBoard integration already exists** — real-time viz is solved

### Architecture

```
Site A (CPU, Slurm)     Site B (GPU, K8s)      Site C (GPU, Flux)
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│ Data Prep    │──────▶│ Fine-Tune    │──────▶│ Eval/Serve   │
│ • Download   │       │ • QLoRA      │       │ • vLLM       │
│ • Tokenize   │       │ • TensorBoard│       │ • Benchmark  │
│ • Validate   │       │ • Checkpoint │       │ • Compare    │
└──────────────┘       └──────────────┘       └──────────────┘
```

---

## Idea 4: Cross-Cloud Monte Carlo Ensemble

### Concept

Run a massive Monte Carlo simulation (structural engineering, climate, or financial risk) across thousands of cores at multiple sites. Results stream in and convergence plots update live.

### Why This is a Killer Demo

- **Classic HPC workload** — well understood
- **Embarrassingly parallel** — perfect for multi-site distribution
- **Live convergence** — visually compelling as statistics stabilize
- **Spot instance showcase** — Monte Carlo is inherently fault-tolerant

### Live Visualization

- Histogram filling in real-time as samples complete
- Convergence plot (mean ± std vs. sample count)
- Per-site throughput bars
- Cost comparison: spot vs. on-demand

---

## Idea 5: AI-Powered Scientific Discovery Pipeline

### Concept

Multi-stage pipeline where each stage runs on the optimal resource type:
1. **Data generation** (CPU, Slurm) — Simulate or generate candidate data
2. **ML Screening** (GPU, K8s) — Score candidates with a trained model
3. **High-fidelity simulation** (GPU, Flux) — Run detailed sim on top candidates
4. **Results dashboard** (Session) — Interactive exploration of results

---

## Implementation Strategy

### Phase 1: MVP — Mandelbrot Burst Renderer (1-2 days)

Build the simplest possible version that demonstrates the core concepts:

1. **Workflow YAML** — Multi-resource input, DAG with parallel render jobs
2. **Render script** — Python Mandelbrot renderer, outputs tile PNG + metadata JSON
3. **Tile broker** — Simple script that distributes tile assignments across sites
4. **Dashboard** — FastAPI + HTML/JS page served via session proxy
   - Assembles tiles as they complete
   - Color-codes tiles by source site
   - Shows live throughput chart
5. **Run on 2 resources** — Start with 2 sites (e.g., AWS + on-prem or 2 different clusters)

### Phase 2: Polish — Production Demo (3-5 days)

- Add Blender rendering option for photorealistic output
- 3+ sites with mixed schedulers (Slurm + K8s + Flux)
- Spot instance integration with automatic failover
- Grafana monitoring overlay
- Load balancing with work-stealing
- One-click start/stop experience

### Phase 3: Expand — Additional Killer Apps

- Port the pattern to Monte Carlo, AI training, or cluster fabric demos
- Create a "demo suite" workflow that lets you pick which killer app to run

---

## Technical Patterns from Existing Workflows

Based on analysis of the medical fine-tuning, VLLM-RAG, desktop, and hello-world workflows:

### Session Proxy Pattern (for live dashboard)
```yaml
sessions:
  session:
    useTLS: false
    redirect: true
    # Dashboard served on this port, proxied through ACTIVATE UI
```

### Multi-Resource Input Pattern
```yaml
"on":
  execute:
    inputs:
      resource_site_a:
        type: compute-clusters
        label: "Site A (Primary)"
      resource_site_b:
        type: compute-clusters
        label: "Site B (Burst)"
```

### Job Scheduler Abstraction
```yaml
# Same job runs on Slurm or PBS or direct execution
steps:
  - uses: marketplace/job_runner/v4.0
    with:
      resource: ${{ inputs.resource }}
      slurm:
        partition: ${{ inputs.slurm.partition }}
        gres: ${{ inputs.slurm.gres }}
```

### Real-Time Service Pattern (from VLLM-RAG)
```yaml
# Start a web service, wait for it, connect session
jobs:
  run_service:
    steps:
      - uses: marketplace/job_runner/v4.0
  create_session:
    needs: [run_service]
    # Wait for port, update session metadata
```

---

## Decision Matrix

| Criteria | Burst Render | Cluster Fabric | AI Pipeline | Monte Carlo |
|----------|:---:|:---:|:---:|:---:|
| Visual Impact | ★★★★★ | ★★★☆☆ | ★★★★☆ | ★★★☆☆ |
| Ease of Implementation | ★★★★★ | ★★☆☆☆ | ★★★☆☆ | ★★★★☆ |
| Technical Impressiveness | ★★★☆☆ | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| Audience Breadth | ★★★★★ | ★★★☆☆ | ★★★★☆ | ★★★☆☆ |
| Platform Feature Coverage | ★★★★☆ | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| Demo Speed (time to wow) | ★★★★★ | ★★☆☆☆ | ★★★☆☆ | ★★★★☆ |
| **Total** | **27** | **21** | **23** | **20** |

**Winner: Multi-Cloud Burst Rendering** — Best combination of visual impact, implementation speed, and audience appeal.

---

## Next Steps

1. [ ] Build MVP Mandelbrot renderer (Python script)
2. [ ] Create workflow YAML with multi-resource inputs
3. [ ] Build live dashboard (FastAPI + WebSocket + D3.js)
4. [ ] Test on 2 resources (e.g., labcluster + a30gpuserver)
5. [ ] Add site color-coding and throughput charts
6. [ ] Polish for demo: one-click start, clean teardown
