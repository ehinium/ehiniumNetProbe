<!--
Language switch:
- English: scroll down
- فارسی: پایین‌تر
-->

# ehiniumNetProbe

[English](#about) | [فارسی](#درباره)

---

## About

ehiniumNetProbe is a lightweight network diagnostic tool focused on testing real connectivity between two servers.

Instead of checking a single protocol in isolation, it verifies whether actual packets can be exchanged end-to-end over different transport layers (ICMP, TCP, UDP, and TLS). This makes it possible to see which protocols work, which partially work, and which are blocked or unstable between two points.

By combining basic reachability tests, throughput measurements, and long-running stability (soak) checks, the tool helps identify:
- whether TCP or UDP traffic is allowed
- whether TLS handshakes succeed reliably
- whether connections degrade or drop after repeated use
- which types of tunnels or encapsulations are likely to work between the two servers

---

### Features
- Interactive menu (Client or Server)
- Test suites:
  - Express Test (all checks)
  - Baseline Connectivity Test (icmp, tcp connect, tcp/udp echo, tls)
  - Throughput Test (iperf3 tcp + udp)
  - Stability Soak Test (tcp + tls repeated checks)
  - Custom Test (tune ports, loops, output format, optional TSV)
- Multiple hosts supported (comma separated) for Baseline and Throughput tests

---

### Requirements

Server:
- openssl
- iperf3
- socat or python3
- netcat (nc) or python3

Client:
- ping
- netcat (nc)
- openssl
- iperf3
- socat or python3

Install (Ubuntu):
```bash
sudo apt update
sudo apt install -y iperf3 openssl netcat-openbsd socat
```

---

### Usage

#### Download and run latest version
```bash
curl -fsSL https://raw.githubusercontent.com/ehinium/ehiniumNetProbe/main/ehiniumNetProbe.sh -o ehiniumNetProbe.sh
chmod +x ehiniumNetProbe.sh
./ehiniumNetProbe.sh
```

Run the same command again to update.

---

#### Server mode
Run on the target server:
```bash
sudo ./ehiniumNetProbe.sh
```
Choose **Server** mode and keep it running.

---

#### Client mode
Run from another machine:
```bash
./ehiniumNetProbe.sh
```
Choose **Client** mode and enter target host (or multiple hosts where supported).

---

#### Optional: install globally
```bash
sudo mv ehiniumNetProbe.sh /usr/local/bin/ehiniumNetProbe
sudo chmod +x /usr/local/bin/ehiniumNetProbe
ehiniumNetProbe
```


---


## درباره


ehiniumNetProbe یک ابزار سبک برای عیب‌یابی اتصال شبکه بین دو سرور است.

به‌جای بررسی یک پروتکل به‌صورت تکی، این ابزار بررسی می‌کند که آیا پکت‌های واقعی می‌توانند به‌صورت end-to-end بین دو سرور رد و بدل شوند یا نه. به این شکل می‌توان مشخص کرد که کدام پروتکل‌ها کار می‌کنند، کدام‌ها به‌صورت ناقص کار می‌کنند، و کدام‌ها مسدود یا ناپایدار هستند.

با ترکیب تست‌های پایه اتصال، اندازه‌گیری سرعت، و تست‌های پایداری بلندمدت (Soak)، این ابزار کمک می‌کند بفهمیم:
- آیا ترافیک TCP یا UDP اجازه عبور دارد یا نه
- آیا هندشیک TLS به‌صورت پایدار انجام می‌شود
- آیا اتصال بعد از چند بار استفاده دچار افت یا قطع می‌شود 
- چه نوع تونل‌ها یا روش‌های انتقال احتمالا بین این دو سرور قابل استفاده هستند 

---

### قابلیت‌ها
- منوی تعاملی (Client یا Server)
- انواع تست:
  - Express Test: همه تست‌ها
  - Baseline Connectivity Test: ping، tcp connect، tcp/udp echo، tls
  - Throughput Test: تست سرعت iperf3 (TCP و UDP)
  - Stability Soak Test: بررسی پایداری اتصال TCP و TLS
  - Custom Test: تنظیم پورت‌ها، تعداد تکرار، فرمت خروجی
- امکان تست چند سرور به‌صورت همزمان (با کاما) در Baseline و Throughput

---

### پیش‌نیازها

در حالت Server:
- openssl
- iperf3
- socat یا python3
- netcat (nc) یا python3

در حالت Client:
- ping
- netcat (nc)
- openssl
- iperf3
- socat یا python3

نصب در اوبونتو:
```bash
sudo apt update
sudo apt install -y iperf3 openssl netcat-openbsd socat python3
```

---

### نحوه استفاده

#### دانلود و اجرای آخرین نسخه
```bash
curl -fsSL https://raw.githubusercontent.com/ehinium/ehiniumNetProbe/main/ehiniumNetProbe.sh -o ehiniumNetProbe.sh
chmod +x ehiniumNetProbe.sh
./ehiniumNetProbe.sh
```

برای بروزرسانی، همین دستور را دوباره اجرا کنید.

---

#### حالت Server
روی سرور مقصد اجرا کنید:
```bash
sudo ./ehiniumNetProbe.sh
```
حالت **Server** را انتخاب کرده و اسکریپت را روشن نگه دارید.

---

#### حالت Client
روی سرور یا سیستم دیگر اجرا کنید:
```bash
./ehiniumNetProbe.sh
```
حالت **Client** را انتخاب کرده و آدرس سرور (یا چند آدرس) را وارد کنید.

---

#### نصب سراسری (اختیاری)
```bash
sudo mv ehiniumNetProbe.sh /usr/local/bin/ehiniumNetProbe
sudo chmod +x /usr/local/bin/ehiniumNetProbe
ehiniumNetProbe
```
