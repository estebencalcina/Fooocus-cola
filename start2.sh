#!/bin/bash
set -e

# Carpeta desde la que ejecutas: /content/Fooocus-cola
BASE_DIR="$(pwd)"
FOOOCUS_DIR="$BASE_DIR/Fooocus"
ENV_DIR="/tmp/fooocus"

# Cargar Conda correctamente, sin depender de ~/.conda/envs
source "$(conda info --base)/etc/profile.d/conda.sh"

# Descargar o actualizar Fooocus
if [ ! -d "$FOOOCUS_DIR" ]; then
  git clone https://github.com/estebencalcina/Fooocus.git "$FOOOCUS_DIR"
else
  cd "$FOOOCUS_DIR"
  git pull
  cd "$BASE_DIR"
fi

cd "$FOOOCUS_DIR"

# Crear el entorno aislado solo la primera vez
if [ ! -x "$ENV_DIR/bin/python" ]; then
  echo "Creando entorno Conda para Fooocus..."
  conda env create --prefix "$ENV_DIR" -f environment.yaml
fi

# Activar SIEMPRE el entorno correcto
conda activate "$ENV_DIR"

# Instalar dependencias de Fooocus dentro del entorno, no en el Python global de Colab
pip install --no-cache-dir -r requirements_versions.txt

# Versiones compatibles: evita el error NumPy/CuPy
pip uninstall -y numpy cupy cupy-cuda11x cupy-cuda12x || true
pip install --no-cache-dir --force-reinstall \
  numpy==1.26.4 \
  cupy-cuda12x==13.6.0

# Evita el error: TypeError: unhashable type: 'dict'
pip install --no-cache-dir --force-reinstall \
  gradio==3.41.2 \
  fastapi==0.103.2 \
  starlette==0.27.0 \
  jinja2==3.1.2

# Configurar la carpeta de modelos
MODEL_FOLDER="$FOOOCUS_DIR/models/checkpoints-real-folder"

if [ ! -f config.txt ]; then
  echo "{ \"path_checkpoints\": \"$MODEL_FOLDER\" }" > config.txt
else
  jq --arg new_value "$MODEL_FOLDER" \
    '.path_checkpoints = $new_value' config.txt > config_tmp.txt \
    && mv config_tmp.txt config.txt
fi

# Crear la carpeta de checkpoints si todavía no existe
if [ ! -d models/checkpoints-real-folder ]; then
  mkdir -p models/checkpoints-real-folder
fi

# Mantener el enlace usado por Fooocus
if [ ! -L models/checkpoints ]; then
  rm -rf models/checkpoints
  ln -s models/checkpoints-real-folder models/checkpoints
fi

# Detener instancias previas, por si las hubiera
pkill -f "entry_with_update.py" || true
pkill -f "cloudflared tunnel --url.*7865" || true

# Iniciar Fooocus
echo "Iniciando Fooocus..."
nohup python entry_with_update.py \
  --listen \
  --share \
  --always-high-vram \
  > /content/fooocus.log 2>&1 &

# Esperar a que Fooocus esté disponible, en vez de esperar 120 segundos sin comprobar nada
echo "Esperando a Fooocus..."
for i in {1..90}; do
  if curl -s http://127.0.0.1:7865/ > /dev/null; then
    echo "Fooocus ya está activo."
    break
  fi

  if ! pgrep -f "entry_with_update.py" > /dev/null; then
    echo "Fooocus se cerró. Últimas líneas del registro:"
    tail -n 60 /content/fooocus.log
    exit 1
  fi

  sleep 2
done

# Mostrar las últimas líneas para ver el enlace de Gradio, si se generó
tail -n 30 /content/fooocus.log

# Crear el túnel Cloudflare para Fooocus
echo "Creando túnel Cloudflare para Fooocus..."
cloudflared tunnel --url http://127.0.0.1:7865
