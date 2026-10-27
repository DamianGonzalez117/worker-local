#!/bin/bash

# Definir la ruta del proyecto Python System
PYTHON_SYSTEM=$HOME/Documentos/AWS-CodeComit/python-system

# Definir la ruta de las librerias locales Python
PYTHON_LIB=$HOME/Documentos/AWS-CodeComit/

# Configurar variables de entorno
setup_env() {
    export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION="python"
    export TOPICS="system-domain-events"
    export TOPIC="system"
    export SERVICE_NAME="secretsmanager"
    export AWS_REGION="us-east-1"
    export TZ="America/Mexico_City"
    export ENVIRONMENT="local"
    export BUS_SECRET_NAME="dev/app/bus"
    export AWS_PROFILE="codecommit"
    export KAFKA_SERVER="localhost:9093"
    export KAFKA_PROTOCOL="PLAINTEXT"
    export APP_NAME="system"
    export GROUP_ID="system"
    export CONF_PATH="src/message-protos.json"
    export DB_SECRET_NAME="dev/db/postgres"
    export NOSQL_DB_NAME="SYSTEM"
    export REDIS_HOST="localhost"
    export REDIS_PORT="6379"
    export REDIS_STRICT="true"
    export SCHEMA="core"
    export PYTHONPATH="${PYTHON_SYSTEM}/src"
    export NOSQL_SECRET_NAME="dev/db/documentdb"
    export LOGGIN_LEVEL="INFO"
    
    echo "Variables de entorno configuradas"
}

# Mostrar ayuda
show_help() {
    echo "Uso: $0 [OPCION]"
    echo ""
    echo "Opciones:"
    echo "  (sin opciones)   Ejecutar la aplicacion"
    echo "  update --all     Actualizar todas las librerias"
    echo "  update [libs]    Actualizar librerias especificas"
    echo "  update --locate [libs]  Actualizar desde repositorio local"
    echo "  --grpc           Ejecutar en modo gRPC"
    echo "  --help           Mostrar esta ayuda"
    echo ""
    echo "Ejemplos:"
    echo "  $0               # Ejecutar la aplicacion"
    echo "  $0 update --all  # Actualizar todas las librerias"
    echo "  $0 update requests flask  # Actualizar librerias especificas"
}

# Cambiar al directorio del proyecto
cd $PYTHON_SYSTEM

# Activar el entorno virtual
. $PYTHON_SYSTEM/venv/bin/activate

# Actualizar todas las librerías
update_all() {
    echo "Actualizando todas las librerias..."
    pip install --upgrade -r requirements.txt
}

# Actualizar una o más librerías específicas
update_libraries() {
    echo "Actualizando librerias especificas: $@"
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

# Verificar argumentos
if [ $# -eq 0 ]; then
    # Sin argumentos -> configurar y ejecutar
    setup_env
    python src/app.py
    exit 0
fi

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
        setup_env
        export TRANSPORT_MODE="grpc"
        export GRPC_PORT="50051"
        export GRPC_HOST="localhost"
        export GRPC_MAX_WORKERS="10"
        export PROTOBUS_GATEWAY_HOST="localhost"
        export PROTOBUS_GATEWAY_PORT="50052"
        
        python src/app.py
        ;;
    --help)
        show_help
        ;;
    *)
        echo "Error: Opcion desconocida: $1"
        show_help
        exit 1
        ;;
esac

# Mostrar la ruta del entorno virtual
echo "Entorno virtual activado en: $PYTHON_SYSTEM/venv/bin"