# One-shot plugin-installer image. Stdlib-only script; the slim base is all
# it needs. See installer/install_plugins.py for what it does.
FROM python:3.12-slim

WORKDIR /app
COPY installer/install_plugins.py /app/install_plugins.py

ENTRYPOINT ["python", "/app/install_plugins.py"]
