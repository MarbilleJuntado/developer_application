FROM elixir:1.18

ENV APP_HOME /app
RUN mkdir -p $APP_HOME
WORKDIR $APP_HOME

COPY mix.exs .
COPY mix.lock .

RUN mix local.hex --force \
    && mix local.rebar --force \
    && MIX_ENV=prod mix deps.get

COPY lib lib
RUN MIX_ENV=prod mix compile

ENV MIX_ENV=prod
ENTRYPOINT ["mix", "send.application"]
