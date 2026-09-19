FROM ruby:4.0-alpine

# Runtime tools only — the C toolchain lives in a virtual package below
RUN apk add --no-cache bash cronie curl tzdata

WORKDIR /app

# Install gems first (separate layer — only rebuilds when Gemfile changes).
# build-base is needed to compile io-event's native extension; installing
# and removing it inside one RUN keeps the toolchain out of the image.
COPY Gemfile Gemfile.lock* ./
RUN apk add --no-cache --virtual .build-deps build-base \
 && bundle install \
 && apk del .build-deps

# Bake in app code as a fallback — works out of the box without volume mounts.
# Copied path by path rather than `COPY . .`: the build context is a live
# production directory, and a wildcard copy kept dragging in whatever else
# happened to sit there (Synology @eaDir sidecars, host config files, editor
# leftovers), rebuilding the image on nights when no code had changed.
# In production, docker-compose mounts the whole directory on /app anyway, so
# this layer only matters when running without mounts.
COPY server.rb ./
COPY lib/ ./lib/
COPY plugins/ ./plugins/
COPY config/ ./config/
COPY scripts/ ./scripts/

EXPOSE 80

# Starts cron + Dylan server (reads crontab from config/)
CMD ["/app/scripts/start.sh"]
