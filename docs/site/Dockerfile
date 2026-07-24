# Build the Starlight static site and serve it with nginx.
# Build context is the REPO ROOT (the generator reads cluster/ manifests):
#   docker build -f docs/site/Dockerfile -t ghcr.io/arsenikki/homelab-docs .
FROM node:22-alpine AS build
WORKDIR /app/docs/site
COPY docs/site/package.json docs/site/package-lock.json ./
RUN npm ci
# Bring in the site tooling, the KB content, and the cluster manifests the
# generator renders (prebuild = sync KB + generate reference pages, then astro build).
WORKDIR /app
COPY docs/site ./docs/site
COPY docs/homelab ./docs/homelab
COPY cluster ./cluster
WORKDIR /app/docs/site
RUN npm run build

FROM nginx:1.27-alpine
COPY docs/site/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/docs/site/dist /usr/share/nginx/html
EXPOSE 80
