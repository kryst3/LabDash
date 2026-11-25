FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN useradd --system --create-home labdash \
    && mkdir -p /app/instance \
    && chown labdash:labdash /app/instance

COPY --chown=labdash:labdash . .

USER labdash

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "from urllib.request import urlopen; urlopen('http://127.0.0.1:5000/login', timeout=2)"]

CMD ["gunicorn", "--workers=1", "--threads=4", "--bind=0.0.0.0:5000", "app:app"]
