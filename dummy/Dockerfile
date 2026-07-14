# syntax=docker/dockerfile:1
# check=error=true

# Production image for Cloud Run. The SAME image serves two roles:
#   1. Cloud Run *service* — HTTP push target. Default CMD boots the Rails
#      server; Cloud Tasks / Cloud Scheduler POST to /solid_gcp/*.
#   2. Cloud Run *Job* — FakeImportJob (perform_via :cloud_run_job). Deploy the
#      job with the command overridden to:  bin/rails solid_gcp:execute
#      It reads the serialized envelope from the SOLID_GCP_ENVELOPE env var.
#
# NOTE: this app depends on the gem via `path: "../gem"`, which lives OUTSIDE
# the Docker build context. To build a real image, either (a) publish/vendor
# solid_gcp and point the Gemfile at it, or (b) build with the repo root as the
# context and adjust the COPY paths. Flightdeck will use the published gem.
#
# docker build -t dummy .
# docker run -d -p 8080:8080 -e RAILS_MASTER_KEY=<config/master.key> --name dummy dummy

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Cloud Run injects $PORT (default 8080) and expects the container to listen on
# it. Thruster honors PORT via its own env. Bind to 8080 by default.
ENV PORT="8080"
EXPOSE 8080

# Default: Cloud Run service (HTTP). For the Cloud Run *Job*, override the
# command at deploy time with:  bin/rails solid_gcp:execute
CMD ["./bin/thrust", "./bin/rails", "server"]
