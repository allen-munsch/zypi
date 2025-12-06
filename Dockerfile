# Use an official Elixir image as a parent image
# See https://hub.docker.com/_/elixir/ for available tags
ARG ELIXIR_VERSION=1.19.3
ARG OTP_VERSION=28
ARG IMAGE_NAME=elixir

FROM ${IMAGE_NAME}:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim

# Set the working directory in the container
WORKDIR /app

# Install system dependencies required for Zypi and for os_mon
# procps contains `top` and `uptime` which are used in Zypi.System.Stats
RUN apt-get update && apt-get install -y \
    build-essential \
    crun \
    procps \
    curl \
    jq \
    dmsetup \
    util-linux \
    skopeo \
    ca-certificates \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Set ASDF paths correctly for the mix commands to work
ENV PATH="/root/.asdf/bin:/root/.asdf/shims:${PATH}"

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy over the mix.exs and mix.lock files
COPY mix.exs mix.lock ./

# Fetch the dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy the rest of the application source code
COPY lib ./lib
COPY config ./config

# Compile the application
RUN mix compile

# Define the command to run your app
# "mix run --no-halt" is used to keep the container running
CMD ["elixir", "--sname", "zypi_node_instance", "--cookie", "zypi_secret_cookie", "-S", "mix", "run", "--no-halt"]
