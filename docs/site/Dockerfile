# Build the Starlight static site from the docs/homelab KB and serve it with nginx.
# Build context is docs/ (so both site/ and homelab/ are available):
#   docker build -f docs/site/Dockerfile -t ghcr.io/arsenikki/homelab-docs docs
FROM node:22-alpine AS build
WORKDIR /app/site
COPY site/package.json site/package-lock.json ./
RUN npm ci
COPY site/ ./
COPY homelab/ /app/homelab/
# prebuild (scripts/sync.mjs) copies /app/homelab -> src/content/docs, then astro builds.
RUN npm run build

FROM nginx:1.27-alpine
COPY site/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/site/dist /usr/share/nginx/html
EXPOSE 80
