FROM elixir:1.18-alpine

ENV APP_HOME /app
WORKDIR $APP_HOME

RUN apk add --no-cache ca-certificates

COPY mix.exs .
COPY mix.lock .

RUN mix local.hex --force \
    && mix local.rebar --force \
    && MIX_ENV=prod mix deps.get \
    && MIX_ENV=test mix deps.get

COPY lib lib
COPY test test

RUN MIX_ENV=prod mix compile
RUN MIX_ENV=test mix compile

ENV MIX_ENV=prod
ENTRYPOINT ["mix", "send.application"]
