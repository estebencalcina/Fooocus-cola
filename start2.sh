#!/bin/bash
set -e

# Rutas
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

# Crear un entorno aislado.
# Se usa virtualenv porque python -m venv falla en este entorno con ensurepip.
if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "Creando entorno virtual para Fooocus..."

  rm -rf "$VENV_DIR"

  python3 -m pip install --no-cache-dir virtualenv
  python3 -m virtualenv --system-site-packages "$VENV_DIR"
fi

PYTHON="$VENV_DIR/bin/python"
PIP="$PYTHON -m pip"

echo "Actualizando herramientas de instalación..."
"$PYTHON" -m pip install --upgrade pip setuptools wheel

echo "Instalando dependencias de Fooocus..."
"$PYTHON" -m pip install --no-cache-dir -r requirements_versions.txt

# Corrige el problema de NumPy/CuPy.
echo "Ajustando NumPy y CuPy..."
"$PYTHON" -m pip uninstall -y numpy cupy cupy-cuda11x cupy-cuda12x || true

"$PYTHON" -m pip install --no-cache-dir --force-reinstall \
  numpy==1.26.4 \
  cupy-cuda12x==13.6.0

# Corrige incompatibilidades entre Fooocus, Gradio, FastAPI y Pydantic.
echo "Ajustando Gradio, FastAPI, Starlette y Pydantic..."

"$PYTHON" -m pip uninstall -y \
  gradio \
  gradio-client \
  fastapi \
  starlette \
  pydantic \
  pydantic-core \
  jinja2 \
  uvicorn || true

"$PYTHON" -m pip install --no-cache-dir --force-reinstall \
  gradio==3.41.2 \
  gradio-client==0.5.0 \
  fastapi==0.103.2 \
  starlette==0.27.0 \
  pydantic==1.10.13 \
  jinja2==3.1.2 \
  uvicorn==0.23.2 \
  pyyaml==6.0.1 \
  httpx==0.27.0

# Preparar la carpeta de modelos
mkdir -p models/checkpoints-real-folder

MODEL_FOLDER="$FOOOCUS_DIR/models/checkpoints-real-folder"

if [ ! -f config.txt ]; then
  echo "{ \"path_checkpoints\": \"$MODEL_FOLDER\" }" > config.txt
else
  jq --arg new_value "$MODEL_FOLDER" \
    '.path_checkpoints = $new_value' config.txt > config_tmp.txt \
    && mv config_tmp.txt config.txt
fi

# Mantener los modelos descargados y crear el enlace requerido por Fooocus
if [ -d models/checkpoints ] && [ ! -L models/checkpoints ]; then
  echo "Moviendo modelos existentes..."
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
  --always-high-vram \
  > /content/fooocus.log 2>&1 &

echo "Esperando a Fooocus."
echo "La primera vez puede tardar bastante por la descarga de modelos grandes."

FOOOCUS_READY=0

# Espera máxima: 45 minutos
for i in $(seq 1 900); do

  if ! pgrep -f "entry_with_update.py" > /dev/null; then
    echo "Fooocus se cerró. Últimas líneas del registro:"
    tail -n 120 /content/fooocus.log
    exit 1
  fi

  if curl -s --max-time 3 http://127.0.0.1:7865/ > /dev/null; then
    FOOOCUS_READY=1
    echo "Fooocus está activo en el puerto 7865."
    break
  fi

  # Cada minuto muestra parte del registro
  if [ $((i % 20)) -eq 0 ]; then
    echo "Aún iniciando... $((i * 3)) segundos transcurridos."
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
echo "Creando túnel Cloudflare para Fooocus..."
cloudflared tunnel --url http://127.0.0.1:7865
