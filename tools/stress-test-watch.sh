watch -n 1 'docker compose exec -T zypi-node curl -sf http://localhost:4000/containers | jq ".containers | group_by(.status) | map({status: .[0].status, count: length})"'
