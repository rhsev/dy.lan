FROM ruby:4.0-alpine

# Build-Dependencies + Runtime tools
RUN apk add --no-cache build-base bash cronie curl git

WORKDIR /app

# Gems installieren
COPY Gemfile Gemfile.lock* ./
RUN bundle install

# App-Code kopieren
COPY . .

# Crontab installieren
RUN crontab /app/config/crontab

# Port 80 exponieren
EXPOSE 80

# Aktiviere ZJIT (Ruby 4.0 JIT Compiler) für bessere Performance
# ENV RUBYOPT="--zjit"

# Start script ausführen (startet Cron + Dylan Server)
CMD ["/app/scripts/start.sh"]
