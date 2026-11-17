# Kiểm thử VNPAY sandbox trên staging

Website staging: <https://staging.hotelbooking.id.vn>. Cổng thanh toán vẫn dùng VNPAY sandbox; không thu tiền thật. Staging dùng database và cấu hình riêng, không dùng PostgreSQL/Mailpit/ngrok trên máy local.

## 1. Chuẩn bị code và hạ tầng

Cần triển khai cùng đợt:

- Backend: controller/service VNPAY, cấu hình, public GET IPN, migration `V20261115120000000__create_vnpay_payments.sql` và tích hợp xác nhận booking/tồn phòng.
- Frontend: nối nút tạo booking trên trang `/stays/:hotelId`, nút thanh toán và trang `/payment/return` đọc kết quả từ server.
- Infrastructure: `compose/backend.yaml` truyền `VNPAY_*`, `AUTH_COOKIE_SECURE` vào container; file mẫu staging ghi các URL HTTPS.

Các thay đổi chỉ xuất hiện trên staging sau khi PR được merge, image mới được build và deployment thành công. Không đưa `.env`, key hoặc token vào commit.

Repo infrastructure có workflow **Deploy staging** và dùng `compose.app.yaml`. Hướng dẫn này áp dụng khi VPS đã chuẩn bị gateway chung và mạng `hotel-booking-edge`. Nếu chưa chuyển VPS sang cấu hình này, làm theo [hướng dẫn gateway](vps-shared-gateway.md) trước; không xóa volume hoặc ghi đè database hiện tại bằng file mẫu.

## 2. Điền cấu hình runtime trên VPS

Đăng nhập SSH vào VPS bằng tài khoản deploy của dự án. Chỉnh file **đang có**:

```bash
nano /opt/hotel-booking/environments/staging/.env
```

Đây là file trên VPS, khác `.env` trong thư mục backend trên máy Windows. Giữ nguyên DB/user/password/JWT và các cấu hình đang dùng. Thêm hoặc cập nhật:

```dotenv
VNPAY_ENABLED=true
VNPAY_TMN_CODE=<ma-merchant-sandbox>
VNPAY_HASH_SECRET=<secret-sandbox>
VNPAY_PAYMENT_URL=https://sandbox.vnpayment.vn/paymentv2/vpcpay.html
VNPAY_RETURN_URL=https://staging.hotelbooking.id.vn/payment/return

AUTH_COOKIE_SECURE=true
AUTH_VERIFICATION_URL=https://staging.hotelbooking.id.vn/verify-email
AUTH_PASSWORD_RESET_URL=https://staging.hotelbooking.id.vn/reset-password
```

Thay các placeholder bằng credential merchant sandbox. Không dùng credential production. Compose mặc định để VNPAY tắt nếu chưa cấu hình, tránh chặn các môi trường chưa bật thanh toán.

Để đăng ký/xác minh email trên staging, cấu hình SMTP thực sự truy cập được từ container backend. Ví dụ Resend, nếu dự án đã có sender/domain được xác minh:

```dotenv
MAIL_HOST=smtp.resend.com
MAIL_PORT=587
MAIL_USERNAME=resend
MAIL_PASSWORD=<api-key-smtp>
MAIL_SMTP_AUTH=true
MAIL_STARTTLS_ENABLE=true
MAIL_STARTTLS_REQUIRED=true
AUTH_MAIL_FROM=<dia-chi-gui-da-xac-minh>
```

Cũng có thể dùng dịch vụ SMTP thử nghiệm của staging. `MAIL_HOST=localhost` chỉ tới chính container backend; không tới Mailpit trên máy bạn. File `.env.example` hiện có phần SMTP mặc định chỉ đủ cho kiểm tra khởi động, không chứng minh gửi email hoạt động.

## 3. Đưa bản đã sửa lên staging

Theo pipeline đang có trong repo:

1. Tạo/review PR cấu hình infrastructure vào `main` theo quy tắc của repo. Thay đổi Compose sẽ được workflow **Deploy staging** sử dụng. Runtime `.env` phải được chuẩn bị trước.
2. Đưa thay đổi backend và frontend qua PR từ nhánh tính năng vào `develop`, chờ required checks thành công rồi merge.
3. Push/merge `develop` ở mỗi ứng dụng sẽ build, smoke test, publish image và gọi **Deploy staging** của infrastructure với digest tương ứng. Chờ deployment của cả FE và BE thành công.
4. Khi cần chạy lại với cùng image (ví dụ sau khi sửa `.env` trên VPS), vào repo **infrastructure → Actions → Deploy staging → Run workflow**, chọn `main`. Bỏ trống `frontend_image` và `backend_image` để giữ cặp image trong `images.env` đã có trên VPS. Lần đầu chưa có cặp image phải cung cấp đủ digest hợp lệ từ bước publish.
5. Ghi lại RUN ID/artifact `staging-release` của deployment sẽ được kiểm thử, tránh nhầm kết quả với lần deploy khác.

Môi trường staging hiện tự cập nhật từ **develop**. Nhánh tên `staging` là bước chốt phát hành, không phải điều kiện bắt buộc để bắt đầu QA staging. Merge `main` của FE/BE là luồng production riêng.

Không cần chạy Maven/Vite/ngrok trên Windows để website staging hoạt động. Frontend dùng `/api/v1` cùng origin, gateway chuyển request tới backend; `API_PROXY_TARGET` chỉ dành cho Vite dev.

Flyway tự tạo bảng giao dịch khi image backend mới khởi động. Thay đổi runtime `.env` cần container được tạo lại qua deployment để nhận env mới; chỉ tải lại trình duyệt không cập nhật env container.

## 4. Chuyển IPN sang staging

Trong merchant sandbox VNPAY, cấu hình Terminal đúng `VNPAY_TMN_CODE`, đặt IPN URL:

```text
https://staging.hotelbooking.id.vn/api/v1/payments/vnpay/ipn
```

Return URL đã được backend gửi trong URL thanh toán:

```text
https://staging.hotelbooking.id.vn/payment/return
```

Với merchant hiện có một IPN URL, đổi từ ngrok sang staging sẽ chuyển thông báo sang backend staging. Vì database local và staging khác nhau, nên test staging riêng; muốn chạy hai nơi độc lập đồng thời cần merchant sandbox riêng hoặc cơ chế định tuyến IPN phù hợp.

Không thêm đăng nhập gateway/Basic Auth trước IPN. Backend xác thực bằng HMAC-SHA512, mã merchant và dữ liệu giao dịch. Nginx đang giữ nguyên path/query cho `/api/` nên không cần rewrite endpoint này.

## 5. Kiểm tra trước thanh toán

Từ PowerShell trên máy bạn:

```powershell
Invoke-RestMethod -Uri "https://staging.hotelbooking.id.vn/actuator/health"
Invoke-RestMethod -Uri "https://staging.hotelbooking.id.vn/api/v1/payments/vnpay/ipn"
```

- Health cần trả `status=UP`.
- IPN không có chữ ký cần trả HTTP 200, JSON `RspCode=97`, `Message=Invalid Signature`. Đây là kiểm tra endpoint truy cập được, chưa phải giao dịch thành công.
- Nếu IPN trả 401/403/404 hoặc HTML, kiểm tra image backend và route gateway trước khi thanh toán.
- Nếu tạo thanh toán trả 503 `PAYMENT_UNAVAILABLE`, kiểm tra biến VNPAY thực tế đã vào container, không chỉ file `.env`.
- Nếu thanh toán quay về localhost, kiểm tra `VNPAY_RETURN_URL` trong container rồi tạo giao dịch mới; URL đã tạo trước đó vẫn giữ Return URL cũ.

## 6. Kiểm thử trên website

1. Mở <https://staging.hotelbooking.id.vn>, đăng ký/xác minh email hoặc dùng tài khoản test đã xác minh trong **database staging**. Tài khoản local không tự xuất hiện ở staging.
2. Chuẩn bị một khách sạn ACTIVE đang mở bán, hạng phòng/phòng vật lý và giá/tồn khả dụng cho ngày tương lai. Dữ liệu demo của profile `dev` không tự seed trên staging.
3. Tạo booking, xác nhận thông tin liên hệ, bấm thanh toán VNPAY trước hạn giữ phòng.
4. Chọn thẻ nội địa/ngân hàng NCB và dùng thẻ sandbox:

   | Trường | Giá trị |
   | --- | --- |
   | Số thẻ | `9704198526191432198` |
   | Chủ thẻ | `NGUYEN VAN A` |
   | Ngày phát hành | `07/15` |
   | OTP | `123456` |

5. Trình duyệt phải quay về domain staging. Kết quả mong đợi: payment `SUCCEEDED`, `bookingConfirmed=true`, booking `CONFIRMED` và tồn phòng được xác nhận.
6. Tải lại trang, đăng nhập lại nếu cần, kiểm tra `/my-bookings` để xác nhận dữ liệu vẫn được lưu.
7. Thử thêm hủy thanh toán, IPN gọi lặp, hết hạn giữ phòng và bấm tạo đơn/thanh toán nhiều lần. Với IPN thành công nhưng giữ phòng không còn hợp lệ, payment vẫn được lưu và hiển thị cần đối soát; không tự xác nhận lại tồn đã bán cho khách khác.

DB staging là DB trên VPS. pgAdmin đang nối `127.0.0.1:15432` là database local, không phản ánh giao dịch staging. Nếu cần xem DB staging bằng pgAdmin, dùng kết nối SSH tunnel phù hợp với cách VPS đang triển khai; PostgreSQL trong Compose này không publish cổng ra Internet.

Tài liệu: [VNPAY PAY](https://sandbox.vnpayment.vn/apis/docs/thanh-toan-pay/pay.html), [thẻ sandbox](https://sandbox.vnpayment.vn/apis/docs/gioi-thieu/), [pipeline hiện có](../README.md).
