---
name: t1dmdroid-install
description: >-
  Build T1DMDROID and install it on the phone without freezing this machine. Read BEFORE any
  `./gradlew`, `cargo build`, `cargo test`, `android describe` or APK install in T1DMDROID, on
  either branch. Covers the resource-capped build wrapper, one-build-at-a-time order, finding the
  APK without Gradle, adb install, relaunch, service check, and killing leftover build processes.
---

# T1DMDROID: build and install

Machine: 32 cores, 15 GiB RAM, live desktop. Uncapped builds froze it.

## Hard limits

- One build at a time. Never two, not even in the background.
- Every build: 4 cores, 4 GB RAM, no swap, lowest CPU and disk priority.
- No Gradle or Kotlin daemon outlives its build.
- No `android describe`: it starts Gradle.

## Gradle wrapper

```sh
systemd-run --user --scope --quiet \
  -p CPUQuota=400% -p MemoryMax=4G -p MemorySwapMax=0 \
  taskset -c 0-3 nice -n 19 ionice -c3 \
  env -u JAVA_HOME PATH="$HOME/.cargo/bin:$PATH" CARGO_BUILD_JOBS=2 \
  ./gradlew --no-daemon --max-workers=2 \
    -Pkotlin.compiler.execution.strategy=in-process \
    "-Dorg.gradle.jvmargs=-Xmx2500m -XX:MaxMetaspaceSize=640m -XX:+UseParallelGC -Dfile.encoding=UTF-8" \
    <tasks> > <scratchpad>/build.log 2>&1
```

- `MemoryMax` covers the whole scope: heap, metaspace, aapt2, cargo, page cache. 2500m heap fits; R8
  passes at that size. Over the cap, the build is OOM-killed and the desktop is untouched.
- `in-process`: no separate Kotlin compiler daemon.
- `PATH=` and `env -u JAVA_HOME`: why they matter is in T1DMDROID `CLAUDE.md`.
- Run it with `run_in_background`, then wait for the completion notification. Don't poll.

## Cargo wrapper

```sh
systemd-run --user --scope --quiet \
  -p CPUQuota=400% -p MemoryMax=4G -p MemorySwapMax=0 \
  taskset -c 0-3 nice -n 19 ionice -c3 \
  cargo test -j 2 <args>          # same for cargo build --release
```

## Order

`private` = `../T1DMDROID`. `main` = worktree `~/.cache/t1dm/droid-main`. Never `git checkout main`.

1. Commit on both branches first, version bump included, so the build carries the right version.
2. `main`: `:app:assemblePersonalRelease`, plus `:app:assemblePublicRelease` if flavour-gated code
   changed. Proves it compiles. Don't install it.
3. `private`: `:app:assemblePersonalRelease` plus the test gates the change touches. This APK goes on
   the phone.
4. After each build:

   ```sh
   ps -eo pid,rss,args | grep -E "[j]ava|[K]otlinCompile|[c]argo|[r]ustc"
   free -h
   ```

   Anything listed: `kill <pid>`. Prefer `kill` over `./gradlew --stop`, which starts another JVM.
5. Install. Last step of the task.

## Stopping a build

Stopping the background task kills only the shell. The scope keeps running:

```sh
systemctl --user list-units --type=scope --no-legend | grep run-
systemctl --user kill -s KILL <run-….scope>
```

Never `pkill -f` with a pattern that is also in your own command line: it kills your own shell first.

## Find the APK

```sh
cat app/build/outputs/apk/personal/release/output-metadata.json   # versionCode, versionName, outputFile
```

`versionCode` must match `app/build.gradle.kts`.

## Install

The phone is the user's CGM monitor. An install stops the monitoring service until the app is
relaunched.

```sh
adb get-state                     # fails: nothing attached; skip install, say so, not a failure
adb install -r app/build/outputs/apk/personal/release/app-personal-release.apk
adb shell am start -n com.t1dm.app/.MainActivity
for i in $(seq 10); do
  adb shell dumpsys activity services com.t1dm.app </dev/null | grep -q "isForeground=true" && break
  timeout 3 tail -f /dev/null
done
adb shell dumpsys activity services com.t1dm.app </dev/null | grep -m1 isForeground   # want true
adb shell dumpsys package com.t1dm.app </dev/null | grep -m1 versionName
```

HyperOS install traps: `android-device-testing`.

## On-screen review is the user's

The install ends at the checks above. The user reviews the screen on the phone.

- No `input tap`, `input swipe` or `input keyevent` to reach a screen. A tap on the dashboard's sensor
  name switched the live CGM view to another sensor.
- Checks that change nothing are fine: logcat, `dumpsys`, tests, `uiautomator dump`, `screencap`.
- If only the screen shows the result, name the screen and the row to check, then stop.
