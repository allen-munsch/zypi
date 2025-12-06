#!/bin/bash
# tools/zypi-cli.sh - Interactive container session

SERVICE="zypi-node"
API="http://localhost:4000"

_api() { docker compose exec -T $SERVICE curl -sf -X "$1" -H "Content-Type: application/json" ${3:+-d "$3"} "${API}$2"; }

zypi() {
  case "$1" in
    create)  _api POST "/containers" "{\"id\":\"$2\",\"image\":\"$3\"}" | jq . ;;
    start)   _api POST "/containers/$2/start" | jq . ;;
    stop)    _api POST "/containers/$2/stop" | jq . ;;
    destroy) _api DELETE "/containers/$2" | jq . ;;
    logs)    _api GET "/containers/$2/logs" | jq -r '.logs' ;;
    attach)  docker compose exec -T $SERVICE curl -sN "${API}/containers/$2/attach" | while read -r line; do [[ "$line" == data:* ]] && echo "${line#data: }" | base64 -d; done ;;
    status)  _api GET "/containers/$2" | jq . ;;
    list)    _api GET "/containers" | jq . ;;
    shell) docker compose exec $SERVICE crun exec -t "$2" /bin/sh ;;
    # shell_chroot)
    #   os_pid=$(_api GET "/containers/$2" | jq -r '.os_pid // empty')
    #   if [ -n "$os_pid" ]; then
    #     docker compose exec $SERVICE nsenter -t "$os_pid" -m -u -i -p -r /bin/sh
    #   else
    #     docker compose exec $SERVICE chroot "/var/lib/zypi/rootfs/$2" /bin/sh
    #   fi
    #   ;;
    inspect) docker compose exec $SERVICE ls -la "/var/lib/zypi/rootfs/$2" ;;
    push)
      local ref="$2" path="$3"
      local config=$(cat "${path}/config.overlaybd.json")
      local manifest=$(cat "${path}/manifest.json")
      local layers=$(echo "$manifest" | jq -c '.layers')
      local size=$(echo "$manifest" | jq -r '.size_bytes')
      _api POST "/images/${ref}/push" "{\"config\":${config},\"layers\":${layers},\"size_bytes\":${size}}" | jq .
      ;;
    *)       echo "Usage: zypi {create|start|stop|destroy|logs|attach|status|list|shell|inspect} [id] [image]" ;;
  esac
}

echo "Zypi CLI loaded. Commands: zypi {create|start|stop|destroy|logs|attach|status|list|shell|inspect}"
