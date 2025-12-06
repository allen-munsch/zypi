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
      docker compose exec -T $SERVICE curl -sN "${API}/containers/$2/attach" | \
        while read -r line; do
          [[ "$line" == data:* ]] && echo "${line#data: }" | base64 -d
        done
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
      echo "Inspection:"
      echo "  list                 List containers"
      echo "  status <id>          Container status"
      echo "  inspect <id>         Container details"
      echo "  logs <id>            Container logs"
      echo "  attach <id>          Attach to output stream"
      ;; 
  esac
}

echo "Zypi CLI loaded. Type 'zypi' for help."