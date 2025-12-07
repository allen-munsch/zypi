#!/bin/bash
SERVICE="zypi-node"
API="http://localhost:4000"

_api() {
  docker compose exec -T $SERVICE curl -sf -X "$1" -H "Content-Type: application/json" ${3:+-d "$3"} "${API}$2"
}

# Wait for SSH to be ready on a container
wait_for_ssh() {
  local id="$1"
  local timeout="${2:-60}"
  local elapsed=0
  
  echo -n "Waiting for SSH"
  while [ $elapsed -lt $timeout ]; do
    local ready=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}/ssh_ready" 2>/dev/null | jq -r '.ready // false')
    if [ "$ready" = "true" ]; then
      echo " ready!"
      return 0
    fi
    echo -n "."
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  echo " timeout!"
  return 1
}


zypi() {
  case "$1" in
    push)
      local ref="$2"
      if [ -z "$ref" ]; then echo "Usage: zypi push <image:tag>"; return 1; fi
      echo "==> Pushing ${ref} to Zypi..."
      docker save "$ref" | docker compose exec -T $SERVICE curl -sf -X POST \
        -H "Content-Type: application/octet-stream" \
        --data-binary @- "${API}/images/${ref}/import" | jq .
      ;;
    images)
      _api GET "/images" | jq .
      ;; 
    create)
      _api POST "/containers" "{\"id\":\"$2\",\"image\":\"$3\"}" | jq .
      ;; 
    start)
      _api POST "/containers/$2/start" | jq .
      ;; 
    stop)
      _api POST "/containers/$2/stop" | jq .
      ;; 
    destroy)
      _api DELETE "/containers/$2" | jq .
      ;; 
    logs)
      _api GET "/containers/$2/logs" | jq -r '.logs'
      ;; 
        attach)
      local id="$2"
      if [ -z "$id" ]; then echo "Usage: zypi attach <id>"; return 1; fi

      local CONSOLE_PORT=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}/console_port" 2>/dev/null | jq -r '.port')
      if [ -z "$CONSOLE_PORT" ] || [ "$CONSOLE_PORT" = "null" ]; then
        echo "Error: Could not get console port for container ${id}. Is it running?"
        return 1
      fi

      echo "Attaching to container ${id} console output..."
      echo "This is READ-ONLY. Use 'zypi shell ${id}' for interactive access."
      echo "Press Ctrl-C to detach."
      echo ""

      # Simple read-only attach - just view output
      docker compose exec -it $SERVICE sh -c "
        echo 'ATTACH:${id}' | nc -q0 localhost ${CONSOLE_PORT} || 
        (echo 'ATTACH:${id}'; sleep infinity) | nc localhost ${CONSOLE_PORT}
      "
      ;;
     
    shell)
      local id="$2"
      if [ -z "$id" ]; then 
        echo "Usage: zypi shell <container_id>"
        echo "Opens an interactive SSH shell in the running container"
        return 1
      fi

      # Check if container is running
      local STATUS=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}" 2>/dev/null | jq -r '.status // "unknown"')
      if [ "$STATUS" != "running" ]; then
        echo "Error: Container ${id} is not running (status: ${STATUS})"
        return 1
      fi

      # Get shell info
      local SHELL_INFO=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}/shell_info" 2>/dev/null)
      
      if [ -z "$SHELL_INFO" ]; then
        echo "Error: Could not get shell info for container ${id}"
        return 1
      fi
      
      # Check for errors
      local ERROR=$(echo "$SHELL_INFO" | jq -r '.error // empty')
      if [ -n "$ERROR" ]; then
        local MESSAGE=$(echo "$SHELL_INFO" | jq -r '.message // "Unknown error"')
        echo "Error: ${ERROR}"
        echo "${MESSAGE}"
        return 1
      fi
      
      local IP=$(echo "$SHELL_INFO" | jq -r '.ip')
      local KEY_PATH=$(echo "$SHELL_INFO" | jq -r '.ssh_key_path')
      local USER=$(echo "$SHELL_INFO" | jq -r '.ssh_user // "root"')
      local PORT=$(echo "$SHELL_INFO" | jq -r '.ssh_port // 22')
      
      # Wait for SSH to be ready (container needs time to boot and install SSH)
      # if ! wait_for_ssh "$id" 60; then
      #   echo ""
      #   echo "Error: SSH did not become ready within 60 seconds"
      #   echo "The container may still be installing SSH. Check logs:"
      #   echo "  zypi logs ${id}"
      #   return 1
      # fi
      
      echo "Connecting via SSH to ${USER}@${IP}..."
      echo "Press Ctrl-D or type 'exit' to disconnect."
      echo ""
      
      docker compose exec -it $SERVICE ssh \
        -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        -p "$PORT" \
        "${USER}@${IP}"
      ;;
     
    status)
      _api GET "/containers/$2" | jq .
      ;; 
    list)
      _api GET "/containers" | jq .
      ;; 
    inspect)
      _api GET "/containers/$2" | jq .
      ;; 
    run)
      local id="$2" image="$3"
      if [ -z "$id" ] || [ -z "$image" ]; then
        echo "Usage: zypi run <id> <image>"
        return 1
      fi
      zypi create "$id" "$image" && zypi start "$id"
      ;; 
    *)
      echo "Zypi CLI - Firecracker Container Runtime"
      echo ""
      echo "Image commands:"
      echo "  push <image:tag>     Push Docker image to Zypi"
      echo "  images               List available images"
      echo ""
      echo "Container commands:"
      echo "  create <id> <image>  Create container"
      echo "  start <id>           Start container (launches VM)"
      echo "  stop <id>            Stop container"
      echo "  destroy <id>         Destroy container"
      echo "  run <id> <image>     Create and start"
      echo ""
      echo "Interactive:"
      echo "  shell <id>           Open interactive shell (SSH)"
      echo "  attach <id>          Attach to console output stream"
      echo "  logs <id>            View container logs"
      echo ""
      echo "Inspection:"
      echo "  list                 List containers"
      echo "  status <id>          Container status"
      echo "  inspect <id>         Container details"
      ;; 
  esac
}

echo "Zypi CLI loaded. Type 'zypi' for help."