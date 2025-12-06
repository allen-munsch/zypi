
for x in $(seq 2 4);do 
	echo $x
	pushd hello-zippy
	docker build -t hello-zippy:v$x .
	popd

	source tools/zypi-cli.sh
	docker save hello-zippy:v$x | docker compose exec -T zypi-node curl -v -X POST -H "Content-Type: application/octet-stream"   --data-binary @- "http://localhost:4000/images/hello-zippy:v$x/import"
	zypi create test$x hello-zippy:v$x
	zypi start test$x
done


for x in $(seq 21 22);do 
	echo $x
	pushd hello-zippy
	docker build -t hello-zippy:v$x .
	popd

	source tools/zypi-cli.sh
	docker save hello-zippy:v$x | docker compose exec -T zypi-node curl -v -X POST -H "Content-Type: application/octet-stream"   --data-binary @- "http://localhost:4000/images/hello-zippy:v$x/import"
	zypi create test$x hello-zippy:v$x
	zypi start test$x
done
