# TalkLoc prototype (test build)

A small Android app to test the riskiest part of the idea: **hold-to-talk voice and the other person's live location on the same screen, between two phones.**

You do not need to install any developer tools. GitHub builds the app for you in the cloud.

This is a test build, not the finished product. It has no sign-in, no circles and no ads. It only answers: *does voice + live pin work on real phones, including when the screen is off?*

---

## What you need (all free)

1. A **GitHub** account (done)
2. A **LiveKit Cloud** account: livekit.io (this carries the voice and the location messages)
3. **Two Android phones** to test with (yours plus a friend's or family member's)

---

## Part 1: The code is already on GitHub

The code and the build recipe (`.github/workflows/build-apk.yml`) are in this repository. Nothing to upload.

## Part 2: Build the app

1. In your repository click the **Actions** tab.
2. Click **Build APK** on the left, then **Run workflow**, then the green **Run workflow** button.
3. Wait about 10 to 15 minutes. A green tick means it worked.
4. Click the finished run. At the bottom, under **Artifacts**, click **talkloc-apk** to download a zip. Unzip it to get `app-release.apk`.

**If the run shows a red cross:** click the run, click the failed step, copy the last 40 lines of red text, and send them to me. The first build often needs one or two fixes. That is normal.

## Part 3: Install on your phone

1. Get `app-release.apk` onto the phone (send it to yourself on WhatsApp, Google Drive or email).
2. Tap it. If the phone asks, allow **Install unknown apps** for that app (Chrome, WhatsApp, Files).
3. Open **TalkLoc**.

## Part 4: Make the voice passes (tokens)

1. In LiveKit Cloud create a project. In the project settings copy:
   - the **server address** (looks like `wss://yourname-abc123.livekit.cloud`)
   - an **API key** and **API secret** (look for Keys in Settings)
2. On your laptop open `tools/token-maker.html` in Chrome. Nothing leaves your computer.
3. Enter the key and secret. Use the **same room name** for both phones, for example `test-room`.
4. Make **two tokens**: identity `phone-1` / name `Me`, and identity `phone-2` / name `Friend`.
5. Send each token to the right phone (WhatsApp is fine, delete the message afterwards). Tokens expire after the hours you chose, so make new ones if a day passes.

> Never share the API secret, and never upload it to GitHub.

## Part 5: Test

On each phone: open TalkLoc, paste the server address and that phone's token, tap **Connect**.

- Tap **Continue** on the location notice, then allow location. When your phone shows the settings page choose **Allow all the time**. Allow the microphone and notifications.
- When both phones are connected each shows the other's pin, the distance and the direction.
- **Hold the red button to talk. Release to listen.**

### The tests that matter

| Test | What to look for |
|---|---|
| Walk apart 100 m, hold to talk | Voice clear? Pin and distance move? |
| Lock the screen for 5 minutes | Does the other phone's pin keep moving? A notification "TalkLoc is sharing your location" should stay on |
| Switch to another app for 5 minutes | Same question |
| Turn mobile data to 3G or weak signal | Does voice still work? Does "Updated" show a recent time? |
| Battery after 1 hour | Note the percentage used |
| Try on a Xiaomi, Oppo or Vivo phone if you can | These close apps the most. In phone settings set TalkLoc battery to **No restrictions** and turn on **Autostart** |

Write down what fails, with the phone model. That is the real result of this prototype.

---

## Known limits of this test build

- **Talk with the app open.** Android blocks microphone use in the background. Receiving voice and sharing location can work with the screen off, but sending voice needs the app on screen.
- Tokens are made by hand and expire. A real app will do this automatically with a small server.
- The map uses free OpenStreetMap tiles. That is fine for testing but not for many users.
- Android only.
- Version differences: the build uses the newest Flutter, and a package may have changed. If the build fails, send me the error text and I will fix it.

## What is where

- `lib/` the app code (setup screen, talk screen, theme)
- `scripts/patch_android.py` adds permissions during the build
- `tools/token-maker.html` makes the passes for each phone
- `.github/workflows/build-apk.yml` the build recipe
