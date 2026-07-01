#!/bin/bash
set -e

# Carpeta principal
BASE_DIR="/content/Fooocus-cola"
FOOOCUS_DIR="$BASE_DIR/Fooocus"

# Usar el Python normal de Jupyter/Colab
PYTHON="python3"
PIP="python3 -m pip"

cd "$BASE_DIR"

# Descargar Fooocus solo si aún no existe
if [ ! -d "$FOOOCUS_DIR" ]; then
  echo "Descargando Fooocus..."
  git clone https://github.com/estebencalcina/Fooocus.git "$FOOOCUS_DIR"
else
  echo "Actualizando Fooocus..."
  cd "$FOOOCUS_DIR"
  git pull
fi

cd "$FOOOCUS_DIR"

# Instalar dependencias del proyecto
echo "Instalando dependencias de Fooocus..."
$PIP install --no-cache-dir -r requirements_versions.txt

# Corregir el conflicto de NumPy / CuPy
echo "Ajustando NumPy y CuPy..."
$PIP uninstall -y numpy cupy cupy-cuda11x cupy-cuda12x || true

$PIP install --no-cache-dir --force-reinstall \
  numpy==1.26.4 \
  cupy-cuda12x==13.6.0

# Fijar versiones compatibles de la interfaz web
# Corrige: TypeError: unhashable type: 'dict'
echo "Ajustando Gradio, FastAPI y Starlette..."
$PIP uninstall -y gradio fastapi starlette jinja2 uvicorn || true

$PIP install --no-cache-dir --force-reinstall \
  gradio==3.41.2 \
  fastapi==0.103.2 \
  starlette==0.27.0 \
  jinja2==3.1.2 \
  uvicorn==0.23.2

# Preparar carpeta de modelos
mkdir -p models/checkpoints-real-folder

MODEL_FOLDER="$FOOOCUS_DIR/models/checkpoints-real-folder"

# Crear o actualizar config.txt
if [ ! -f config.txt ]; then
  echo "{ \"path_checkpoints\": \"$MODEL_FOLDER\" }" > config.txt
else
  jq --arg new_value "$MODEL_FOLDER" \
    '.path_checkpoints = $new_value' config.txt > config_tmp.txt \
    && mv config_tmp.txt config.txt
fi

# Convertir checkpoints a enlace simbólico sin borrar modelos reales
if [ -d models/checkpoints ] && [ ! -L models/checkpoints ]; then
  echo "Moviendo modelos existentes..."
  cp -a models/checkpoints/. models/checkpoints-real-folder/ 2>/dev/null || true
  rm -rf models/checkpoints
fi

if [ ! -L models/checkpoints ]; then
  ln -s models/checkpoints-real-folder models/checkpoints
fi

# Cerrar instancias anteriores, si existen
pkill -f "entry_with_update.py" 2>/dev/null || true
pkill -f "cloudflared tunnel --url.*7865" 2>/dev/null || true

# Iniciar Fooocus
echo "Iniciando Fooocus..."

nohup $PYTHON entry_with_update.py \
  --listen \
  --share \
  --always-high-vram \
  > /content/fooocus.log 2>&1 &

# Esperar hasta que el puerto 7865 esté abierto
echo "Esperando a Fooocus..."

FOOOCUS_READY=0

for i in $(seq 1 120); do
  if $PYTHON -c "
import socket
s = socket.socket()
s.settimeout(1)
s.connect(('127.0.0.1', 7865))
s.close()
" 2>/dev/null; then
    FOOOCUS_READY=1
    echo "Fooocus está activo en el puerto 7865."
    break
  fi

  if ! pgrep -f "entry_with_update.py" > /dev/null; then
    echo "Fooocus se cerró. Últimas líneas del registro:"
    tail -n 80 /content/fooocus.log
    exit 1
  fi

  sleep 2
done

if [ "$FOOOCUS_READY" -ne 1 ]; then
  echo "Fooocus tardó demasiado en iniciar. Registro:"
  tail -n 80 /content/fooocus.log
  exit 1
fi

echo ""
echo "Últimas líneas de Fooocus:"
tail -n 40 /content/fooocus.log

echo ""
echo "Creando túnel Cloudflare para Fooocus..."
cloudflared tunnel --url http://127.0.0.1:7865
