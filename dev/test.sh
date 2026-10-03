#!/usr/bin/env bash
# cek-setup.sh - pemeriksaan otomatis setup NATS + Typesense.
# Jalankan dari folder yang berisi .env dan docker-compose.yml:   bash cek-setup.sh
# Script ini hanya MEMBACA status; tidak mengubah atau menghapus data apa pun.

cd "$(dirname "$0")" || exit 1

if [ ! -f .env ]; then
  echo ".env tidak ditemukan di $(pwd)"
  exit 1
fi
set -a; . ./.env; set +a      # baca .env ke variabel (NATS_APP_PASSWORD, TYPESENSE_API_KEY)

PASS=0
FAIL=0
ok()  { echo "[ OK     ] $1"; PASS=$((PASS+1)); }
bad() { echo "[ GAGAL  ] $1"; echo "           saran: $2"; FAIL=$((FAIL+1)); }

# cek "deskripsi" "saran jika gagal" perintah...   -> lulus jika perintah berhasil (exit 0)
cek() {
  local desc="$1" hint="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc" "$hint"; fi
}

echo "== Disk dan sistem =="
cek "Disk data ter-mount di /data" \
    "cek baris /data di /etc/fstab, lalu: sudo mount -a" \
    mountpoint -q /data
cek "Folder /data/nats dan /data/typesense dimiliki 1000:1000" \
    "sudo chown -R 1000:1000 /data/nats /data/typesense" \
    bash -c '[ "$(stat -c %u:%g /data/nats)" = "1000:1000" ] && [ "$(stat -c %u:%g /data/typesense)" = "1000:1000" ]'
cek "File .env hanya bisa dibaca pemiliknya (izin 600)" \
    "chmod 600 .env" \
    bash -c '[ "$(stat -c %a .env)" = "600" ]'
cek "Pemakaian disk / di bawah 80%" \
    "bersihkan image lama: docker image prune" \
    bash -c '[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 80 ]'
cek "Pemakaian disk /data di bawah 80%" \
    "kecilkan retensi stream NATS atau tambah disk lewat Add Disk" \
    bash -c '[ "$(df --output=pcent /data | tail -1 | tr -dc 0-9)" -lt 80 ]'
cek "Jam sistem tersinkron (NTP)" \
    "cek: timedatectl dan chronyc tracking; tanyakan tim infra" \
    bash -c '[ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]'

echo
echo "== Docker dan container =="
cek "Layanan docker aktif" \
    "sudo systemctl start docker" \
    systemctl is-active --quiet docker
cek "Docker menyala otomatis saat boot" \
    "sudo systemctl enable docker" \
    systemctl is-enabled --quiet docker
for c in nats typesense; do
  cek "Container $c berjalan" \
      "docker compose logs --tail=50 $c" \
      bash -c "[ \"\$(docker inspect -f '{{.State.Running}}' $c)\" = \"true\" ]"
  cek "Container $c tidak sering restart (kurang dari 3x)" \
      "docker compose logs --tail=100 $c" \
      bash -c "[ \"\$(docker inspect -f '{{.RestartCount}}' $c)\" -lt 3 ]"
  cek "Container $c tidak pernah dimatikan karena kehabisan memori (OOM)" \
      "naikkan mem_limit di docker-compose.yml dan Resize VM bila perlu" \
      bash -c "[ \"\$(docker inspect -f '{{.State.OOMKilled}}' $c)\" = \"false\" ]"
done

echo
echo "== Kesehatan layanan =="
cek "NATS healthz OK" \
    "docker compose logs --tail=50 nats" \
    curl -fsS http://127.0.0.1:8222/healthz
cek "Typesense /health OK" \
    "docker compose logs --tail=50 typesense" \
    bash -c 'curl -fsS http://127.0.0.1:8108/health | grep -q "\"ok\":true"'

echo
echo "== Keamanan =="
cek "Typesense menolak akses tanpa API key" \
    "pastikan TYPESENSE_API_KEY terisi di .env lalu: docker compose up -d" \
    bash -c 'c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8108/collections); [ "$c" = 401 ] || [ "$c" = 403 ]'
cek "Typesense menerima API key yang benar" \
    "cek nilai TYPESENSE_API_KEY di .env, lalu: docker compose up -d" \
    curl -fsS -H "X-TYPESENSE-API-KEY: $TYPESENSE_API_KEY" http://127.0.0.1:8108/collections
cek "NATS menolak koneksi tanpa kredensial" \
    "periksa blok authorization di nats.conf (juga pastikan image natsio/nats-box bisa di-pull)" \
    bash -c 'docker run --rm --network host natsio/nats-box nats --server nats://127.0.0.1:4222 pub cek.tanpa.auth x 2>&1 | grep -qi "authorization"'
case "$NATS_APP_PASSWORD" in
  '$2'*)
    echo "[ LEWAT  ] Login NATS tidak diuji otomatis karena NATS_APP_PASSWORD berupa hash bcrypt."
    echo "           Uji manual dengan password asli (lihat bagian Checklist di panduan)."
    ;;
  *)
    cek "NATS menerima kredensial sobat_app dan JetStream aktif" \
        "periksa NATS_APP_PASSWORD di .env, lalu: docker compose up -d" \
        docker run --rm --network host natsio/nats-box nats --server "nats://sobat_app:${NATS_APP_PASSWORD}@127.0.0.1:4222" account info
    ;;
esac
cek "Port monitoring NATS (8222) hanya di localhost" \
    "pastikan mapping port di compose berbunyi 127.0.0.1:8222:8222" \
    bash -c '! ss -tln | grep -E ":8222( |$)" | grep -vq "127.0.0.1"'

echo
echo "Hasil: $PASS lulus, $FAIL gagal"
echo "Belum diuji script ini: konektivitas dari OKD, backup/restore, dan reboot VM (lihat Checklist di panduan)."
[ "$FAIL" -eq 0 ]