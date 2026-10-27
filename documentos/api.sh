#!/bin/bash

# Definir la ruta del proyecto Python API
PYTHON_API=$HOME/Documentos/AWS-CodeComit/python-api

# Definir la ruta de las librerias locales Python
PYTHON_LIB==$HOME/Documentos/AWS-CodeComit

# Variables de entorno específicas para FastAPI con Uvicorn
export ENVIRONMENT="local"
export AWS_PROFILE="codecommit"
export AWS_REGION="us-east-1"
export APP_NAME="api"
export LOGGIN_LEVEL="INFO"
export EXPIRE_CACHE="3600"
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION="python"
export KAFKA_HOST="localhost:9093"
export KAFKA_PROTOCOL="PLAINTEXT"
export REDIS_HOST="localhost"
export REDIS_PORT="6379"
export REDIS_STRICT="True"
export TIME_TO_SLEEP="1"
export PATH_SECRET_BUS="dev/app/bus"
export PATH_SECRET_FRONT="dev/app/frontend"
export NOSQL_SECRET_NAME="dev/db/documentdb"
export NOSQL_DB_NAME="IAM"
export TIME_ZONE="America/Mexico_City"
export REGION_NAME="us-east-1"
export SECRETS_SERVICE_NAME="secretsmanager"
export TIMEOUT="60"
export COOKIES_DOMAIN="localhost"
export IDENTITY_PROVIDER_SECRET_NAME="dev/app/identityprovider"

# Cambiar al directorio del proyecto
cd $PYTHON_API

# Agregar el directorio src al PYTHONPATH
export PYTHONPATH=$PYTHON_API/src

# Función para actualizar todas las librerías
update_all() {
    echo "Actualizando todas las librerías..."
    pip install --upgrade -r requirements.txt
}

# Función para actualizar una o más librerías específicas
update_libraries() {
    echo "Actualizando librerías específicas: $@"
    for lib in "$@"; do
        pip install --upgrade "$lib"
    done
}

# Función para actualizar librerías desde un repositorio local
update_from_local() {
    echo "Actualizando desde repositorio local: $@"
    for lib in "$@"; do
        repo_path="$PYTHON_LIB/$lib"
        if [ -d "$repo_path" ]; then
            echo "Actualizando $lib desde $repo_path"
            pip install --upgrade "$repo_path"
        else
            echo "Repositorio $lib no encontrado en $repo_path"
        fi
    done
}

# Comprobar el argumento
case "$1" in
    update)
        if [ "$2" == "--all" ]; then
            update_all
        elif [ "$2" == "--locate" ]; then
            shift 2
            update_from_local "$@"
        else
            shift 1
            update_libraries "$@"
        fi
        ;;
    *)
        # Activar el entorno virtual si no se pasa argumento 'update'
        . $PYTHON_API/venv/bin/activate

        # Ejecutar Uvicorn para iniciar la aplicación FastAPI
        uvicorn src.main:app --port 8080 --reload
        ;;
esac

# Mostrar la ruta del entorno virtual
echo "Entorno virtual activado en: $PYTHON_API/venv/bin"
