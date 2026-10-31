import pathlib
import sys
import time

print("SHELL_STARTED", flush=True)
time.sleep(2)
pathlib.Path(sys.argv[1]).write_text("command survived cancellation")
