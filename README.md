# Hạ tầng staging Hotel Booking

Frontend staging: https://staging.hotelbooking.id.vn/

## Các file cấu hình

| File | Vai trò |
| --- | --- |
| `compose.yaml` | Container frontend và gateway HTTPS; chọn image qua biến `FRONTEND_IMAGE`. |
| `nginx/default.conf` | HTTPS, proxy frontend và health check của gateway. |
| `.github/workflows/test-vps.yml` | Kiểm tra SSH và quyền sử dụng Docker. |
| `.github/workflows/deploy-staging.yml` | Chuyển cấu hình, chọn image, deploy và kiểm tra HTTPS/HTML. |

VPS dùng Ubuntu 22.04. GitHub Actions chạy trên máy runner Ubuntu 24.04 riêng.
Backend và PostgreSQL chưa được triển khai; các đường dẫn API tạm trả 503.

## Chuẩn bị VPS và GitHub Secrets

- Tài khoản `deploy` chạy được Docker Engine và Docker Compose.
- Tài khoản này ghi được vào `/opt/hotel-booking`.
- `deploy` đã đăng nhập GHCR và có quyền tải package frontend.
- Chứng chỉ và private key nằm tại `/etc/hotelbooking/tls/staging.pem`
  và `/etc/hotelbooking/tls/staging.key`; giữ hai file này trên VPS.
- Cloudflare proxy `staging.hotelbooking.id.vn` về VPS với Full (strict).

Tạo các repository secret sau trong **infrastructure**:

| Secret | Giá trị |
| --- | --- |
| `VPS_HOST` | IP hoặc hostname VPS |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | SSH private key được phép đăng nhập vào `deploy` |
| `VPS_KNOWN_HOSTS` | Dòng SSH host key đã xác minh, khớp `VPS_HOST` |

## Chọn phiên bản frontend

Workflow chỉ chấp nhận image đúng định dạng:

```text
ghcr.io/68cs-hotel-booking-system/frontend@sha256:<64 lowercase hex characters>
```

Workflow chạy khi cấu hình được push vào `main`, hoặc qua `workflow_dispatch`
với input `frontend_image` không bắt buộc:

- Có input: triển khai đúng image được truyền vào.
- Không có input: dùng lại `/opt/hotel-booking/images.env`.
- Chưa có file này: lấy image của service `frontend` đang chạy thuộc Compose
  project `hotel-booking-staging`, rồi tạo file khi triển khai nội bộ thành công.
- Chưa có cả file lẫn container đang chạy: truyền input cho lần triển khai đầu.

Workflow truyền image vào Compose bằng file env tạm. Sau khi Compose và kiểm tra
Nginx thành công, file được lưu thành `images.env`. Khi đổi phiên bản, digest cũ
được ghi vào `images.previous.env`.

Các file phiên bản chỉ nằm trên VPS, không bị bước SCP ghi đè và không chứa token.
Sau bước SSH, workflow kiểm tra HTTPS và HTML qua domain công khai. Nếu kiểm tra
thất bại, workflow báo đỏ; chưa tự động rollback container.
Để rollback, chạy workflow thủ công với digest của image trước đó.

Kiểm tra trên VPS bằng tài khoản `deploy`:

```bash
cd /opt/hotel-booking
cat images.env
docker compose --env-file images.env ps
docker compose --env-file images.env logs --tail=50 gateway frontend
```

## Nối CI frontend với workflow infra

Phía nhận của infra sẵn sàng sau khi workflow này được merge vào `main` của infra.
Repo frontend cần được cấu hình thêm như sau:

1. Tạo fine-grained PAT hoặc GitHub App credential giới hạn vào repo infra,
   có quyền **Actions: read and write**. PAT `read:packages` trên VPS dùng để kéo
   image, không phải token kích hoạt workflow.
2. Lưu token vào **repository secret của frontend** tên `INFRA_DISPATCH_TOKEN`.
3. Thêm job dưới đây vào `.github/workflows/ci.yml` của frontend, cùng mức với
   `verify` và `publish`, rồi đưa thay đổi qua PR vào `develop`:

```yaml
  deploy-staging:
    name: Trigger staging deployment
    needs: publish
    if: github.event_name == 'push' && github.ref == 'refs/heads/develop'
    runs-on: ubuntu-24.04
    timeout-minutes: 5

    steps:
      - name: Trigger infrastructure deployment
        env:
          GH_TOKEN: ${{ secrets.INFRA_DISPATCH_TOKEN }}
          FRONTEND_IMAGE: ${{ needs.publish.outputs.image }}
        run: |
          set -euo pipefail
          : "${GH_TOKEN:?Missing INFRA_DISPATCH_TOKEN}"
          : "${FRONTEND_IMAGE:?Missing published frontend image}"

          gh workflow run deploy-staging.yml \
            --repo 68CS-hotel-booking-system/infrastructure \
            --ref main \
            -f frontend_image="$FRONTEND_IMAGE"
```

Job CI frontend chỉ gửi yêu cầu triển khai; cần xem lần chạy riêng trong infra để
biết kết quả deploy. Lần chạy infra thành công có đủ `GATEWAY_DEPLOY_OK`,
`HTTPS_OK` và `FRONTEND_OK`.

## Phạm vi hiện tại

- Phía infra đã hỗ trợ nhận phiên bản và triển khai frontend.
- Tự động kích hoạt từ frontend cần thêm job và secret nêu trên.
- Chưa triển khai backend, rollback tự động hoặc lịch backup.
