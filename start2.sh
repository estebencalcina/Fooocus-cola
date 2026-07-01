#!/bin/bash
set -e

BASE_DIR="/content/Fooocus-cola"
FOOOCUS_DIR="$BASE_DIR/Fooocus"
VENV_DIR="/content/fooocus-venv"

cd "$BASE_DIR"

# Descargar o actualizar Fooocus
if [ ! -d "$FOOOCUS_DIR" ]; then
  echo "Descargando Fooocus..."
  git clone https://github.com/estebencalcina/Fooocus.git "$FOOOCUS_DIR"
else
  echo "Actualizando Fooocus..."
  cd "$FOOOCUS_DIR"
  git pull
fi

cd "$FOOOCUS_DIR"

# Crear entorno propio solo una vez.
# --system-site-packages permite usar Torch/CUDA ya disponibles en Colab.
if [ ! -d "$VENV_DIR" ]; then
  echo "Creando entorno virtual para Fooocus..."
  python3 -m venv --system-site-packages "$VENV_DIR"
fi

PYTHON="$VENV_DIR/bin/python"
PIP="$PYTHON -m pip"

echo "Actualizando pip..."
$PIP install --upgrade pip setuptools wheel

# Instalar dependencias de Fooocus en el entorno virtual
echo "Instalando dependencias de Fooocus..."
$PIP install --no-cache-dir -r requirements_versions.txt

# Corregir NumPy y CuPy
echo "Ajustando NumPy y CuPy..."
$PIP uninstall -y numpy cupy cupy-cuda11x cupy-cuda12x || true

$PIP install --no-cache-dir --force-reinstall \
  numpy==1.26.4 \
  cupy-cuda12x==13.6.0

# Versiones compatibles para Fooocus / Gradio antiguo
echo "Ajustando Gradio, FastAPI, Starlette y Pydantic..."
$PIP uninstall -y gradio fastapi starlette jinja2 uvicorn pydantic pydantic-core || true

$PIP install --no-cache-dir --force-reinstall \
  gradio==3.41.2 \
  fastapi==0.103.2 \
  starlette==0.27.0 \
  pydantic==1.10.13 \
  jinja2==3.1.2 \
  uvicorn==0.23.2 \
  pyyaml==6.0.1

# Carpeta para modelos
mkdir -p models/checkpoints-real-folder

MODEL_FOLDER="$FOOOCUS_DIR/models/checkpoints-real-folder"
echo "{ \"path_checkpoints\": \"$MODEL_FOLDER\" }" > config.txt

# Crear enlace de checkpoints sin borrar tus modelos descargados
if [ -d models/checkpoints ] && [ ! -L models/checkpoints ]; then
  cp -a models/checkpoints/. models/checkpoints-real-folder/ 2>/dev/null || true
  rm -rf models/checkpoints
fi

if [ ! -L models/checkpoints ]; then
  ln -s models/checkpoints-real-folder models/checkpoints
fi

# Cerrar procesos anteriores
pkill -f "entry_with_update.py" 2>/dev/null || true
pkill -f "cloudflared tunnel --url.*7865" 2>/dev/null || true

echo "Iniciando Fooocus..."

nohup "$PYTHON" entry_with_update.py \
  --listen \
  --share \
  --always-high-vram \
  > /content/fooocus.log 2>&1 &

echo "Esperando a Fooocus. La primera vez puede tardar 15 a 30 minutos por las descargas..."

FOOOCUS_READY=0

# 45 minutos máximos: 900 ciclos x 3 segundos
for i in $(seq 1 900); do

  if ! pgrep -f "entry_with_update.py" >/dev/null; then
    echo "Fooocus se cerró. Registro:"
    tail -n 100 /content/fooocus.log
    exit 1
  fi

  if curl -s --max-time 3 http://127.0.0.1:7865/ >/dev/null; then
    FOOOCUS_READY=1
    echo "Fooocus está activo."
    break
  fi

  if [ $((i % 20)) -eq 0 ]; then
    echo "Aún iniciando... $(($i * 3)) segundos transcurridos."
    tail -n 8 /content/fooocus.log
  fi

  sleep 3
done

if [ "$FOOOCUS_READY" -ne 1 ]; then
  echo "Fooocus no respondió dentro de 45 minutos."
  echo "Últimas líneas del registro:"
  tail -n 120 /content/fooocus.log
  exit 1
fi

echo ""
echo "Últimas líneas de Fooocus:"
tail -n 40 /content/fooocus.log

echo ""
echo "Creando enlace Cloudflare para Fooocus..."
cloudflared tunnel --url http://127.0.0.1:7865
