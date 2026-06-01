#!/bin/bash
set -e

NEO4J_HOME=/var/lib/neo4j
NEO4J_DATA=/var/lib/neo4j/data
NEO4J_LOGS=/var/log/neo4j
NEO4J_RUN=/var/run/neo4j
NEO4J_PLUGINS_DIR=/var/lib/neo4j/plugins

export NEO4J_HOME

# ==== CONFIG SETUP ====
# Copy default config to a writable location (data dir is bind-mounted)
NEO4J_CONF="${NEO4J_DATA}/conf"
export NEO4J_CONF
if [ ! -f "$NEO4J_CONF/neo4j.conf" ]; then
    mkdir -p "$NEO4J_CONF"
    cp -r /etc/neo4j/* "$NEO4J_CONF/" 2>/dev/null || true
fi

# ==== NEO4J_AUTH SETUP ====
if [ -n "${NEO4J_AUTH:-}" ]; then
    if [ "$NEO4J_AUTH" = "none" ]; then
        echo "Disabling authentication"
        echo "dbms.security.auth_enabled=false" >> "$NEO4J_CONF/neo4j.conf"
    elif [[ "$NEO4J_AUTH" =~ ^([^/]+)/([^/]+)/?(true)?$ ]]; then
        password="${BASH_REMATCH[2]}"
        if [ "$password" = "neo4j" ]; then
            echo >&2 "ERROR: Password cannot be 'neo4j'"
            exit 1
        fi
        if [ ! -f "$NEO4J_DATA/neostore.db" ] && [ ! -f "$NEO4J_DATA/neostore" ]; then
            echo "Setting initial Neo4j password..."
            neo4j-admin dbms set-initial-password "$password" --require-password-change=false 2>&1 || true
        else
            echo "Database already initialized, skipping password setup."
        fi
    else
        echo >&2 "ERROR: Invalid NEO4J_AUTH format: $NEO4J_AUTH (expected neo4j/password)"
        exit 1
    fi
fi

# ==== NEO4J_PLUGINS INSTALL ====
if [ -n "${NEO4J_PLUGINS:-}" ]; then
    echo "Installing plugins: $NEO4J_PLUGINS"
    for plugin in $(echo "$NEO4J_PLUGINS" | jq -r '.[]'); do
        case "$plugin" in
            apoc)
                p_version="${APOC_VERSION:-5.20.0}"
                url="https://github.com/neo4j/apoc/releases/download/${p_version}/apoc-${p_version}-core.jar"
                echo "  Downloading APOC ${p_version}..."
                curl -fsSL -o "$NEO4J_PLUGINS_DIR/apoc.jar" "$url" || {
                    echo "  WARNING: Failed to download APOC from $url"
                }
                if grep -q "^dbms.security.procedures.unrestricted=" "$NEO4J_CONF/neo4j.conf" 2>/dev/null; then
                    sed -i "/^dbms.security.procedures.unrestricted=/ s/$/,apoc.*/" "$NEO4J_CONF/neo4j.conf"
                else
                    echo "dbms.security.procedures.unrestricted=apoc.*" >> "$NEO4J_CONF/neo4j.conf"
                fi
                ;;
            graph-data-science|gds)
                gds_url="https://graphdatascience.ninja/versions.json"
                neo4j_ver="5.20.0"
                echo "  Looking up GDS for Neo4j ${neo4j_ver}..."
                gds_jar_url=$(curl -fsSL "$gds_url" 2>/dev/null | \
                    jq -r --arg nv "$neo4j_ver" '[.[] | select(.neo4j==$nv)] | .[0].jar // empty' 2>/dev/null || echo "")
                if [ -z "$gds_jar_url" ]; then
                    gds_jar_url="https://graph-data-science-release.s3.amazonaws.com/gds/2.6.10/neo4j-graph-data-science-2.6.10.jar"
                    echo "  (fallback) $gds_jar_url"
                fi
                echo "  Downloading GDS..."
                curl -fsSL -o "$NEO4J_PLUGINS_DIR/gds.jar" "$gds_jar_url" || {
                    echo "  WARNING: Failed to download GDS from $gds_jar_url"
                }
                if grep -q "^dbms.security.procedures.unrestricted=" "$NEO4J_CONF/neo4j.conf" 2>/dev/null; then
                    if ! grep -q "gds" "$NEO4J_CONF/neo4j.conf"; then
                        sed -i "/^dbms.security.procedures.unrestricted=/ s/$/,gds.*/" "$NEO4J_CONF/neo4j.conf"
                    fi
                else
                    echo "dbms.security.procedures.unrestricted=gds.*" >> "$NEO4J_CONF/neo4j.conf"
                fi
                ;;
            *)
                echo "  WARNING: Unknown plugin '$plugin', skipping"
                ;;
        esac
    done
fi

# ==== NEO4J_* ENV VARS → CONFIG ====
while IFS='=' read -r env_full env_value; do
    var="${env_full#NEO4J_}"
    case "$var" in
        AUTH|PLUGINS|ACCEPT_LICENSE_AGREEMENT|CONF|DEBUG|EDITION|HOME|SHA256|TARBALL|AUTH_PATH|DEPRECATION_WARNING) continue ;;
        *_FILE) continue ;;
    esac
    setting=$(echo "$var" | sed 's/_/./g' | sed 's/\.\./_/g')
    if [ -n "$env_value" ]; then
        sed -i "/^${setting}=/d" "$NEO4J_CONF/neo4j.conf" 2>/dev/null || true
        echo "${setting}=${env_value}" >> "$NEO4J_CONF/neo4j.conf"
    fi
done < <(env | grep '^NEO4J_')

# ==== CLEANUP ====
rm -f "$NEO4J_RUN/neo4j.pid" "$NEO4J_DATA/conf/neo4j.pid" 2>/dev/null || true

# ==== SIGNAL HANDLER ====
cleanup() {
    echo "Shutting down Neo4j..."
    kill "$NEO4J_PID" 2>/dev/null || true
    wait "$NEO4J_PID" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ==== START NEO4J ====
echo "Starting Neo4j..."
neo4j console &
NEO4J_PID=$!

# ==== WAIT FOR NEO4J HTTP API ====
http_addr="${NEO4J_server_http_listen__address:-:7474}"
http_port="${http_addr##*:}"
echo "Waiting for Neo4j to start on HTTP port $http_port..."
count=0
while ! nc -z localhost "$http_port" 2>/dev/null; do
    sleep 2
    count=$((count + 1))
    if [ $count -gt 90 ]; then
        echo "ERROR: Neo4j did not start within 180 seconds"
        kill "$NEO4J_PID" 2>/dev/null || true
        exit 1
    fi
done
echo "Neo4j has started (HTTP port $http_port)."

# ==== LOAD DATA ====
if [ -f /init/graph.json ]; then
    echo "Loading data from /init/graph.json..."
    bolt_addr="${NEO4J_server_bolt_listen__address:-:7687}"
    bolt_port="${bolt_addr##*:}"
    python3 /opt/neo4j-loader/loader.py --input_path /init/graph.json --uri "bolt://localhost:${bolt_port}"
    echo "Data loading complete."
else
    echo "No graph file at /init/graph.json — skipping loader."
fi

# ==== KEEP NEO4J RUNNING ====
wait "$NEO4J_PID"
