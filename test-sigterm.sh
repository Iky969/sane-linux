#!/bin/sh
# test-sigterm.sh - layanan uji untuk membuktikan child TIDAK mewarisi signal
# mask milik PID 1 (SIGTERM harus benar-benar sampai ke layanan, bukan diblokir
# lalu dibunuh paksa SIGKILL oleh init).
#
# Pakai di /etc/init.conf pada rootfs uji:
#     sigterm-test:once:/test-sigterm.sh
#
# Ekspektasi setelah ninit menerima SIGTERM:
#   [service] Menerima SIGTERM, bye!
#   ninit: sigterm-test (pid N) exit status=0x0        <- bukan 0x9 (SIGKILL)
#   ninit: graceful shutdown (cmd=1126301404)

trap 'echo "Menerima SIGTERM, bye!"; exit 0' TERM

echo "sigterm-test: jalan, menunggu SIGTERM (pid $$)"
while true; do
    sleep 1
done
