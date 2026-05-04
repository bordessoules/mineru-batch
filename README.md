# mineru-batch

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/bordessoules/mineru-batch/actions/workflows/ci.yml/badge.svg)](https://github.com/bordessoules/mineru-batch/actions/workflows/ci.yml)
[![Built on MinerU](https://img.shields.io/badge/built%20on-MinerU-blue)](https://github.com/opendatalab/MinerU)
[![vLLM](https://img.shields.io/badge/inference-vLLM-orange)](https://github.com/vllm-project/vllm)

Wrapper autour de [MinerU](https://github.com/opendatalab/MinerU) pour transformer **tous les PDFs d'une arborescence** en Markdown, en un appel.

```bash
./mineru-batch.sh /chemin/vers/mes/pdfs
```

À la fin, à côté de chaque `foo.pdf` :
- `foo.md` — le markdown extrait (UTF-8, tableaux HTML inline, titres `#`)
- `images/` — figures extraites, partagées entre tous les `.md` du dossier (hashes uniques)

Reprend où il s'est arrêté : tout PDF avec un `.md` voisin est skippé.

## Exemple de sortie

Une facture Bouygues Telecom (3 pages) → `Bouyguestelecom_Facture_20250716.md` (extrait) :

```markdown
Date de facture 16/07/2025

N° de facture 11014954620725

N° de ligne 06 66 56 55 07

Bonjour, voici votre facture du 16 juillet 2025

<table>
  <tr><td></td><td>€ HT</td><td>€ TTC(*)</td></tr>
  <tr><td>Montant prélevé le 31 juillet 2025</td><td></td><td>10,99</td></tr>
  <tr><td>Vos services fournis par votre opérateur</td><td>9,16</td><td>10,99</td></tr>
  <tr><td>TVA 20,00 % payée sur les débits</td><td></td><td>1,83</td></tr>
</table>

# Détail de votre facture du 16 juillet 2025

# Vos services fournis par votre opérateur

décomptées de vos forfaits
```

À retenir :
- **Tableaux HTML** structurés (colspan/rowspan préservés) → idéal pour parser les montants HT/TTC/TVA en aval
- **UTF-8 propre** : `€`, `°`, accents (é/à/è/ç/ô) tous corrects, zéro mojibake
- **Titres markdown** (`#`) pour la structure hiérarchique
- **Images** référencées en lien relatif `![](images/HASH.jpg)`

## Pourquoi

`pdfplumber` / `pymupdf` galèrent sur les factures, tickets, layouts complexes. MinerU sort un **VLM** (Vision-Language Model `MinerU2.5-Pro-2604-1.2B`, 95+ sur OmniDocBench) qui comprend la mise en page comme un humain.

L'astuce de ce wrapper : faire tourner **vLLM en serveur persistent** et appeler le CLI MinerU en mode `hybrid-http-client`. Le modèle est chargé en VRAM **une seule fois**, puis tous les PDFs sont processés à la chaîne.

## Pré-requis

- Docker Desktop (WSL2 sur Windows) ou Docker natif Linux
- GPU NVIDIA, Compute Capability ≥ 7.0 (Volta+), driver CUDA 12.9.1+
- 16 GB VRAM minimum, 24 GB recommandé
- ~40 GB de disque pour l'image (vLLM + modèles)
- `docker compose` v2

Vérifier le GPU passthrough :
```bash
docker run --rm --gpus all nvidia/cuda:12.9.1-base-ubuntu22.04 nvidia-smi
```

## Premier lancement

Le tout premier appel build l'image (~20-30 min, télécharge ~10 GB de modèles HF) puis démarre le serveur (warmup vLLM ~2-3 min). Les fois d'après, l'image est cache et seul le warmup serveur joue.

```bash
chmod +x mineru-batch.sh
./mineru-batch.sh ~/mes-factures
```

Sortie typique :
```
[*] Image mineru:latest absente. Build...
[*] Demarrage du serveur vLLM (GPU=0, input=/home/me/mes-factures)...
[*] Attente health=healthy...
[OK] serveur ready.
[*] 95 PDFs dans 12 dossiers parents.
[1] elapsed=0s  /
[2] elapsed=70s  bouygues-telecom.fr (24 pdf)
...
[DONE] 95 OK / 0 FAIL / 0 SKIPPED en 650s
```

## Options

```bash
./mineru-batch.sh <dossier>                            # GPU 0, backend hybrid (defaut)
./mineru-batch.sh <dossier> --gpu 1                    # cible la 2eme GPU
./mineru-batch.sh <dossier> --backend vlm-http-client  # VLM pur (plus lent, qualite max)
```

| Backend | Vitesse | Qualité | Quand l'utiliser |
|---|---|---|---|
| `hybrid-http-client` (défaut) | ~5 s/PDF | 95+ OmniDocBench | PDFs avec texte natif (factures, rapports) |
| `vlm-http-client` | ~15 s/PDF | 95+ OmniDocBench | PDFs scannés ou layouts très atypiques |

## Brancher un autre serveur OpenAI-compatible (LM Studio, OpenRouter, vLLM custom…)

Le mode `--remote URL` saute le serveur vLLM intégré et envoie les pages directement à un endpoint **OpenAI-compatible externe**. MinerU utilise simplement `/v1/chat/completions` avec `image_url` base64 — donc n'importe quel serveur respectant ce contrat marche, **avec un VLM moderne au choix** (Qwen3-VL, GLM-4.5V, InternVL3, GPT-4o, Claude, Gemini, etc.).

> **Trade-off** : le modèle par défaut `MinerU2.5-Pro-2604-1.2B` est fine-tuné spécifiquement pour la conversion de documents. Un VLM générique (même plus gros) peut être moins précis sur les tableaux complexes et les formules. Mais sur du texte courant et des layouts standards (factures, rapports), un Qwen3-VL ou GPT-4o donne des résultats au moins équivalents.

### LM Studio (local, GPU/CPU host)

1. Lance LM Studio, charge un VLM (ex. `Qwen2.5-VL-7B-Instruct` ou `MiniCPM-V-2.6`)
2. Démarre le serveur OpenAI-compat (port 1234 par défaut)
3. Lance le batch :

```bash
./mineru-batch.sh ~/factures \
  --remote http://host.docker.internal:1234/v1
```

(`host.docker.internal` est résolu automatiquement vers l'host depuis le container — fonctionne sur Docker Desktop et sur Linux via `--add-host=host-gateway` qu'on injecte.)

### Ollama (local)

```bash
ollama serve  # déjà fait par défaut
ollama pull qwen2.5-vl:7b
./mineru-batch.sh ~/factures --remote http://host.docker.internal:11434/v1
```

### OpenRouter (cloud, pas de GPU local)

```bash
./mineru-batch.sh ~/factures \
  --remote https://openrouter.ai/api/v1 \
  --model qwen/qwen3-vl-8b-instruct \
  --api-key sk-or-v1-xxxxx
```

Modèles VLM utiles sur OpenRouter : `qwen/qwen3-vl-*`, `anthropic/claude-sonnet-4.5`, `openai/gpt-4o`, `google/gemini-1.5-pro`, `meta-llama/llama-3.2-90b-vision-instruct`, `mistralai/pixtral-large-2411`.

### vLLM custom (autre VLM dans vLLM)

Pour servir un modèle plus gros que MinerU2.5-Pro-1.2B sur ta machine :

```bash
docker run -d --gpus all -p 8001:8000 \
  --ipc=host --name my-vllm \
  vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-VL-7B-Instruct \
  --max-model-len 8192

./mineru-batch.sh ~/factures --remote http://host.docker.internal:8001/v1
```

### Variables d'env supportées (équivalent flags)

| Flag | Env var | Effet |
|---|---|---|
| `--remote URL` | — | Mode endpoint externe |
| `--model NAME` | `MINERU_VL_MODEL_NAME` | Force le model name dans la requête |
| `--api-key KEY` | `MINERU_VL_API_KEY` | Header `Authorization: Bearer <key>` |
| `--gpu N` | `GPU_ID` | GPU pour le serveur local (mode défaut) |
| `--backend B` | `BACKEND` | `hybrid-http-client` (défaut) ou `vlm-http-client` |

## Reprise / ajout incrémental

Ajoute des PDFs n'importe où dans l'arbo, relance la même commande : seuls les nouveaux sont traités.

## Architecture

```
┌─────────────────┐         ┌──────────────────────────────────────┐
│  mineru-batch   │  HTTP   │  mineru-openai-server (container)    │
│   (host CLI)    │────────▶│  ┌──────────────┐  ┌──────────────┐  │
│                 │  :30000 │  │ vLLM engine  │  │  CLI mineru  │  │
│ find *.pdf      │         │  │ MinerU2.5-Pro│◀─│ (par batch)  │  │
│ docker exec ... │◀────────│  │ sur RTX 3090 │  │              │  │
└─────────────────┘         │  └──────────────┘  └──────────────┘  │
                            └──────────────────────────────────────┘
                                      ▲
                                      │ volume read-write
                            ┌─────────┴────────┐
                            │  /chemin/factures │  ← .pdf (in) / .md (out) / images/
                            └──────────────────┘
```

Le serveur reste up entre les batches. Pour l'éteindre :
```bash
docker compose --profile openai-server down
```

## Profils Docker compose disponibles

```bash
docker compose --profile openai-server up -d   # vLLM + CLI client (cas batch)
docker compose --profile gradio        up -d   # UI web sur :7860 (test interactif)
docker compose --profile api           up -d   # API REST MinerU sur :8000
docker compose --profile router        up -d   # routeur multi-workers sur :8002
```

Tu peux changer `INPUT_DIR` et `GPU_ID` via env :
```bash
INPUT_DIR=/data/pdfs GPU_ID=1 docker compose --profile gradio up -d
```

## Sortie complète

Pour chaque PDF, MinerU produit :
- Le `.md` (copié à côté du PDF source)
- `data/output/<chemin>/<basename>/hybrid_auto/` :
  - `<basename>.md`
  - `<basename>_layout.pdf` — PDF annoté avec les boxes layout détectées
  - `<basename>_origin.pdf` — copie de l'original
  - `<basename>_content_list.json` — éléments structurés (titre, paragraphe, table, image, formule)
  - `<basename>_middle.json` — représentation intermédiaire complète
  - `images/` — figures extraites

Pratique pour debug ou pour parser le contenu structuré dans un pipeline downstream.

## Crédits

- [MinerU](https://github.com/opendatalab/MinerU) — OpenDataLab
- [vLLM](https://github.com/vllm-project/vllm) — moteur d'inférence
