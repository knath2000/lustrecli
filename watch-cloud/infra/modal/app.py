from pathlib import Path
import os
import subprocess

import modal

if modal.is_local():
    root = Path(__file__).resolve().parents[2]
    image = modal.Image.from_dockerfile(
        root / "services" / "resolver" / "Dockerfile",
        context_dir=root,
        add_python="3.12",
    )
else:
    image = modal.Image.debian_slim()
app = modal.App("lustre-watch-resolver")


@app.function(
    image=image,
    cpu=0.25,
    memory=(512, 768),
    min_containers=0,
    max_containers=3,
    scaledown_window=30,
    timeout=60,
)
@modal.concurrent(max_inputs=4)
@modal.web_server(port=8080, startup_timeout=60, requires_proxy_auth=True)
def serve():
    env = {**os.environ, "PORT": "8080", "NODE_ENV": "production"}
    subprocess.Popen(
        ["node", "/app/services/resolver/dist/server.js"],
        env=env,
        stdin=subprocess.DEVNULL,
    )
