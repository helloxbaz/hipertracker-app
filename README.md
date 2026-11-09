<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="HiperTracker" width="120">
</p>

<h1 align="center">HiperTracker</h1>

<p align="center">GPS tracking app for Hipersign staff and vehicles. It sends the phone's location to the Hipersign Traccar server, so managers can see it live in <b>Hipersign ERP → HiperTracker</b>.</p>

## 📲 Install on an Android phone

<p align="center">
  <a href="https://github.com/helloxbaz/hipertracker-app/releases/latest/download/HiperTracker.apk">
    <img src="https://img.shields.io/badge/Download-HiperTracker%20APK-0b5fff?style=for-the-badge&logo=android&logoColor=white" alt="Download HiperTracker APK" height="56">
  </a>
</p>

<p align="center">
  Or scan with the phone's camera:<br><br>
  <img src="https://api.qrserver.com/v1/create-qr-code/?size=240x240&margin=8&data=https%3A%2F%2Fgithub.com%2Fhelloxbaz%2Fhipertracker-app%2Freleases%2Flatest%2Fdownload%2FHiperTracker.apk" alt="QR code to download HiperTracker" width="240">
</p>

**Direct link:** https://github.com/helloxbaz/hipertracker-app/releases/latest/download/HiperTracker.apk

1. Open the link (or tap the button) on the phone and download **HiperTracker.apk**.
2. Open the downloaded file. If Android asks, allow your browser to **install unknown apps**, then tap **Install**.
3. Open **HiperTracker**, allow **Location → Allow all the time** and **Notifications**.
4. Either log in with the worker's ERP username and password (⚙ Settings → **Hipersign ERP account**), or, in Hipersign ERP, open the device in **HiperTracker → Devices & People** and scan its **Phone setup QR** with the app (⚙ Settings → QR icon). Both link this phone to that person and give it its private device key.

> Android only. If the official Traccar Client from the Play Store is installed on the phone, uninstall it first.

## 🔄 Updates

Every change pushed to this repository builds a new version automatically and publishes it under [Releases](https://github.com/helloxbaz/hipertracker-app/releases).
The app checks for new versions when it opens and shows **"New version available"** with an **Update** button that downloads and installs it.
Workers can also check any time with the update icon at the top of the app.

## What the app does

- Sends location in the background **straight to Hipersign ERP** (`/api/method/hipertracker_position`), no Traccar server needed. Each phone sends its private device key, so nobody else can post locations for it
- **Check In / Check Out** with location, saved in ERP as Employee Checkin; tracking and the GPS alarm run only between the two (set in HiperTracker Settings)
- **GPS-off alert:** if the worker turns location off, the phone rings an alarm (even with the app closed) and repeats it at the interval set in ERP; when it escalates, ERP notifies their head (bell notification + email)
- ERP also alerts the head when a checked-in phone stops reporting (switched off, no internet), and keeps a day-by-day **route history** for every phone
- SOS button, one-off "send location now"
- Settings protected by an optional password
- Remote setup by QR code, link or MDM; remote commands by push (start/stop tracking, request position)

## For developers

Standard Flutter project:

```shell
flutter pub get
flutter run
```

Releases are built by `.github/workflows/apk.yml` on every push to `main`. It needs the repository secrets
`HT_KEYSTORE_BASE64`, `HT_KEYSTORE_PASSWORD`, `HT_KEY_ALIAS` and `HT_KEY_PASSWORD`; every release must be signed with the same key or phones will refuse to update.

## License

Based on [Traccar Client](https://github.com/traccar/traccar-client) by Anton Tananaev. Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt).
