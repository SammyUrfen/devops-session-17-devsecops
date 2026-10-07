# python:3.12-slim (Debian 13) had 44 HIGH CVEs with no fix available (util-linux, ncurses, systemd, perl).
# Alpine ships far fewer OS packages, so the attack surface and the CVE count drop. See README "Base image".
FROM python:3.12-alpine

WORKDIR /app
COPY requirements.txt .
# Upgrade the pip that ships in the base image (pip 25.0.1 had 6 CVEs), then install the app deps.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Run as an unprivileged user, not root.
RUN adduser -D -H -u 10001 appuser
USER 10001

EXPOSE 5001
CMD ["python", "app/app.py"]
