# python:3.12-slim (Debian 13) had 44 HIGH CVEs with no fix available (util-linux, ncurses, systemd, perl).
# Alpine ships far fewer OS packages, so the attack surface and the CVE count drop. See README "Base image fix".
FROM python:3.12-alpine

WORKDIR /app
COPY requirements.txt .
# Install the app deps, then remove pip and the ensurepip wheels. The app never runs pip, and pip's
# vendored libraries (urllib3, msgpack, setuptools) carried fixable HIGH CVEs that failed the gate.
RUN pip install --no-cache-dir -r requirements.txt && \
    pip uninstall -y pip && \
    rm -rf /usr/local/lib/python3.12/ensurepip

COPY app ./app

# Run as an unprivileged user, not root.
RUN adduser -D -H -u 10001 appuser
USER 10001

EXPOSE 5001
CMD ["python", "app/app.py"]
