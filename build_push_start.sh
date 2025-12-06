
for x in $(seq 3 7);do 
	echo $x
	pushd hello-zypi
	docker build -t hello-zypi:v$x .
	popd

	source tools/zypi-cli.sh
	docker save hello-zypi:v$x | docker compose exec -T zypi-node curl -v -X POST -H "Content-Type: application/octet-stream"   --data-binary @- "http://localhost:4000/images/hello-zypi:v$x/import"
	zypi create test$x hello-zypi:v$x
	zypi start test$x
done
