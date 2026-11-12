# --- stage 1: build the React frontend ---
FROM node:20-slim AS frontend-build
WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# --- stage 2: static-file server ---
# Every compute-heavy feature (trim, join, telemetry extraction, lap
# detection, HUD rendering, compositing) runs client-side in the browser --
# see frontend/src/lib/ -- so all that's left is serving the built frontend.
# nginx-unprivileged runs as a non-root user (uid 101); see nginx.conf for
# the port, caching and MIME rules. No data volume: nothing is ever stored
# server-side.
FROM nginxinc/nginx-unprivileged:1.28-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=frontend-build /frontend/dist /usr/share/nginx/html

EXPOSE 7000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:7000/api/health || exit 1
