# sysbench-android

This is a small build project that compiles `sysbench` for Android. There is no Android app or interface here. It is a Docker-based build that pulls in the required NDK, downloads the `sysbench` source code, and produces ready-to-use binaries for several architectures.

After the build finishes, the `out/` folder contains files like `sysbench-armv7`, `sysbench-aarch64`, and `sysbench-x86_64`. You can copy those to a device or emulator if you need `sysbench` on Android.

## How to build

The easiest way is with Docker Compose:

```bash
docker compose build
docker compose run --rm sysbench-android-build
```

If Docker is already set up and you want to run the script directly, you can do that too:

```bash
./build-sysbench-android.sh
```

The build downloads `sysbench` from `akopytov/sysbench` and uses Android NDK `r10e`. If you want to build a different `sysbench` revision, you can change it in `docker-compose.yml` or in `Dockerfile` through the `SYSBENCH_REF` argument.

## Usage

Once the build is done, take the binary that matches your device architecture from `out/` and copy it to the device. For example, if you are using the ARMv7 build, the flow looks like this:

```bash
adb push out/sysbench-armv7 /data/local/tmp/sysbench
adb shell chmod 755 /data/local/tmp/sysbench
adb shell 'cd /data/local/tmp; ./sysbench-armv7 cpu run --threads=1'
adb shell 'cd /data/local/tmp; ./sysbench-armv7 memory --memory-block-size=1M run'
```

From there you can run the tool with the arguments you need for your device.

### Disk throughput test (no block device access needed)

`disk-test.sh` mimics `hdparm -Tt` but works entirely in a local directory using `sysbench fileio`:

```bash
adb push disk-test.sh /data/local/tmp/
adb push out/sysbench-armv7 /data/local/tmp/sysbench
adb shell chmod 755 /data/local/tmp/disk-test.sh /data/local/tmp/sysbench
adb shell 'cd /data/local/tmp; sh disk-test.sh ./sysbench . 512'
```

The script reports two numbers:

- **Cached reads** — memory read throughput (sysbench `memory`, sequential)
- **Disk reads** — sequential read from disk with `O_DIRECT` to bypass the OS page cache (sysbench `fileio seqrd`)

The third argument controls the test file size in MB (default 512). Use a smaller value (e.g. 128) on devices with limited storage, or larger (e.g. 1024) to ensure the working set exceeds the disk's internal cache.

## Note

The build is intended for Linux and Docker. The first run can take a while because it needs to download dependencies and the `sysbench` source code.
