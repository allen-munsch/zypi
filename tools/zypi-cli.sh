#!/bin/bash
SERVICE="zypi-node"
API="http://localhost:4000"

_api() {
  docker compose exec -T $SERVICE curl -sf -X "$1" -H "Content-Type: application/json" ${3:+-d "$3"} "${API}$2"
}



zypi() {
  case "$1" in
    push)
      local ref="$2"
      if [ -z "$ref" ]; then echo "Usage: zypi push <image:tag>"; return 1; fi
      echo "==> Pushing ${ref} to Zypi..."
      docker save "$ref" | docker compose exec -T $SERVICE curl -sf -X POST \
        -H "Content-Type: application/octet-stream" \
        --data-binary @tools/extract-docker-image.sh "${API}/images/${ref}/import" | jq .
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

      # Get the console port from the API
      local CONSOLE_PORT=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}/console_port" | jq -r '.port')
      if [ -z "$CONSOLE_PORT" ] || [ "$CONSOLE_PORT" = "null" ]; then
        echo "Error: Could not get console port for container ${id}. Is it running?"
        return 1
      fi

      echo "Attaching to container ${id} on port ${CONSOLE_PORT}..."
      echo "Press Ctrl-C to detach."
      echo ""

      # Use bash /dev/tcp for proper bidirectional I/O
      docker compose exec -it $SERVICE bash -c '
        # Open bidirectional TCP connection on fd 3
        exec 3<>/dev/tcp/localhost/'"${CONSOLE_PORT}"'
        
        # Send the ATTACH command
        echo "ATTACH:'"${id}"'" >&3
        
        # Background: read from TCP (fd 3) and write to stdout
        cat <&3 &
        READ_PID=$!
        
        # Cleanup on exit
        trap "kill $READ_PID 2>/dev/null; exec 3>&-" EXIT INT TERM
        
        # Foreground: read from stdin and write to TCP (fd 3)
        cat >&3
      '
      ;;
     
    shell)
      local id="$2"
      if [ -z "$id" ]; then 
        echo "Usage: zypi shell <container_id>"
        echo "Opens an interactive shell in the running container"
        return 1
      fi

      # Check if container is running
      local STATUS=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}" | jq -r '.status // "unknown"')
      if [ "$STATUS" != "running" ]; then
        echo "Error: Container ${id} is not running (status: ${STATUS})"
        return 1
      fi

      # Get shell info
      local SHELL_INFO=$(docker compose exec -T $SERVICE curl -sf "${API}/containers/${id}/shell_info")
      
      if [ -z "$SHELL_INFO" ]; then
        echo "Error: Could not get shell info for container ${id}"
        return 1
      fi
      
      # Check for errors
      local ERROR=$(echo "$SHELL_INFO" | jq -r '.error // empty')
      if [ -n "$ERROR" ]; then
        echo "Error: ${ERROR}"
        echo "$(echo "$SHELL_INFO" | jq -r '.message // ""')"
        return 1
      fi
      
      # Get connection mode
      local MODE=$(echo "$SHELL_INFO" | jq -r '.mode // "console"')
      local SSH_AVAILABLE=$(echo "$SHELL_INFO" | jq -r '.ssh_available // false')
      
      if [ "$SSH_AVAILABLE" = "true" ]; then
        # SSH mode
        local IP=$(echo "$SHELL_INFO" | jq -r '.ip')
        local KEY_PATH=$(echo "$SHELL_INFO" | jq -r '.ssh_key_path')
        local USER=$(echo "$SHELL_INFO" | jq -r '.ssh_user // "root"')
        local PORT=$(echo "$SHELL_INFO" | jq -r '.ssh_port // 22')
        
        echo "Connecting via SSH to ${USER} @${IP}..."
        echo "Press Ctrl-D or type 'exit' to disconnect."
        echo ""
        
        docker compose exec -it $SERVICE ssh \
          -i "$KEY_PATH" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -p "$PORT" \
          "${USER} @${IP}"
      else
        # Console mode fallback
        local CONSOLE_PORT=$(echo "$SHELL_INFO" | jq -r '.console_port // 4001')
        
        echo "Connecting to container ${id} shell..."
        echo "Press Ctrl-C to disconnect."
        echo ""
        
        # Clear buffer so we don't see boot logs
        docker compose exec -T $SERVICE curl -sf -X POST "${API}/containers/${id}/console/clear" > /dev/null 2>&1 || true
        
        # Spawn shell (sends newlines to get fresh prompt)  
        docker compose exec -T $SERVICE curl -sf -X POST "${API}/containers/${id}/shell/spawn" > /dev/null
        
        # Small delay for prompt
        sleep 0.3
        
        # Use bash /dev/tcp for proper bidirectional I/O with raw terminal
        docker compose exec -it $SERVICE bash -c '
          # Save terminal settings
          OLD_STTY=$(stty -g)
          
          # Set terminal to raw mode (pass through all characters)
          stty raw -echo
          
          # Restore terminal on exit
          trap "stty $OLD_STTY" EXIT INT TERM
          
          # Open bidirectional TCP connection
          exec 3<>/dev/tcp/localhost/'"${CONSOLE_PORT}"'
          
          # Send ATTACH command (need \r\n for line ending)
          printf "ATTACH:'"${id}"'\r\n" >&3
          
          # Background: TCP to stdout
          cat <&3 &
          READ_PID=$!
          
          # Update trap to also kill reader
          trap "kill $READ_PID 2>/dev/null; stty $OLD_STTY; exec 3>&-" EXIT INT TERM
          
          # Foreground: stdin to TCP
          cat >&3
        '
      fi
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