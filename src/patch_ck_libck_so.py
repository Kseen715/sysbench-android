from pathlib import Path
import re

path = Path("third_party/concurrency_kit/Makefile")
text = path.read_text()

# Insert "touch src/libck.so" before "make install" so the install step does
# not fail when the shared library was not built (static-only build).
text, count = re.subn(
    r'(?ms)make && \\\n(\s*)make install',
    r'make && \\\n\1touch src/libck.so && \\\n\1make install',
    text,
    count=1,
)
if count:
    path.write_text(text)
