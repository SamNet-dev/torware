# Torware

One-click Tor Bridge/Relay node setup and management tool with live TUI dashboard, Snowflake proxy, Lantern Unbounded proxy, and Telegram notifications.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Tor](https://img.shields.io/badge/Tor-supported-purple.svg)

## Screenshots

| Main Menu | Live Dashboard | Settings |
|:---------:|:--------------:|:--------:|
| ![Main Menu](torware-mainmenu.png) | ![Live Stats](torware-livestats.png) | ![Settings](torware-settings.png) |

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/torware/main/torware.sh | sudo bash
```

That's it. The installer will:
- Detect your OS (Ubuntu, Debian, Fedora, CentOS, Arch, Alpine, etc.)
- Install Docker if not already present
- Walk you through an interactive setup wizard
- Start your Tor relay in Docker with auto-restart on boot

## Features

### Relay Types
- **Bridge (obfs4)** — Hidden entry point for censored users. IP not publicly listed. Safest option. *(Default)*
- **Middle Relay** — Routes encrypted traffic within the Tor network. IP is publicly listed but no exit traffic.
- **Exit Relay** — Final hop to the internet. Requires understanding of legal implications. Full warning and confirmation during setup.

### Live TUI Dashboard
Real-time terminal dashboard with 5-second refresh:
- Active circuits and connections
- Bandwidth (download/upload) with totals
- CPU and RAM usage per container and system-wide
- Client countries (24-hour unique clients for bridges)
- Data cap usage (if configured)
- Snowflake proxy stats

### Snowflake WebRTC Proxy
Run a Snowflake proxy alongside your relay to help censored users connect via WebRTC:
- No port forwarding needed (WebRTC handles NAT traversal)
- Configurable CPU and memory limits
- Live connection and traffic stats on the dashboard
- Independent start/stop from the main relay

### Unbounded Proxy (Lantern)
Run Lantern's Unbounded volunteer WebRTC proxy to help censored users through a second circumvention network:
- Built from source automatically during setup
- Live and all-time connection tracking
- Independent management from the menu or CLI
- No port forwarding needed (WebRTC)

### Multi-Container Support
Run up to 5 Tor containers simultaneously:
- Each container gets unique ORPort and ControlPort
- Per-container bandwidth, relay type, and resource limits
- Mixed relay types (e.g., container 1 = bridge, container 2 = middle)
- Add/remove containers from the management menu

### MTProxy (Telegram Proxy)
Run an official Telegram proxy to help censored users access Telegram:
- FakeTLS obfuscation (traffic disguised as HTTPS)
- QR code and link generation for easy sharing
- Send proxy link directly via Telegram bot
- Configurable port, domain, CPU/memory limits
- Connection limits and geo-blocking options
- Host networking for reliable performance

### Telegram Notifications
- Setup wizard with guided BotFather integration
- Periodic status reports (configurable interval + start hour)
- Bot commands: `/tor_status`, `/tor_peers`, `/tor_uptime`, `/tor_containers`, `/tor_snowflake`, `/tor_unbounded`, `/tor_mtproxy`, `/tor_start_N`, `/tor_stop_N`, `/tor_restart_N`, `/tor_help`
- Send MTProxy link & QR code via bot
- Alerts for high CPU, high RAM, all containers down, or zero connections
- Daily and weekly summary reports
- Uses `/tor_` prefix so the bot can be shared with other services

### Background Traffic Tracker
- ControlPort event subscription for real-time bandwidth and circuit data
- Country-level traffic aggregation via GeoIP
- Cumulative statistics persisted to disk
- Runs as a systemd service (or OpenRC/SysVinit)

### Health Check
15-point diagnostic covering:
- Docker daemon status
- Container state and restart count
- ControlPort connectivity and cookie authentication
- Data volume integrity
- Network mode verification
- Relay fingerprint validation
- Snowflake proxy and metrics endpoint
- GeoIP and system tool availability

### About & Learn
Built-in educational section covering:
- What is Tor and how it works
- Bridge, Middle, and Exit relay explanations
- Snowflake proxy details
- How Tor circuits work (with ASCII diagram)
- Dashboard metrics explained
- Legal and safety considerations
- Port forwarding guide for home users

## CLI Commands

```
torware start           Start all relay containers
torware stop            Stop all relay containers
torware restart         Restart all relay containers
torware status          Show relay status summary
torware dashboard       Open live TUI dashboard
torware stats           Open advanced statistics
torware peers           Show live peers by country
torware logs            View container logs
torware health          Run health check
torware fingerprint     Show relay fingerprint(s)
torware bridge-line     Show bridge line(s) for sharing
torware snowflake       Snowflake proxy management
torware unbounded       Unbounded proxy status
torware mtproxy         MTProxy (Telegram) status and link
torware backup          Backup Tor identity keys
torware restore         Restore from backup
torware uninstall       Remove Torware and containers
torware menu            Open interactive menu
torware help            Show help
torware version         Show version
```

Or just run `torware` with no arguments to open the interactive menu.

## Requirements

- **OS**: Linux (Ubuntu, Debian, Fedora, CentOS, RHEL, Arch, Alpine, openSUSE, Raspbian)
- **RAM**: 512 MB minimum (1 GB+ recommended for multiple containers)
- **Docker**: Installed automatically if not present
- **Ports**: 9001 TCP (ORPort), 9002 TCP (obfs4) — must be forwarded if behind NAT
- **Root**: Required for Docker and system service management

## Port Forwarding (Home Users)

If running from home behind a router, you must forward these ports:

| Port | Protocol | Purpose |
|------|----------|---------|
| 9001 | TCP | Tor ORPort |
| 9002 | TCP | obfs4 pluggable transport |

Log into your router (usually `192.168.1.1` or `10.0.0.1`), find **Port Forwarding**, and add both TCP forwards to your server's local IP.

Snowflake does **not** need port forwarding — WebRTC handles NAT traversal automatically.

## Docker Images

| Relay Type | Image |
|------------|-------|
| Bridge (obfs4) | `thetorproject/obfs4-bridge:0.24` |
| Middle/Exit Relay | `osminogin/tor-simple:0.4.8.10` |
| Snowflake Proxy | `thetorproject/snowflake-proxy:latest` |
| Unbounded Proxy | `torware/unbounded-widget:latest` (built from source) |
| MTProxy (Telegram) | `nineseconds/mtg:2.1.7` |

## File Structure

```
/opt/torware/
├── settings.conf              # Configuration
├── torware                    # Management script (symlinked to /usr/local/bin/torware)
├── torware-tracker.sh         # Background ControlPort monitor
├── backups/                   # Tor identity key backups
├── relay_stats/               # Tracker data
│   ├── cumulative_data        # Country|InBytes|OutBytes
│   ├── cumulative_ips         # Country|IP
│   ├── tracker_snapshot       # Real-time 15s window
│   └── geoip_cache            # IP to Country cache
└── containers/                # Per-container torrc files
    ├── relay-1/torrc
    ├── relay-2/torrc
    └── ...
```

## Configuration

All settings are stored in `/opt/torware/settings.conf` and can be changed via the Settings menu or by editing the file directly.

Key settings:
- `RELAY_TYPE` — bridge, middle, or exit
- `NICKNAME` — your relay's nickname on the Tor network
- `CONTACT_EMAIL` — contact for directory authorities
- `BANDWIDTH` — bandwidth rate limit (Mbit/s)
- `CONTAINER_COUNT` — number of Tor containers (1-5)
- `DATA_CAP` — monthly data cap (GB), 0 for unlimited
- `SNOWFLAKE_ENABLED` — true/false
- `SNOWFLAKE_CPUS` / `SNOWFLAKE_MEMORY` — Snowflake resource limits
- `UNBOUNDED_ENABLED` — true/false
- `UNBOUNDED_CPUS` / `UNBOUNDED_MEMORY` — Unbounded resource limits
- `MTPROXY_ENABLED` — true/false
- `MTPROXY_PORT` — Telegram proxy port (default: 8443)
- `MTPROXY_DOMAIN` — FakeTLS domain (default: cloudflare.com)
- `MTPROXY_CPUS` / `MTPROXY_MEMORY` — MTProxy resource limits

Per-container overrides: `RELAY_TYPE_N`, `BANDWIDTH_N`, `ORPORT_N` (where N is the container index).

## Uninstall

```bash
sudo torware uninstall
```

This will stop and remove containers, remove systemd services, and optionally delete configuration and backups.

## Contributing

Contributions are welcome. Please open an issue or pull request on GitHub.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Changelog

### v1.1 — Feature Patch
- **MTProxy (Telegram Proxy)** — Run an official Telegram proxy to help censored users access Telegram
  - FakeTLS obfuscation (traffic looks like HTTPS to cloudflare.com, google.com, etc.)
  - Host networking mode for reliable DNS resolution
  - Prometheus metrics for accurate traffic monitoring
  - QR code generation for easy sharing
  - Telegram bot integration: send proxy link & QR via `/tor_mtproxy` command
  - Menu option to send link via Telegram after setup or changes
  - Port change warnings (alerts when proxy URL changes)
  - Security settings: connection limits, geo-blocking by country
  - CLI command: `torware mtproxy`
  - Setup wizard integration (standalone or as add-on)
- **Lantern Unbounded Proxy** — Run Lantern's Unbounded volunteer WebRTC proxy alongside your relay to help censored users access the internet through a second censorship-circumvention network
  - Built from source during Docker image creation (pinned to production-compatible commit)
  - Live and all-time connection tracking on the dashboard
  - Full menu management: start, stop, restart, disable, change resources, remove
  - Telegram bot command: `/tor_unbounded`
  - CLI command: `torware unbounded`
  - Health check integration
  - Setup wizard integration (standalone or as add-on to any relay type)
  - About & Learn section explaining Unbounded/Lantern
- **Docker images pinned** — All images now use specific version tags for reproducibility (no more `:latest`)
- **Security improvements**
  - Sanitized settings file loading (explicit parsing instead of bash source)
  - Bash 4.2+ requirement for safer variable handling
  - Health checks for all containers (Tor relays, Snowflake, Unbounded, MTProxy)
- **Structured JSON logging** — Optional JSON log format for integration with log aggregators (`LOG_FORMAT=json`)
- **Centralized configuration** — New CONFIG array for cleaner state management
- **Dashboard optimizations**
  - Parallel data fetching for faster refresh
  - All graphs limited to top 5 for better screen fit
  - MTProxy stats integrated into all dashboard views
- **Compact advanced stats** — Merged upload/download country tables into a single combined traffic table
- **Container details alignment** — Fixed table alignment when container names are long
- **View Logs** menu now includes Unbounded and MTProxy containers

### v1.0.1 — Feature Patch
- Fixed dashboard uptime showing N/A
- Added Snowflake traffic to dashboard totals
- Capped Snowflake CPU limit to available cores
- Increased relay startup check to 3 retries (15s total)
- Fixed bridge line fingerprint replacement and PT port
- Fixed bridge line parsing skipping blank lines
- Fixed startup false failure, live map overflow
- Added Snowflake advanced stats section

### v1.0.0
- Initial release with Bridge, Middle, and Exit relay support
- Live TUI dashboard with 5-second refresh
- Snowflake WebRTC proxy support
- Multi-container support (up to 5)
- Telegram bot notifications and commands
- Background traffic tracker with country-level stats
- 15-point health check
- Built-in About & Learn educational section
- CLI commands for all operations
- Auto-install on Ubuntu, Debian, Fedora, CentOS, Arch, Alpine, and more

## Acknowledgments

- [The Tor Project](https://www.torproject.org/) for building and maintaining the Tor network
- [Snowflake](https://snowflake.torproject.org/) for the WebRTC pluggable transport
- [Lantern](https://lantern.io/) for the Unbounded censorship-circumvention proxy
- All Tor relay operators who keep the network running

---

<div dir="rtl">

## فارسی

### تورویر (Torware) چیست؟

تورویر یک ابزار خط فرمان برای راه‌اندازی و مدیریت نودهای شبکه تور (Tor) است. با یک دستور ساده، می‌توانید یک بریج (Bridge)، رله میانی (Middle Relay) یا رله خروجی (Exit Relay) تور را روی سرور خود راه‌اندازی کنید.

### نصب سریع

<div dir="ltr">

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/torware/main/torware.sh | sudo bash
```

</div>

### انواع رله

- **بریج (Bridge)** — نقطه ورود مخفی برای کاربرانی که در کشورهای سانسورشده هستند. آدرس IP شما عمومی نمی‌شود. **امن‌ترین گزینه.** (پیش‌فرض)
- **رله میانی (Middle Relay)** — ترافیک رمزنگاری‌شده را در شبکه تور مسیریابی می‌کند. آدرس IP شما عمومی است اما ترافیک خروجی ندارید.
- **رله خروجی (Exit Relay)** — آخرین گام به اینترنت. نیاز به درک مسائل حقوقی دارد.

### ویژگی‌ها

- **داشبورد زنده** — نمایش لحظه‌ای مدارها، پهنای باند، مصرف CPU/RAM و کشور کاربران
- **پروکسی اسنوفلیک (Snowflake)** — کمک به کاربران سانسورشده از طریق WebRTC بدون نیاز به Port Forwarding
- **پروکسی آنباندد (Unbounded/Lantern)** — اجرای پروکسی داوطلبانه لنترن برای کمک به کاربران سانسورشده از طریق شبکه دوم ضد سانسور
- **پروکسی MTProxy (تلگرام)** — اجرای پروکسی رسمی تلگرام برای کمک به کاربران سانسورشده برای دسترسی به تلگرام
  - پنهان‌سازی FakeTLS (ترافیک شبیه HTTPS به نظر می‌رسد)
  - تولید QR کد و لینک برای اشتراک‌گذاری آسان
  - ارسال لینک مستقیم از طریق ربات تلگرام
- **چند کانتینر** — تا ۵ کانتینر تور همزمان با انواع مختلف رله
- **اعلان‌های تلگرام** — گزارش وضعیت خودکار و دستورات ربات
- **بررسی سلامت** — ۱۵ نقطه تشخیصی برای اطمینان از عملکرد صحیح
- **آموزش داخلی** — توضیح کامل شبکه تور، انواع رله‌ها و مسائل حقوقی

### پیش‌نیازها

- **سیستم‌عامل**: لینوکس (اوبونتو، دبیان، فدورا، سنت‌اواس، آرچ، آلپاین و...)
- **رم**: حداقل ۵۱۲ مگابایت (۱ گیگابایت یا بیشتر توصیه می‌شود)
- **داکر**: در صورت نبودن، به صورت خودکار نصب می‌شود
- **پورت‌ها**: 9001 TCP و 9002 TCP — اگر پشت NAT هستید باید Port Forward کنید

### Port Forwarding (کاربران خانگی)

اگر از خانه و پشت روتر اجرا می‌کنید، باید این پورت‌ها را Forward کنید:

| پورت | پروتکل | کاربرد |
|------|---------|--------|
| 9001 | TCP | پورت اصلی تور (ORPort) |
| 9002 | TCP | انتقال obfs4 |

وارد تنظیمات روتر شوید (معمولا `192.168.1.1` یا `10.0.0.1`)، بخش **Port Forwarding** را پیدا کنید و هر دو پورت TCP را به IP محلی سرور خود Forward کنید.

اسنوفلیک نیازی به Port Forwarding **ندارد** — WebRTC به صورت خودکار از NAT عبور می‌کند.

### خط بریج (Bridge Line)

بعد از راه‌اندازی، خط بریج شما ممکن است چند ساعت تا ۱-۲ روز طول بکشد تا در دسترس قرار بگیرد. تور باید مراحل زیر را طی کند:
1. بوت‌استرپ کامل و تست دسترسی ORPort
2. انتشار توصیفگر به مرجع بریج
3. اضافه شدن به BridgeDB برای توزیع

می‌توانید پیشرفت را با گزینه **Health Check** (شماره ۸ در منو) بررسی کنید.

### چرا بریج اجرا کنیم؟

میلیون‌ها نفر در کشورهایی مانند ایران، چین، روسیه و بسیاری دیگر از کشورها، به دلیل سانسور اینترنت قادر به دسترسی آزاد به اطلاعات نیستند. با اجرای یک بریج تور، شما به این افراد کمک می‌کنید تا:

- به اینترنت آزاد دسترسی پیدا کنند
- اخبار واقعی را بخوانند
- با خانواده و دوستان خود در خارج از کشور ارتباط برقرار کنند
- از حریم خصوصی خود محافظت کنند

**هر بریج مهم است.** حتی یک بریج کوچک با پهنای باند محدود می‌تواند به ده‌ها نفر کمک کند.

### تاریخچه تغییرات

#### نسخه ۱.۱ — وصله ویژگی
- **پروکسی MTProxy (تلگرام)** — اجرای پروکسی رسمی تلگرام برای کمک به کاربران سانسورشده
  - پنهان‌سازی FakeTLS (ترافیک شبیه HTTPS به cloudflare.com یا google.com به نظر می‌رسد)
  - حالت شبکه host برای رفع مشکلات DNS
  - متریک‌های Prometheus برای نظارت دقیق ترافیک
  - تولید QR کد برای اشتراک‌گذاری آسان
  - ارسال لینک و QR کد از طریق ربات تلگرام با دستور `/tor_mtproxy`
  - هشدار هنگام تغییر پورت (اطلاع‌رسانی تغییر URL پروکسی)
  - تنظیمات امنیتی: محدودیت اتصال، مسدودسازی جغرافیایی
  - دستور خط فرمان: `torware mtproxy`
- **پروکسی آنباندد (Unbounded/Lantern)** — اجرای پروکسی داوطلبانه WebRTC لنترن در کنار رله تور برای کمک به کاربران سانسورشده از طریق شبکه دوم ضد سانسور
  - ساخت از سورس‌کد هنگام ایجاد ایمیج داکر (قفل شده روی کامیت سازگار با سرور اصلی)
  - نمایش اتصالات زنده و کل اتصالات در داشبورد
  - مدیریت کامل از منو: شروع، توقف، ری‌استارت، غیرفعال‌سازی، تغییر منابع، حذف
  - دستور ربات تلگرام: `/tor_unbounded`
  - دستور خط فرمان: `torware unbounded`
- **قفل نسخه ایمیج‌های داکر** — همه ایمیج‌ها از تگ نسخه خاص استفاده می‌کنند (بدون `:latest`)
- **بهبودهای امنیتی**
  - بارگذاری امن فایل تنظیمات (پارس صریح به جای source بش)
  - نیاز به بش ۴.۲ به بالا برای مدیریت امن متغیرها
  - بررسی سلامت برای همه کانتینرها
- **لاگ JSON ساختاریافته** — فرمت اختیاری JSON برای یکپارچه‌سازی با سیستم‌های جمع‌آوری لاگ
- **بهینه‌سازی داشبورد**
  - واکشی موازی داده‌ها برای بازخوانی سریع‌تر
  - محدود شدن نمودارها به ۵ مورد برتر
  - یکپارچه‌سازی آمار MTProxy در تمام نماها
- **فشرده‌سازی آمار پیشرفته** — ادغام جداول آپلود/دانلود کشورها در یک جدول واحد
- **منوی مشاهده لاگ** شامل کانتینر آنباندد و MTProxy

#### نسخه ۱.۰.۱ — وصله ویژگی
- رفع نمایش N/A برای آپتایم در داشبورد
- اضافه شدن ترافیک اسنوفلیک به مجموع داشبورد
- محدود شدن CPU اسنوفلیک به هسته‌های موجود
- افزایش تلاش بررسی راه‌اندازی رله به ۳ بار (۱۵ ثانیه)
- رفع خط بریج: جایگزینی فینگرپرینت و استفاده از پورت PT
- رفع پارس خط بریج: رد کردن خطوط خالی
- رفع خطای نادرست شروع، سرریز نقشه زنده
- اضافه شدن بخش آمار پیشرفته اسنوفلیک

#### نسخه ۱.۰.۰
- انتشار اولیه با پشتیبانی از بریج، رله میانی و رله خروجی
- داشبورد زنده TUI با بازخوانی ۵ ثانیه‌ای
- پشتیبانی از پروکسی اسنوفلیک WebRTC
- پشتیبانی از چند کانتینر (تا ۵)
- اعلان‌ها و دستورات ربات تلگرام
- ردیاب ترافیک پس‌زمینه با آمار سطح کشور
- بررسی سلامت ۱۵ نقطه‌ای
- بخش آموزشی داخلی
- دستورات خط فرمان برای تمام عملیات
- نصب خودکار روی اوبونتو، دبیان، فدورا، سنت‌اواس، آرچ، آلپاین و بیشتر

### مجوز

این پروژه تحت مجوز MIT منتشر شده است. فایل [LICENSE](LICENSE) را ببینید.

</div>
