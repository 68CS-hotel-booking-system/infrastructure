# Hạ tầng Hotel Booking

Staging: https://staging.hotelbooking.id.vn/

## Cấu trúc hiện tại

```text
infrastructure/
├── compose.yaml                    # Ghép bốn service và override staging
├── compose/
│   ├── postgres.yaml               # Database, volume dữ liệu, health check
│   ├── backend.yaml                # Image backend, env và kết nối database
│   ├── frontend.yaml               # Image frontend, health check và log
│   └── gateway.yaml                # Nginx, dependency và health check backend
├── environments/
│   ├── staging/
│   │   ├── .env.example            # Mẫu biến runtime, được lưu trong Git
│   │   ├── compose.override.yaml   # Cổng public và mount Nginx/TLS
│   │   ├── .env                    # Chỉ trên VPS: DB/JWT/mail thực tế
│   │   └── images.env              # Chỉ trên VPS: hai image đang được chọn
│   └── production/.gitkeep
├── nginx/
│   ├── staging.conf                # HTTPS, proxy frontend/API và health
│   └── production/.gitkeep
├── scripts/
│   ├── deploy.sh                   # Chọn image, validate, pull/up và lưu phiên bản
│   ├── health-check.sh             # Kiểm tra HTTPS, HTML frontend và backend UP
│   └── rollback/.gitkeep
└── .github/workflows/
    ├── validate.yml
    ├── test-vps.yml
    ├── deploy-staging.yml
    └── production/.gitkeep
```

`.gitignore` bỏ qua secret và phiên bản runtime. `.gitattributes` giữ LF cho
Bash/YAML/Nginx. Production và script rollback còn là thư mục giữ chỗ.

Compose project giữ tên `hotel-booking-staging`. Mọi đường dẫn mount tương đối
được tính từ thư mục gốc repo. Chỉ gateway publish cổng 80/443; PostgreSQL và
backend giao tiếp trong mạng Docker.

Backend chờ PostgreSQL healthy. Gateway chờ frontend healthy và backend started,
sau đó health check của gateway kiểm tra cả `/healthz` và backend trả status UP.
Backend không có health check riêng bên trong image Java. Nginx chuyển `/api/`
và `/actuator/health` tới backend:8080, trang web tới frontend:80.

## Vai trò các workflow

| Workflow | Khi nào chạy | Kiểm tra/thao tác |
| --- | --- | --- |
| `validate.yml` | PR, push main hoặc thủ công | Cú pháp Bash và Compose với giá trị mẫu; không chạy container |
| `test-vps.yml` | Thủ công | SSH, tài khoản đăng nhập, Docker, phiên bản Compose và quyền ghi /opt/hotel-booking |
| `deploy-staging.yml` | Thay đổi cấu hình trên main hoặc thủ công | Validate, chuyển cấu hình, deploy và kiểm tra domain công khai |

`test-vps.yml` không thay đổi container, không kiểm tra secret runtime, chứng chỉ
TLS, quyền pull GHCR hoặc chức năng ứng dụng. Dòng `SSH_DOCKER_OK` chỉ xác nhận
những kiểm tra kết nối/quyền Docker trong workflow đã qua.

## Chuẩn bị VPS trước lần deploy đầu

VPS dùng Ubuntu; runner GitHub Actions dùng Ubuntu 24.04. Tài khoản `deploy` cần:

- Dùng được Docker Engine và Docker Compose hỗ trợ `include`.
- Ghi được vào `/opt/hotel-booking` và các thư mục runtime bên dưới.
- Đăng nhập GHCR với quyền pull cả package frontend và backend nếu chúng private.
- Có TLS tại `/etc/hotelbooking/tls/staging.pem` và `staging.key`.
- Domain staging trỏ tới VPS; nếu qua Cloudflare, cấu hình Full (strict).

Tạo repository secrets trong repo infrastructure:

| Secret | Nội dung |
| --- | --- |
| `VPS_HOST` | IP hoặc hostname VPS |
| `VPS_USER` | Tài khoản deploy |
| `VPS_SSH_KEY` | Private key SSH của tài khoản deploy |
| `VPS_KNOWN_HOSTS` | Host key đã xác minh, khớp VPS_HOST |

Trên VPS, dùng tài khoản deploy tạo file runtime dựa theo
`environments/staging/.env.example` trong repo:

```bash
cd /opt/hotel-booking
mkdir -p environments/staging
umask 077
nano environments/staging/.env
```

Điền đủ biến PostgreSQL, JWT và mail. Có thể tạo mật khẩu DB bằng
`openssl rand -hex 24` và khóa JWT bằng `openssl rand -base64 32` cho lần thiết lập
đầu. Giữ các giá trị này giữa các lần deploy. File thật không được commit hoặc
chuyển từ runner bằng gói cấu hình.

`MAIL_HOST=localhost` và `MAIL_PORT=1025` trong mẫu chỉ phục vụ khởi tạo ứng dụng;
chưa có SMTP tại địa chỉ đó để gửi email. Khi làm luồng email, dùng cấu hình SMTP
thực tế và URL xác minh khớp frontend.

Chuẩn bị cả hai digest trong `environments/staging/images.env` trên VPS, hoặc
truyền cả hai input ở lần deploy đầu. Định dạng được chấp nhận:

```dotenv
FRONTEND_IMAGE=ghcr.io/68cs-hotel-booking-system/frontend@sha256:<64 lowercase hex characters>
BACKEND_IMAGE=ghcr.io/68cs-hotel-booking-system/backend-api@sha256:<64 lowercase hex characters>
```

Nếu còn file images.env ở gốc VPS theo cấu trúc cũ, chuyển dữ liệu sang vị trí
mới một lần và bổ sung backend digest. Script không tự đọc file cũ hoặc dò
container đang chạy.

Chuẩn bị runtime trước khi merge cấu hình vào main, vì push main có thể tự
kích hoạt deploy. Chạy `test-vps.yml` thủ công để kiểm tra SSH/Docker trước.

## Luồng deploy chính

1. Nhận `frontend_image` và `backend_image`; image không được truyền thì dùng giá trị
   đang lưu trong `environments/staging/images.env`.
2. Kiểm tra digest và Compose với `.env` runtime cùng file image tạm.
3. Pull image, chạy Compose và chờ trạng thái running/healthy.
4. Kiểm tra/reload Nginx, rồi lưu hai phiên bản vào `images.env`.
5. Runner kiểm tra HTTPS, HTML frontend và backend health qua domain staging.

Workflow dùng tar với danh sách cấu hình cần chuyển, không gửi `.env` hoặc
`images.env` runtime. Giải nén dùng `--overwrite` để cập nhật file tại chỗ,
giữ inode của file Nginx đang được bind mount vào gateway.

File tạm bảo vệ thông tin phiên bản nếu các bước nội bộ thất bại; không tự
hoàn tác container hoặc migration đã chạy. Public health check diễn ra sau khi
lưu phiên bản. Chưa có rollback/backup tự động.

Lần deploy thành công có đủ:

```text
GATEWAY_DEPLOY_OK
HTTPS_OK
FRONTEND_OK
BACKEND_OK
```

## Kiểm tra trên VPS

Các lệnh Compose phải nạp cả runtime và image:

```bash
cd /opt/hotel-booking

docker compose \
  --env-file environments/staging/.env \
  --env-file environments/staging/images.env \
  ps

docker compose \
  --env-file environments/staging/.env \
  --env-file environments/staging/images.env \
  logs --tail=50 postgres backend frontend gateway

bash scripts/health-check.sh staging
```

`health-check.sh` cần curl và jq khi chạy trực tiếp trên VPS.

Chạy deploy trực tiếp nếu cần:

```bash
# Dùng lại cả hai phiên bản đang lưu.
bash scripts/deploy.sh staging

# Chỉ cập nhật backend, giữ frontend.
bash scripts/deploy.sh staging "" "$BACKEND_IMAGE"

# Cập nhật cả hai.
bash scripts/deploy.sh staging "$FRONTEND_IMAGE" "$BACKEND_IMAGE"
```

## Nối CI ứng dụng với infra

Trong repo frontend/backend, credential gọi repo infra được lưu bằng secret
`INFRA_DISPATCH_TOKEN`, có quyền Actions read/write trên repo infrastructure.
Credential dispatch khác credential GHCR của tài khoản deploy trên VPS.

Sau publish, caller truyền image kèm digest sang workflow infra:

```bash
# Caller frontend.
gh workflow run deploy-staging.yml \
  --repo 68CS-hotel-booking-system/infrastructure \
  --ref main \
  -f frontend_image="$FRONTEND_IMAGE"

# Caller backend.
gh workflow run deploy-staging.yml \
  --repo 68CS-hotel-booking-system/infrastructure \
  --ref main \
  -f backend_image="$BACKEND_IMAGE"
```

Job gọi workflow thành công chỉ xác nhận yêu cầu đã gửi. Xem lần chạy trong
repo infrastructure để biết kết quả deploy. Khi cần quay lại phiên bản trước,
lấy digest từ release.json của bản phát hành rồi chạy workflow với input đó;
việc quay lại image không tự hoàn tác database migration.
