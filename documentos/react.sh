#!/bin/bash

# Definir la ruta del proyecto React
REACT_PROJECT=$HOME/Documentos/AWS-CodeComit/react-negotiation

# Definir el perfil de AWS (opcional, por si git-aws lo requiere)
export AWS_PROFILE="codecommit"

# Función para mostrar mensajes con formato
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m[OK]\033[0m $1"
}

# Verificar que el proyecto existe
if [ ! -d "$REACT_PROJECT" ]; then
    log_error "El proyecto no existe en: $REACT_PROJECT"
    exit 1
fi

# Verificar que el entorno virtual existe
if [ ! -f "$REACT_PROJECT/venv/bin/activate" ]; then
    log_error "El entorno virtual no existe en: $REACT_PROJECT/venv/bin/activate"
    exit 1
fi

# Cambiar al directorio del proyecto
cd "$REACT_PROJECT" || { log_error "No se pudo acceder al directorio del proyecto"; exit 1; }
log_info "Directorio actual: $(pwd)"

# Activar el entorno virtual
log_info "Activando entorno virtual..."
source "$REACT_PROJECT/venv/bin/activate"

if [ -z "$VIRTUAL_ENV" ]; then
    log_error "No se pudo activar el entorno virtual"
    exit 1
fi
log_success "Entorno virtual activado en: $VIRTUAL_ENV"


# Ejecutar npm run dev
log_info "Ejecutando: npm run dev"
npm run dev