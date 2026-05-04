#!/usr/bin/env bash
# mineru-batch: deploie MinerU et traite recursivement tous les PDFs d'un dossier.
# Pour chaque <chemin>/foo.pdf -> ecrit <chemin>/foo.md a cote (skip si deja la).
# Copie aussi les images extraites dans <chemin>/images/ pour que les liens markdown marchent.
#
# Usage:
#   ./mineru-batch.sh /chemin/vers/mon/dossier
#
# Pre-requis:
#   - Docker Desktop avec backend WSL2 (Windows) ou Docker natif (Linux)
#   - GPU NVIDIA + nvidia-container-toolkit (Compute Capability >= 7.0)
#   - 24GB+ VRAM recommande, 16GB minimum
#   - ~40GB disque pour l'image

set -uo pipefail

# Empeche Git Bash (MSYS) de convertir /workspace/... en C:/Program Files/Git/workspace/...
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# --- args ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input_folder> [--gpu N] [--backend hybrid-http-client|vlm-http-client]"
  echo "  GPU defaults to 0. Backend defaults to hybrid-http-client (rapide pour PDFs natifs)."
  exit 1
fi
INPUT_DIR="$1"; shift
INPUT_DIR="${INPUT_DIR%/}"  # strip trailing slash
[[ ! -d "$INPUT_DIR" ]] && { echo "[ERR] $INPUT_DIR introuvable"; exit 1; }
# Si chemin relatif, on le rend absolu via pwd (sans transformation pwd -W qui casse Docker Desktop sur Windows)
case "$INPUT_DIR" in
  /*|[A-Za-z]:*) ;;  # deja absolu (POSIX ou Windows-style)
  *) INPUT_DIR="$(cd "$INPUT_DIR" && pwd)" ;;
esac

GPU_ID="${GPU_ID:-0}"
BACKEND="${BACKEND:-hybrid-http-client}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu) GPU_ID="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    *) echo "Option inconnue: $1"; exit 1 ;;
  esac
done

# --- pre-checks ---
command -v docker >/dev/null || { echo "[ERR] docker requis dans PATH"; exit 1; }
docker info >/dev/null 2>&1 || { echo "[ERR] daemon Docker non joignable (Docker Desktop demarre ?)"; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || { echo "[ERR] cannot cd to $SCRIPT_DIR"; exit 1; }

# --- 1. build image si absente ---
if ! docker image inspect mineru:latest >/dev/null 2>&1; then
  echo "[*] Image mineru:latest absente. Build (~20-30 min, telecharge ~10GB modeles HF)..."
  docker build -t mineru:latest -f Dockerfile .
fi

# --- 2. start serveur (compose est idempotent : si INPUT_DIR/GPU_ID changent, il recree) ---
CONTAINER="mineru-openai-server"
export INPUT_DIR GPU_ID  # consommees par compose.yaml
echo "[*] docker compose up -d (input=$INPUT_DIR, GPU=$GPU_ID)..."
docker compose --profile openai-server up -d

# --- 3. attendre healthy ---
echo "[*] Attente health=healthy (warmup vLLM ~2-3 min au 1er start)..."
deadline=$(( $(date +%s) + 600 ))
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == "healthy" ]]; do
  [[ $(date +%s) -gt $deadline ]] && { echo "[ERR] timeout 10min sans healthy"; exit 1; }
  status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "?")
  echo "    health=$status"
  sleep 10
done
echo "[OK] serveur ready."

# --- 4. inventaire PDFs ---
mapfile -t PDFS < <(find "$INPUT_DIR" -type f -name "*.pdf")
total_pdfs=${#PDFS[@]}
[[ $total_pdfs -eq 0 ]] && { echo "[*] Aucun PDF trouve sous $INPUT_DIR"; exit 0; }
mapfile -t DIRS < <(for p in "${PDFS[@]}"; do echo "${p%/*}"; done | sort -u)
echo "[*] $total_pdfs PDFs dans ${#DIRS[@]} dossiers parents."

# --- 5. traitement ---
LOG="$SCRIPT_DIR/batch_$(date +%Y%m%d_%H%M%S).log"
echo "[*] Log detaille : $LOG"

ok=0; fail=0; skipped=0
START_TS=$(date +%s)

for hostdir in "${DIRS[@]}"; do
  rel="${hostdir#"$INPUT_DIR"}"; rel="${rel#/}"
  containerdir="/workspace/input${rel:+/$rel}"
  host_outdir="$SCRIPT_DIR/data/output${rel:+/$rel}"
  container_outdir="/workspace/output${rel:+/$rel}"

  shopt -s nullglob
  pdfs_here=("$hostdir"/*.pdf)
  shopt -u nullglob
  [[ ${#pdfs_here[@]} -eq 0 ]] && continue

  # skip si tous les .md existent
  need=false
  for pdf in "${pdfs_here[@]}"; do
    base=$(basename "$pdf" .pdf)
    [[ -f "$hostdir/$base.md" ]] || { need=true; break; }
  done
  if ! $need; then
    skipped=$((skipped + ${#pdfs_here[@]}))
    echo "[SKIP] ${rel:-/} (${#pdfs_here[@]} .md deja la)"
    continue
  fi

  ELAPSED=$(($(date +%s)-START_TS))
  echo "[$((ok+fail+1))] elapsed=${ELAPSED}s  ${rel:-/} (${#pdfs_here[@]} pdf)"
  mkdir -p "$host_outdir"

  {
    echo "===== ${rel:-/} ====="
    docker exec "$CONTAINER" mineru \
      -p "$containerdir" -o "$container_outdir" \
      -b "$BACKEND" -u http://localhost:30000
    echo "===== rc=$? ====="
  } >> "$LOG" 2>&1

  # distribute .md + images a cote du PDF source
  for pdf in "${pdfs_here[@]}"; do
    base=$(basename "$pdf" .pdf)
    md=$(find "$host_outdir/$base" -type f -name "$base.md" -print -quit 2>/dev/null)
    if [[ -n "$md" ]]; then
      cp "$md" "$hostdir/$base.md"
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "    [FAIL] $base.pdf (voir $LOG)"
    fi
    img_src=$(find "$host_outdir/$base" -type d -name "images" -print -quit 2>/dev/null)
    if [[ -n "$img_src" ]]; then
      shopt -s nullglob
      imgs=("$img_src"/*)
      shopt -u nullglob
      if [[ ${#imgs[@]} -gt 0 ]]; then
        mkdir -p "$hostdir/images"
        cp -n "${imgs[@]}" "$hostdir/images/" 2>/dev/null
      fi
    fi
  done
done

TOTAL_TIME=$(($(date +%s)-START_TS))
echo
echo "[DONE] $ok OK / $fail FAIL / $skipped SKIPPED sur $total_pdfs PDFs en ${TOTAL_TIME}s"
echo "       .md + images a cote des PDFs : $INPUT_DIR/<chemin>/<nom>.md"
echo "       Audit complet                : $SCRIPT_DIR/data/output/"
echo "       Log                          : $LOG"
echo
echo "Pour eteindre le serveur : docker compose --profile openai-server down"
