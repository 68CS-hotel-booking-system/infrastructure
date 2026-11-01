# Chuyển VPS sang gateway chung

Đây là hướng dẫn thực hiện, chưa phải biên bản đã chạy. Giữ production tắt
(chưa đặt PRODUCTION_DEPLOY_ENABLED=true) cho đến khi hoàn tất phần kiểm tra.
Tạm ngừng merge FE/BE trong cửa sổ chuyển đổi; giữ lại cấu hình/container cũ.

## 1. Điều kiện trước khi chuyển

- Đã build/deploy lại FE và BE với label io.hotelbooking.source-tree.
- Tài khoản deploy dùng được Docker và ghi /opt/hotel-booking.
- VPS có curl/jq, Docker Compose và quyền pull cả hai image GHCR.
- DNS hai domain đúng VPS; TLS hiện có cho staging và bổ sung certificate/key
  hợp lệ cho hotelbooking.id.vn tại /etc/hotelbooking/tls/production.pem và .key.
- Giữ nguyên DB/user/password staging, không chép đè bằng .env.example.

Trên VPS:

    command -v jq
    docker compose version
    test -s /etc/hotelbooking/tls/staging.pem
    test -s /etc/hotelbooking/tls/staging.key
    test -s /etc/hotelbooking/tls/production.pem
    test -s /etc/hotelbooking/tls/production.key

Nếu thiếu jq trên Ubuntu:

    sudo apt-get update
    sudo apt-get install -y jq

Không đưa secret/TLS key vào Git hoặc gửi vào chat.

## 2. Chuyển source bootstrap từ máy local

Chạy tại repo infra trên máy local. Thay deploy@VPS_HOST bằng SSH target thật.
Các file được chép vào thư mục mới, không ghi đè Compose đang chạy ở gốc VPS.

    ssh deploy@VPS_HOST 'mkdir -p /opt/hotel-booking/gateway/compose /opt/hotel-booking/gateway/nginx/production /opt/hotel-booking/gateway/scripts /opt/hotel-booking/environments/production'
    scp compose.app.yaml deploy@VPS_HOST:/opt/hotel-booking/gateway/
    scp compose/backend.yaml compose/frontend.yaml compose/postgres.yaml compose/gateway.shared.yaml deploy@VPS_HOST:/opt/hotel-booking/gateway/compose/
    scp nginx/staging.edge.conf deploy@VPS_HOST:/opt/hotel-booking/gateway/nginx/
    scp nginx/production/default.conf deploy@VPS_HOST:/opt/hotel-booking/gateway/nginx/production/
    scp scripts/health-check.sh deploy@VPS_HOST:/opt/hotel-booking/gateway/scripts/
    scp environments/production/.env.example deploy@VPS_HOST:/opt/hotel-booking/environments/production/

## 3. Backup và runtime

SSH vào VPS. Các lệnh sau cần chạy trong cùng phiên Bash để giữ biến/helper.

    cd /opt/hotel-booking
    umask 077
    install -d -m 700 backups
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a environments/staging "backups/staging-config-$stamp"

Backup DB hiện tại nếu đã có PostgreSQL chạy; kiểm tra đúng một container:

    postgres_id="$(docker ps -q \
      --filter label=com.docker.compose.project=hotel-booking-staging \
      --filter label=com.docker.compose.service=postgres)"
    [[ -n "$postgres_id" && "$postgres_id" != *$'\n'* ]]
    docker exec "$postgres_id" sh -c \
      'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
      > "backups/staging-$stamp.dump" &&
      test -s "backups/staging-$stamp.dump"

Không tiếp tục nếu backup lỗi. Một file dump tạo thành công vẫn cần được kiểm tra
restore ở DB riêng theo quy trình backup của nhóm; không restore đè DB đang chạy.

Tạo .env production lần đầu:

    if [[ ! -e environments/production/.env ]]; then
      cp environments/production/.env.example environments/production/.env
    fi
    nano environments/production/.env
    chmod 600 environments/production/.env

Điền password/JWT riêng (openssl rand -base64 32 để sinh JWT secret), cấu hình
mail thực tế. Không sao chép database staging sang production.

## 4. Kiểm tra gateway trước khi giải phóng cổng

    docker network inspect hotel-booking-edge >/dev/null 2>&1 ||
      docker network create hotel-booking-edge

    bootstrap_root=/opt/hotel-booking/gateway
    stage_compose() {
      DEPLOY_ENVIRONMENT=staging SPRING_PROFILES_ACTIVE=staging \
        docker compose --project-name hotel-booking-staging \
          --project-directory "$bootstrap_root" --file "$bootstrap_root/compose.app.yaml" \
          --env-file /opt/hotel-booking/environments/staging/.env \
          --env-file /opt/hotel-booking/environments/staging/images.env "$@"
    }
    gateway_compose() {
      docker compose --project-name hotel-booking-gateway \
        --project-directory "$bootstrap_root" \
        --file "$bootstrap_root/compose/gateway.shared.yaml" "$@"
    }

    stage_compose config --quiet
    gateway_compose config --quiet
    gateway_compose run --rm --no-deps gateway nginx -t

Lệnh run nginx -t không publish cổng service nên có thể kiểm tra trong lúc gateway
cũ vẫn giữ 80/443. Chứng chỉ phải có; production container chưa có vẫn được vì
upstream phân giải động. Không tiếp tục khi nginx -t lỗi.

## 5. Chuyển ứng dụng và gateway

Giữ project name staging để tiếp tục dùng đúng volume hiện tại:

    stage_compose up -d --wait --wait-timeout 180
    stage_compose exec -T frontend wget -q -T 3 -O - \
      http://staging-backend:8080/actuator/health

Đợi BE khởi động, lặp lại kiểm tra nội bộ đến khi status UP. FE/BE có thể vừa được
tạo lại nên gateway cũ có thể giữ IP cũ trong khoảng chuyển này.

Xác định và dừng đúng gateway cũ, sau đó khởi động project gateway chung:

    old_gateway="$(docker ps -q \
      --filter label=com.docker.compose.project=hotel-booking-staging \
      --filter label=com.docker.compose.service=gateway)"
    [[ -n "$old_gateway" && "$old_gateway" != *$'\n'* ]]
    docker stop "$old_gateway"
    gateway_compose up -d --wait --wait-timeout 120
    bash "$bootstrap_root/scripts/health-check.sh" staging

Khi đủ HTTPS_OK, FRONTEND_OK, BACKEND_OK mới hoàn tất chuyển đổi. Giữ gateway cũ
ở trạng thái stopped. Không dùng docker compose down -v hoặc --remove-orphans.

Nếu gateway chung không chạy được, quay lại gateway cũ rồi điều tra:

    gateway_compose stop gateway
    docker start "$old_gateway"
    docker exec "$old_gateway" nginx -s reload

Đây là quay lại gateway, không hoàn tác app hoặc migration.

Gateway chung giữ mount trong /opt/hotel-booking/gateway/nginx. App deployments
không cập nhật gateway. Khi đổi Nginx sau này, ghi đè tại chỗ hoặc recreate
gateway đúng kế hoạch; nginx -t trước reload. Không sửa secret runtime từ runner.

## 6. Bật các workflow mới

1. Sau chuyển gateway thành công, merge/push source infra mới lên main.
2. Run Deploy staging với hai input trống hoặc cặp digest cụ thể.
3. Run phải thành công, artifact staging-release có deployed-release.json.
4. Xác nhận source ở deployments/staging/<infra-sha>, runtime vẫn ở environments/staging.
5. Đặt environment production, required reviewer, branch main và các secrets
   theo README. APP_READ_TOKEN cần đọc được Contents/Actions của cả FE/BE.
6. Bật quyền Actions tạo PR để Prepare release dùng GITHUB_TOKEN.
7. Sau khi sẵn sàng, đặt Repository Actions variable PRODUCTION_DEPLOY_ENABLED=true.

Không cần chạy production ngay khi bật biến; chạy sau khi có release đã duyệt
và hai nhánh main/CI khớp. Có thể kiểm tra lại bằng Run workflow Deploy production.

## 7. Kiểm thử lần phát hành đầu

- Chọn RUN ID staging QA đã test.
- Merge develop → staging ở hai ứng dụng, CI đạt.
- Prepare release, review và merge PR infra.
- Khi main của một ứng dụng chưa khớp: production phải WAIT, deploy bị skip.
- Sau cả hai main/CI đạt: production phải chờ reviewer.
- Sau duyệt: đúng hai digest trong release xuất hiện trên container production,
  public health đạt và kiểm thử chức năng chính đạt.
- Staging cập nhật sau lúc chốt: nội dung releases/<id>.json vẫn giữ nguyên.
- Không sửa release đã chốt để xử lý lỗi; tạo ID mới sau kiểm thử.

Luồng chưa tự backup/restore DB hoặc rollback ứng dụng. Chuẩn bị quy trình đó
trước khi vận hành dữ liệu production quan trọng.
