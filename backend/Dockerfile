FROM python:3.12-slim

# glibc gives each thread its own malloc arena and never returns that memory
# to the OS. Uvicorn runs the sync handlers on a 40-thread pool, so the radar
# decoding spread across those threads held ~444 MB of arenas and the OOM
# killer took the machine on 2026-09-13. Two arenas measured 200 MB for the
# same launch burst.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    MALLOC_ARENA_MAX=2

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app/ ./app/

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
