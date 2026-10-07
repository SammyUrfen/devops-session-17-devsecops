FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# Run as an unprivileged user, not root.
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 5001
CMD ["python", "app/app.py"]
