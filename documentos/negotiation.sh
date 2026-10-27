#!/bin/bash

# Definir la ruta del proyecto Python Negotiation
PYTHON_NEGOTIATION=$HOME/Documentos/AWS-CodeComit/python-negotiation

# Definir la ruta de las librerias locales Python
PYTHON_LIB=$HOME/Documentos/AWS-CodeComit/

# Agregar variables de entorno específicas
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION="python"
export TOPICS="system-domain-events"
export TOPIC="negotiation"
export ENVIRONMENT="local"
export BUS_SECRET_NAME="dev/app/bus"
export AWS_PROFILE="codecommit"
export KAFKA_SERVER="localhost:9093"
export KAFKA_PROTOCOL="PLAINTEXT"
export APP_NAME="negotiation"
export GROUP_ID="negotiation"
export CONF_PATH="src/message-protos.json"
export DB_SECRET_NAME="dev/db/postgres"
export NOSQL_SECRET_NAME="dev/db/documentdb"
export NOSQL_DB_NAME="negotiation"
export DB_NAME="core"
export REDIS_HOST="localhost"
export REDIS_PORT="6379"
export REDIS_STRICT="True"
export S3_BUCKET_NAME_NEGOTIATION="dev-negotiation-081236551231"
export S3_BUCKET_PROFILE_NAME="codecommit"
export S3_CUSTOMERS_DOCUMENTS_PATH="customers"
export S3_CUSTOMERS_PROFILE_PATH="negotiation/thumbnails"
export S3_CONTACTS_DOCUMENTS_PATH="contacts"
export JWT_SECRET_KEY_NAME="dev/app/secret_jwt"
export JWT_EXPIRATION_TIME="3600"
export SCHEMA="core"
export SERVICE_NAME="secretsmanager"
export REGION_NAME="us-east-1"
export AWS_REGION="us-east-1"
# export SCHEMA="core"
export TZ="America/Mexico_City"
export LOGGIN_LEVEL="WARNING"
export TOPIC_REALTIME=""
export S3_BUCKET_NAME_INTEGRATION="dev-integration-081236551231"
# Cambiar al directorio del proyecto
cd $PYTHON_NEGOTIATION

# Activar el entorno virtual
. $PYTHON_NEGOTIATION/venv/bin/activate

# Actualizar todas las librerías
update_all() {
    echo "Actualizando todas las librerías..."
    pip install --upgrade -r requirements.txt
}

# Actualizar una o más librerías específicas
update_libraries() {
    echo "Actualizando librerías específicas: $@"
    for lib in "$@"; do
        pip install --upgrade "$lib"
    done
}

# Actualizar librerías desde un repositorio local
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
    --grpc)
        export TRANSPORT_MODE="grpc"
        export GRPC_PORT="50051"
        export GRPC_HOST="localhost"
        export GRPC_MAX_WORKERS="10"
        export PROTOBUS_GATEWAY_HOST="localhost"
        export PROTOBUS_GATEWAY_PORT="50052"

        python $PYTHON_NEGOTIATION/src/app.py
        ;;
    *)
        # Ejecutar el archivo Python si no se pasa argumento 'update'
        python src/app.py
        ;;
esac

# Mostrar la ruta del entorno virtual
echo "Entorno virtual activado en: $PYTHON_NEGOTIATION/venv/bin"

