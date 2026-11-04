# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm
WORKDIR /opt/zeus
COPY Cloud/requirements.lock requirements.lock
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then PIP_CERT=/run/secrets/proxy_ca pip install --no-cache-dir -r requirements.lock numpy==2.2.6 onnxruntime==1.24.2; else pip install --no-cache-dir -r requirements.lock numpy==2.2.6 onnxruntime==1.24.2; fi
COPY Cloud/zeus_cloud zeus_cloud
COPY Restoration/app.py Restoration/inference.py ./
COPY ZEUSNext/Resources/comic-models.json ./
ENV PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["sh","-c","uvicorn app:app --host 0.0.0.0 --port ${PORT} --workers 1 --no-access-log --limit-concurrency 4"]
