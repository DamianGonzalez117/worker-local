#!/bin/bash

# Directorio donde están todos tus scripts
SCRIPTS_DIR="$HOME/Documentos/AWS-CodeComit"
LOG_DIR="$HOME/.aws-codecomit-logs"
mkdir -p "$LOG_DIR"

# Mapeo: patrón del proceso -> nombre del script
# Agrega aquí los futuros scripts
declare -A PROCESS_SCRIPT_MAP=(
    ["uvicorn src.main:app"]="api.sh"
    ["python src/app.py"]="negotiation.sh"
    ["negotiation-int"]="negotiation-int.sh"
    ["python-system"]="system.sh"
    ["npm run dev"]="react.sh"
)

# Detectar qué script está corriendo
detect_running_script() {
    for process in "${!PROCESS_SCRIPT_MAP[@]}"; do
        if pgrep -f "$process" > /dev/null; then
            echo "${PROCESS_SCRIPT_MAP[$process]}"
            return 0
        fi
    done
    return 1
}

# Detectar el proceso para matarlo
detect_running_process() {
    for process in "${!PROCESS_SCRIPT_MAP[@]}"; do
        if pgrep -f "$process" > /dev/null; then
            echo "$process"
            return 0
        fi
    done
    return 1
}

# Reiniciar
SCRIPT_NAME=$(detect_running_script)
PROCESS_NAME=$(detect_running_process)

if [ -z "$SCRIPT_NAME" ]; then
    echo "⚠️  No hay ningún servicio corriendo."
    exit 1
fi

echo "🔄 Reiniciando: $SCRIPT_NAME (proceso: $PROCESS_NAME)"

# Matar el proceso
pkill -f "$PROCESS_NAME"
sleep 2

# Forzar si sigue vivo
if pgrep -f "$PROCESS_NAME" > /dev/null; then
    echo "⚡ Forzando detención..."
    pkill -9 -f "$PROCESS_NAME"
    sleep 1
fi

# Reiniciar en background, con log
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.sh}.log"
echo "📝 Log: $LOG_FILE"
nohup "$SCRIPTS_DIR/$SCRIPT_NAME" > "$LOG_FILE" 2>&1 &

echo "✅ $SCRIPT_NAME reiniciado (PID: $!)"
