import subprocess
import sys

dropped = {"-fstack-protector-strong", "-D_FORTIFY_SOURCE=3"}
sys.exit(subprocess.run([a for a in sys.argv[1:] if a not in dropped], check=False).returncode)
