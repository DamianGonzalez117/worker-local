#!/bin/bash

# Definir la ruta del proyecto Python Negotiation
PYTHON_NEGOTIATION=$HOME/Documentos/AWS-CodeComit/python-negotiation-int

# Definir la ruta de las librerias locales Python
PYTHON_LIB=$HOME/Documentos/AWS-CodeComit/

# Agregar variables de entorno específicas (ajustadas según solicitado)
export ENVIRONMENT="local"
export APP_NAME="negotiation-int"
export GROUP_ID="negotiation-int"
export KAFKA_SERVER="localhost:9093"
export KAFKA_PROTOCOL="PLAINTEXT"
export AWS_PROFILE="codecommit"
export BUS_SECRET_NAME="dev/app/bus"
export DB_SECRET_NAME="dev/db/postgres"
export NOSQL_SECRET_NAME="dev/db/documentdb"
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION="python"
export REDIS_HOST="localhost"
export REDIS_PORT="6379"
export REDIS_STRICT="True"
export TOPIC="negotiation-int"
export TOPICS="negotiation-domain-events,ds-multipac-domain-events,billing-collect-domain-events,accounting-domain-events,negotiation-int-domain-events,sales-domain-events,conciliation-domain-events,scheduling-traffic-domain-events,orders-domain-events"
export CONF_PATH="src/message-protos.json"
export DB_NAME="core"
export NOSQL_DB_NAME="INTEGRATION"
export SCHEMA="core"
export TZ="America/Mexico_City"
export LOGGIN_LEVEL="INFO"
export SERVICE_NAME="secretsmanager"
export AWS_REGION="us-east-1"
export TOPIC_REALTIME="None"
export JWT_SECRET_KEY_NAME="dev/app/secret_jwt"
export JWT_EXPIRATION_TIME="3600"
export MONGO_CONNECTION_STRING="mongodb://root:password@localhost:27017"

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
    *)
        # Ejecutar el archivo Python si no se pasa argumento 'update'
        python src/app.py
        ;;
esac

# Mostrar la ruta del entorno virtual
echo "Entorno virtual activado en: $PYTHON_NEGOTIATION/venv/bin"

