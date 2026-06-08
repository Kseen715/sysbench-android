#!/system/bin/sh
# Disk throughput test via sysbench fileio.
# Produces two numbers similar to hdparm -Tt:
#   - Memory (cached) read speed  -> sysbench memory sequential read
#   - Disk sequential read speed  -> sysbench fileio seqrd with O_DIRECT
#
# Usage:
#   ./disk-test.sh [sysbench-binary] [test-dir] [file-size-mb]
#
# Examples:
#   ./disk-test.sh ./sysbench-armv7 /data/local/tmp 512
#   ./disk-test.sh                                          # auto-detect from ./out/

SYSBENCH="${1:-}"
TEST_DIR="${2:-/data/local/tmp}"
FILE_SIZE_MB="${3:-512}"

# ---------- locate binary ----------
if [ -z "$SYSBENCH" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64)  SYSBENCH="./out/sysbench-aarch64" ;;
        armv7*)   SYSBENCH="./out/sysbench-armv7"   ;;
        armv6*)   SYSBENCH="./out/sysbench-armv6"   ;;
        x86_64)   SYSBENCH="./out/sysbench-x86_64"  ;;
        i*86)     SYSBENCH="./out/sysbench-x86"     ;;
        *)        echo "Unknown arch: $ARCH — pass binary as first arg"; exit 1 ;;
    esac
fi

if [ ! -x "$SYSBENCH" ]; then
    echo "sysbench not found or not executable: $SYSBENCH"
    exit 1
fi

echo "sysbench : $SYSBENCH"
echo "test dir : $TEST_DIR"
echo "file size: ${FILE_SIZE_MB}M"
echo ""

# ---------- memory (cached) speed ----------
echo "--- Memory (cached) read speed ---"
MEM_OUTPUT=$("$SYSBENCH" memory \
    --memory-block-size=1M \
    --memory-total-size="${FILE_SIZE_MB}M" \
    --memory-oper=read \
    --memory-access-mode=seq \
    run 2>&1)

# "512.00 MiB transferred (1602.59 MiB/sec)"
MEM_MBS=$(echo "$MEM_OUTPUT" | grep 'MiB transferred' | grep -oE '[0-9]+\.[0-9]+ MiB/sec')
echo " Cached reads: ${MEM_MBS:-see raw output below}"
[ -z "$MEM_MBS" ] && echo "$MEM_OUTPUT"
echo ""

# ---------- disk sequential read (O_DIRECT) ----------
echo "--- Disk sequential read speed (O_DIRECT, bypasses OS cache) ---"
cd "$TEST_DIR" || { echo "Cannot cd to $TEST_DIR"; exit 1; }

PREPARE_OUTPUT=$("$SYSBENCH" fileio \
    --file-total-size="${FILE_SIZE_MB}M" \
    --file-block-size=1M \
    prepare 2>&1)

if echo "$PREPARE_OUTPUT" | grep -qi "error\|failed"; then
    echo "Prepare failed:"
    echo "$PREPARE_OUTPUT"
    exit 1
fi

RUN_OUTPUT=$("$SYSBENCH" fileio \
    --file-total-size="${FILE_SIZE_MB}M" \
    --file-block-size=1M \
    --file-test-mode=seqrd \
    --file-extra-flags=direct \
    --time=15 \
    --events=0 \
    run 2>&1)

"$SYSBENCH" fileio \
    --file-total-size="${FILE_SIZE_MB}M" \
    cleanup >/dev/null 2>&1

# "read:  IOPS=141.90 141.90 MiB/s (148.79 MB/s)"
DISK_MBS=$(echo "$RUN_OUTPUT" | grep 'read:' | grep -oE '[0-9]+\.[0-9]+ MiB/s')
echo " Disk reads:   ${DISK_MBS:-see raw output below}"
[ -z "$DISK_MBS" ] && echo "$RUN_OUTPUT"
