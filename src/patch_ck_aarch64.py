from pathlib import Path
import re

path = Path("third_party/concurrency_kit/Makefile")
text = path.read_text()

# Prefer rewriting CK_CONFIGURE_FLAGS directly when the assignment is present.
text, assigned = re.subn(
    r'(?m)^CK_CONFIGURE_FLAGS\s*=.*$',
    'CK_CONFIGURE_FLAGS = --profile=aarch64 --without-pic',
    text,
    count=1,
)

# Fallback for Makefiles that inline ./configure without CK_CONFIGURE_FLAGS.
if assigned == 0 and "--profile=aarch64" not in text:
    text, inserted = re.subn(
        r'(?m)^(\s*\.\/configure)(\s*\\)$',
        r'\1 --profile=aarch64 --without-pic\2',
        text,
        count=1,
    )
else:
    inserted = 0

# If arm profile leaked in, rewrite it for aarch64.
text = text.replace("--profile=arm", "--profile=aarch64")
path.write_text(text)

if assigned or inserted:
    print("patched CK configure recipe with aarch64 profile")
