# Install iptv-app

**[Download iptv-app.apk](https://github.com/akus0/iptv-app-public/releases/latest/download/iptv-app.apk)**

The same APK supports 32-bit and 64-bit ARM phones, Android TV and Google TV on Android 7.0 or newer. It does not support Samsung Tizen, LG webOS, iOS or x86 Android devices. The app includes no channels or subscriptions.

## Android phone or tablet

1. Open the download link above in your browser.
2. Open the downloaded `iptv-app.apk`.
3. If prompted, allow that browser or file manager to **install unknown apps**, then return to the installer and choose **Install**. Menu names vary by device. You can turn that permission off afterwards.
4. Open iptv-app and add your playlist under **Settings → Playlists & guide → Add Playlist**.

## Android TV or Google TV

1. Install [Downloader by AFTVnews](https://play.google.com/store/apps/details?id=com.esaba.downloader) from the TV's Play Store.
2. In Downloader, open this direct APK address:

   ```text
   https://github.com/akus0/iptv-app-public/releases/latest/download/iptv-app.apk
   ```

3. Allow Downloader to **install unknown apps** when prompted, then install the APK. On some TVs this permission is under **Settings → Apps → Special app access** or **Security & restrictions**.
4. Open iptv-app from the TV's apps list and add your playlist.

Alternatively, download the APK on your phone and transfer it to the TV, then open it with the TV's file manager. Developer mode and wireless debugging are not needed for these installation methods.

### Downloader numeric codes

A Downloader code is a shortcut to a web address. You can create one at the [AFTVnews URL Shortener](https://go.aftvnews.com/) by pasting the direct APK link above and completing its CAPTCHA. Enter the returned number in Downloader on the TV. Because the link points to the latest release, the same code can continue to work after updates. Codes and submitted URLs are public; never submit a playlist or login link.

## Updates and troubleshooting

- Download the latest APK and install it over the existing app. Releases retain the application ID and signing certificate, so Android can update the app while keeping its data. Do not uninstall first.
- Updates are manual; GitHub does not push them to your device. Use the repository's **Watch → Custom → Releases** option for notifications.
- If Android refuses an update, check that the APK came from this repository and that enough storage is available. An installation signed by someone else cannot be updated with this APK.
- If a device's security policy blocks installation, follow its supported installation process. Do not disable Play Protect to force installation.
- Each release includes `SHA256SUMS.txt` and matching source materials. The APK is the only file needed to install the app; source archives are for developers.

[Latest release](https://github.com/akus0/iptv-app-public/releases/latest) · [Set up playlists](../README.md#get-started)
