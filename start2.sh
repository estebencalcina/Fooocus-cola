#!/bin/bash
set -e

# ============================================================
# Fooocus + entorno virtual + Cloudflare
# ============================================================

BASE_DIR="/content/Fooocus-cola"
FOOOCUS_DIR="$BASE_DIR/Fooocus"
VENV_DIR="/content/fooocus-venv"
LOG_FILE="/content/fooocus.log"
READY_FILE="$VENV_DIR/.fooocus_dependencies_ready"

cd "$BASE_DIR"

# ------------------------------------------------------------
# Descargar o actualizar Fooocus
# ------------------------------------------------------------
if [ ! -d "$FOOOCUS_DIR" ]; then
  echo "Descargando Fooocus..."
  git clone https://github.com/estebencalcina/Fooocus.git "$FOOOCUS_DIR"
else
  echo "Actualizando Fooocus..."
  cd "$FOOOCUS_DIR"
  git pull
fi

cd "$FOOOCUS_DIR"

# ------------------------------------------------------------
# Crear entorno virtual aislado
# Se usa virtualenv porque venv/ensurepip falla en este entorno.
# ------------------------------------------------------------
if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "Creando entorno virtual para Fooocus..."

  rm -rf "$VENV_DIR"

  python3 -m pip install --no-cache-dir virtualenv
  python3 -m virtualenv --system-site-packages "$VENV_DIR"
fi

PYTHON="$VENV_DIR/bin/python"
PIP="$PYTHON -m pip"

# ------------------------------------------------------------
# Instalar dependencias solo la primera vez
# Para reinstalar desde cero, borra:
# rm -rf /content/fooocus-venv
# ------------------------------------------------------------
if [ ! -f "$READY_FILE" ]; then
  echo "Instalando dependencias de Fooocus..."

  "$PYTHON" -m pip install --upgrade pip setuptools wheel

  # Dependencias oficiales del repositorio
  "$PYTHON" -m pip install --no-cache-dir -r requirements_versions.txt

  # Versiones compatibles con Python 3.12, Fooocus y Gradio 3
  # Pydantic 1 causa el error ForwardRef._evaluate().
  echo "Ajustando versiones de Gradio, FastAPI y Pydantic..."

  "$PYTHON" -m pip install --no-cache-dir --upgrade --force-reinstall \
    "numpy==1.26.4" \
    "gradio==3.41.2" \
    "gradio-client==0.5.0" \
    "fastapi==0.103.2" \
    "starlette==0.27.0" \
    "pydantic==2.7.4" \
    "pydantic-core==2.18.4" \
    "jinja2==3.1.2" \
    "uvicorn==0.23.2" \
    "httpx==0.27.0" \
    "pyyaml==6.0.1"

  touch "$READY_FILE"
else
  echo "Las dependencias ya están instaladas."
fi

# ------------------------------------------------------------
# Preparar carpetas de modelos
# ------------------------------------------------------------
mkdir -p models/checkpoints-real-folder
mkdir -p models/loras

MODEL_FOLDER="$FOOOCUS_DIR/models/checkpoints-real-folder"

cat > config.txt <<EOF
{
  "path_checkpoints": "$MODEL_FOLDER"
}
EOF

# Mantener el enlace que Fooocus espera para checkpoints
if [ -d models/checkpoints ] && [ ! -L models/checkpoints ]; then
  echo "Moviendo modelos existentes..."
  cp -a models/checkpoints/. models/checkpoints-real-folder/ 2>/dev/null || true
  rm -rf models/checkpoints
fi

if [ ! -L models/checkpoints ]; then
  ln -s models/checkpoints-real-folder models/checkpoints
fi

# ------------------------------------------------------------
# Cerrar procesos anteriores
# ------------------------------------------------------------
pkill -f "entry_with_update.py" 2>/dev/null || true
pkill -f "cloudflared tunnel --url.*7865" 2>/dev/null || true

# ------------------------------------------------------------
# Iniciar Fooocus
# ------------------------------------------------------------
echo "Iniciando Fooocus..."

nohup "$PYTHON" entry_with_update.py \
  --listen \
  --always-high-vram \
  > "$LOG_FILE" 2>&1 &

echo "Esperando a Fooocus..."
echo "Los modelos ya descargados no deberían volver a descargarse."

FOOOCUS_READY=0

# Máximo 30 minutos: 600 ciclos × 3 segundos
for i in $(seq 1 600); do

  # Si el proceso se cerró, mostrar el motivo
  if ! pgrep -f "entry_with_update.py" > /dev/null; then
    echo ""
    echo "Fooocus se cerró. Últimas líneas del registro:"
    tail -n 120 "$LOG_FILE"
    exit 1
  fi

  # Confirmar que Fooocus responde en el puerto 7865
  if curl -s --max-time 3 http://127.0.0.1:7865/ > /dev/null; then
    FOOOCUS_READY=1
    echo "Fooocus está activo en el puerto 7865."
    break
  fi

  # Mostrar progreso cada minuto
  if [ $((i % 20)) -eq 0 ]; then
    echo "Aún iniciando... $((i * 3)) segundos transcurridos."
    tail -n 8 "$LOG_FILE"
  fi

  sleep 3
done

if [ "$FOOOCUS_READY" -ne 1 ]; then
  echo ""
  echo "Fooocus no respondió dentro de 30 minutos."
  tail -n 120 "$LOG_FILE"
  exit 1
fi

echo ""
echo "Últimas líneas del registro de Fooocus:"
tail -n 40 "$LOG_FILE"

echo ""
echo "Creando túnel Cloudflare para Fooocus..."
cloudflared tunnel --url http://127.0.0.1:7865
