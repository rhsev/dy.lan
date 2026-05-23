FROM ruby:4.0-alpine

# Build dependencies + runtime tools
RUN apk add --no-cache build-base bash cronie curl git

WORKDIR /app

# Install gems first (separate layer — only rebuilds when Gemfile changes)
COPY Gemfile Gemfile.lock* ./
RUN bundle install

# Bake in app code as a fallback — works out of the box without volume mounts.
# In production, docker-compose mounts lib/, plugins/, config/, scripts/ and
# server.rb on top, so a git pull + container restart picks up all changes
# without a rebuild. Only Gemfile changes require a new image build.
COPY . .

EXPOSE 80

# Starts cron + Dylan server (reads crontab from config/)
CMD ["/app/scripts/start.sh"]
