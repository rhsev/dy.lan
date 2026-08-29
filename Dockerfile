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
# In production, docker-compose mounts lib/, plugins/, config/, scripts/ and
# server.rb on top, so a git pull + container restart picks up all changes
# without a rebuild. Only Gemfile changes require a new image build.
COPY . .

EXPOSE 80

# Starts cron + Dylan server (reads crontab from config/)
CMD ["/app/scripts/start.sh"]
