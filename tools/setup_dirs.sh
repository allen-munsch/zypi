mkdir -p ./.zypi/overlaybd/logs
mkdir -p ./.zypi/overlaybd/cache
mkdir -p ./.zypi/overlaybd/gzip
mkdir -p ./.zypi/overlaybd/creds
mkdir -p ./.zypi/overlaybd/images

touch ./.zypi/overlaybd/logs/overlaybd.log
touch ./.zypi/overlaybd/logs/overlaybd-audit.log

chmod -R 777 ./.zypi/overlaybd
