# Hạ tầng Hotel Booking

Cấu hình cho staging.hotelbooking.id.vn và hotelbooking.id.vn trên cùng VPS,
một gateway chung và hai bộ FE/BE/PostgreSQL riêng. File nguồn đã cấu hình không
đồng nghĩa với VPS đã chuyển sang kiến trúc mới.

## Luồng phát hành

1. feature → PR develop: CI verify; sau merge develop, build/smoke/publish image,
   gọi Deploy staging trong infra.
2. Deploy staging health đạt → ghi state.json trên VPS và artifact staging-release.
3. QA kiểm thử đúng deployment, ghi RUN ID.
4. develop → staging ở hai repo ứng dụng; chờ CI push của cả hai staging đạt.
5. Prepare release nhận release ID mới và RUN ID QA, xác minh sourceTree/CI rồi
   mở PR chứa releases/<id>.json và environments/production/release.json.
6. Review/merge PR infra; staging → main ở FE/BE bằng merge commit, không squash.
7. Sau toàn bộ CI main thành công, mỗi ứng dụng gửi tín hiệu kiểm tra sang infra.
8. Cả hai main phải khớp sourceTree trong release và CI đạt. Required reviewer
   duyệt job production; job kiểm tra lại lựa chọn release/main/CI rồi deploy
   chính cặp digest đã duyệt, không build lại.

Nhánh staging là bước chốt code; môi trường staging vẫn tự cập nhật từ develop.
Image có SHA tag để tra cứu; deploy dùng registry digest. Merge commit đổi SHA
nhưng sourceTree có thể giữ nguyên. Không chọn lại image mới nhất khi phát hành.

## File và trách nhiệm

| File | Trách nhiệm |
| --- | --- |
| compose.app.yaml | Ba service ứng dụng, profile và alias theo môi trường |
| compose/{postgres,backend,frontend}.yaml | Cấu hình service tái sử dụng |
| compose/gateway.shared.yaml | Gateway project riêng, duy nhất mở 80/443 |
| nginx/staging.edge.conf, nginx/production/default.conf | Hai virtual host và Docker DNS |
| scripts/deploy.sh | Chọn image, validate, pull/up, public health, lưu images.env |
| scripts/remote-deploy.sh | SSH từ runner, gửi source theo env/infra SHA, health/snapshot |
| scripts/snapshot-release.sh | Lấy metadata từ container thực tế, ghi state.json |
| scripts/check-release.sh | Xác minh nguồn gốc image từ CI producer, sourceTree và CI staging/main của cả FE/BE |
| scripts/check-production-selection.sh | Chặn release lỗi thời và thiếu reviewer |
| .github/workflows/validate.yml | Bash/Compose và bảo vệ release đã có |
| .github/workflows/deploy-staging.yml | Deploy staging, lưu artifact QA |
| .github/workflows/prepare-release.yaml | Chốt snapshot thành PR release |
| .github/workflows/deploy-production.yml | Chờ nguồn/CI/reviewer, deploy production |
| .github/workflows/test-vps.yml | Kiểm tra SSH/Docker cơ bản, không deploy |

compose.yaml, compose/gateway.yaml, environments/staging/compose.override.yaml
và nginx/staging.conf là entry point/cấu hình cũ, giữ lại phục vụ chuyển đổi.
Các workflow deploy mới dùng compose.app.yaml. Không xóa volume khi chuyển.

## State và source trên VPS

    /opt/hotel-booking/
      gateway/                         source/mount của gateway chung
      deployments/
        staging/<infra-sha>/           source ứng dụng cho staging
        production/<infra-sha>/        source ứng dụng cho production
      environments/
        staging/{.env,images.env,state.json}
        production/{.env,images.env,state.json}

Staging giữ project name hotel-booking-staging để tiếp tục dùng volume
hotel-booking-staging_postgres_data. Production dùng hotel-booking-production,
volume và default network riêng. Chỉ FE/BE nối thêm hotel-booking-edge; PostgreSQL
không nối mạng edge. Trên cùng VPS, hai môi trường vẫn chia sẻ CPU/RAM.

.env là secret runtime. images.env là lựa chọn image sau public health từ VPS.
state.json được ghi sau public health từ runner; artifact theo RUN ID là snapshot
QA dùng cho Prepare release. Run thất bại không đủ điều kiện để tạo release.
releases/*.json được lưu trong Git và không được sửa/xóa sau khi đã vào main.

## GitHub cần cấu hình

Trong FE/BE: INFRA_DISPATCH_TOKEN, fine-grained PAT có Actions read/write trên
repo infrastructure. Không dùng token này cho GHCR hoặc đặt trong VITE_*.

Trong infra:

| Secret | Phạm vi | Quyền/nội dung |
| --- | --- | --- |
| VPS_HOST / VPS_USER | Repository (staging) | SSH target của tài khoản deploy staging |
| VPS_SSH_KEY / VPS_KNOWN_HOSTS | Repository (staging) | Private key staging và host key đã xác minh |
| PRODUCTION_VPS_HOST / PRODUCTION_VPS_USER | Environment `production` (chỉ đặt ở scope environment) | SSH target của tài khoản deploy production riêng |
| PRODUCTION_VPS_SSH_KEY / PRODUCTION_VPS_KNOWN_HOSTS | Environment `production` (chỉ đặt ở scope environment) | Private key production riêng và host key đã xác minh |
| APP_READ_TOKEN | Repository | Contents read + Actions read trên frontend và backend-api |

Prepare release dùng GITHUB_TOKEN của chính infra với Contents write,
Pull requests write, Actions read. Bật Settings → Actions → General →
Allow GitHub Actions to create and approve pull requests. Workflow chỉ tạo PR,
không approve hoặc merge PR. Nếu PR của bot hiện Approve workflows to run,
người có quyền write cần phê duyệt việc chạy CI.

Bảo vệ main infra: require PR, một review, check validate; không force push,
không xóa nhánh, không bypass các check. FE/BE giữ quy tắc PR
develop → staging → main và required check verify tương ứng.

Trong infra tạo environment production, required reviewer và giới hạn branch
main. Reviewers phụ thuộc loại repo/gói GitHub; workflow kiểm tra cấu hình
reviewer qua API và sẽ từ chối deploy nếu thiếu.

Production mặc định tắt. Sau khi VPS/TLS/runtime/reviewer đã được chuẩn bị,
tạo Repository Actions variable:

    PRODUCTION_DEPLOY_ENABLED=true

Nếu chưa có biến này, workflow ghi Production disabled và không deploy.
APP_READ_TOKEN là repository secret để cả job check và job deploy đọc được.

### Tách ranh giới SSH giữa staging và production

- Bộ secret `PRODUCTION_VPS_*` CHỈ được khai báo trong GitHub Environment `production`
  (không khai báo ở mức repository). `deploy-production.yml` và `scripts/remote-deploy.sh`
  không bao giờ fallback sang `VPS_*`; workflow sẽ dừng ngay nếu thiếu bất kỳ secret
  `PRODUCTION_VPS_*` nào hoặc nếu `PRODUCTION_VPS_USER@PRODUCTION_VPS_HOST` trùng với
  `VPS_USER@VPS_HOST` của staging.
- Dùng cặp khóa SSH riêng và tài khoản OS riêng không phải `root` cho mỗi môi trường
  (ví dụ `deploy-staging` và `deploy-production`), hoặc tách riêng VPS cho production.
- **Giới hạn quyền Docker/OS:** Nếu hai tài khoản OS trên cùng VPS đều nằm trong cùng
  nhóm `docker` (rootful daemon), cả hai đều có quyền tương đương root đối với mọi
  container — tài khoản staging vẫn có thể thao tác workload `hotel-booking-production`.
  Để tạo ranh giới thực sự, cần chọn một trong các biện pháp sau:
  1. Tách riêng VPS cho staging và production (khuyến nghị).
  2. Chạy rootless Docker daemon riêng theo từng user OS và tách quyền sở hữu thư mục
     `/opt/hotel-booking/{deployments,environments}/{staging,production}` (`chmod 700`).
  3. Giới hạn từng khóa trong `~/.ssh/authorized_keys` bằng `forced-command`
     (`command="/usr/local/sbin/hotel-deploy-wrapper staging",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty`)
     chỉ cho phép wrapper thực thi các thao tác Compose/thư mục của đúng môi trường tương ứng.
- **Cách kiểm toán fingerprint và quyền (không xuất private key):**

      # 1. Đối chiếu SHA256 fingerprint khóa công khai của hai user phải khác nhau
      sudo ssh-keygen -lf /home/deploy-staging/.ssh/authorized_keys
      sudo ssh-keygen -lf /home/deploy-production/.ssh/authorized_keys

      # 2. Kiểm tra tùy chọn forced-command/forwarding trong authorized_keys
      sudo grep -v '^[[:space:]]*#' /home/deploy-staging/.ssh/authorized_keys | cut -d' ' -f1-2
      sudo grep -v '^[[:space:]]*#' /home/deploy-production/.ssh/authorized_keys | cut -d' ' -f1-2

      # 3. Kiểm tra nhóm OS, sudo và quyền thư mục từng môi trường
      id deploy-staging && sudo -l -U deploy-staging
      id deploy-production && sudo -l -U deploy-production
      ls -ld /opt/hotel-booking/environments/staging /opt/hotel-booking/environments/production

## Chuẩn bị/chuyển VPS

Thực hiện thứ tự trong docs/vps-shared-gateway.md TRƯỚC khi push/merge cấu hình
deploy mới vào main infra. Gateway staging hiện tại đang giữ 80/443; cần một
khoảng bảo trì ngắn để chuyển sang gateway chung. Production chỉ bật sau khi
staging đã vận hành tốt với cấu hình mới.

Yêu cầu: Docker/Compose, curl, jq, quyền ghi /opt/hotel-booking, pull được cả hai
package GHCR, hai domain trỏ đúng VPS, TLS cho từng domain. Giữ DB/user/password
staging hiện tại. .env.example không chứa secret thực tế.

SMTP mẫu chưa phải dịch vụ mail đang hoạt động. Backend Compose hiện truyền
host/port; SMTP auth/STARTTLS cần cấu hình tương ứng với nhà cung cấp trước QA mail.

[Test VNPAY sandbox trên staging](docs/vnpay-staging.md): cấu hình runtime trên VPS,
truyền env vào container, triển khai FE/BE, chuyển IPN từ ngrok và kiểm tra giao dịch.

## Sử dụng sau khi chuyển đổi

Deploy staging: Actions → Deploy staging, main, tùy chọn frontend_image và
backend_image. Bỏ trống một thành phần để giữ image đang lưu. Lần đầu cần đủ hai
digest hoặc images.env đã có cặp hợp lệ. Cả hai image phải đã rebuild với label
io.hotelbooking.source-tree. Giá trị label thiếu/sai sẽ chặn snapshot.

Sau QA và CI staging của cả hai repo đạt:
Actions → Prepare release → main → release_id (ví dụ v0.1.0) và staging_run_id.
Workflow tạo PR, không dùng state staging mới nhất. Nếu develop/staging có code
chưa test, không gộp code đó rồi tái sử dụng kết quả QA cũ.

Sau PR release được merge và hai CI main đạt, Deploy production được gọi tự động.
Có thể chạy thủ công để kiểm tra lại. WAIT/Skipped không có nghĩa production đã
deploy. Hai callback FE/BE có thể tạo hai run cùng release; có thể hủy run trùng
đang chờ. Workflow production xếp tuần tự và chặn request chọn release cũ khi
main infra đã chọn bản khác. Sau reviewer, source/CI/selection được kiểm tra lại.

Public health thành công xác nhận HTTPS, HTML FE và Actuator UP; vẫn cần QA
đăng ký/xác minh/login và các chức năng nghiệp vụ đã triển khai.

## Kiểm tra local

Trong PowerShell Windows, dùng Git Bash đã tìm được jq:

    & "C:\Program Files\Git\bin\bash.exe" -n scripts/deploy.sh
    & "C:\Program Files\Git\bin\bash.exe" scripts/health-check.sh staging

Lệnh bash mặc định có thể là WSL launcher, dùng môi trường khác với jq Windows.
Workflow validate nạp env mẫu và giá trị kiểm tra để chạy Compose config; không
khởi động container, không kiểm tra certificate thực tế.

## Giới hạn vận hành

Không có rollback/backup DB tự động hoặc deploy zero downtime. Compose up có thể
đã thay container/migration trước khi health thất bại; file state thành công không
tự hoàn tác chúng. Quay lại image cần kiểm tra tương thích schema; không tự restore
DB vì có thể mất dữ liệu mới phát sinh. Giữ các image đã phát hành trong GHCR.

Không sửa migration đã áp dụng; thêm migration mới và kiểm tra nâng cấp DB có dữ
liệu trước production. Chưa có workflow rollback hoặc tự dọn deployments/.
